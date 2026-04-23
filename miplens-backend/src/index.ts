// Cloudflare Worker that generates an AI overview of a MATLAB package.
//
// POST /lens
//   Request body:  { packageName: string, files: { path: string, content: string }[] }
//   Response:      HTTP 200 with Content-Type: application/x-ndjson
//                  One JSON object per line. Event types:
//                    { "type": "reading", "path": string }
//                    { "type": "done",    "text":  string }
//                    { "type": "error",   "message": string }

interface Env {
  OPENROUTER_API_KEY: string;
  OPENROUTER_MODEL: string;
}

interface LensFile {
  path: string;
  content: string;
}

interface LensRequest {
  packageName: string;
  files: LensFile[];
  query?: string;
}

interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  name?: string;
}

interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

const MAX_TURNS = 20;
const MAX_FILE_BYTES_IN_CONTEXT = 200 * 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    if (url.pathname !== "/lens") {
      return jsonResponse({ error: "Not found" }, 404);
    }
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    let body: LensRequest;
    try {
      body = (await request.json()) as LensRequest;
    } catch {
      return jsonResponse({ error: "Invalid JSON body" }, 400);
    }

    const { packageName, files, query } = body;
    if (typeof packageName !== "string" || packageName.length === 0) {
      return jsonResponse({ error: "packageName is required" }, 400);
    }
    if (!Array.isArray(files) || files.length === 0) {
      return jsonResponse({ error: "files must be a non-empty array" }, 400);
    }
    for (const f of files) {
      if (typeof f?.path !== "string" || typeof f?.content !== "string") {
        return jsonResponse({ error: "each file needs path and content strings" }, 400);
      }
    }
    if (query !== undefined && typeof query !== "string") {
      return jsonResponse({ error: "query must be a string if provided" }, 400);
    }

    if (!env.OPENROUTER_API_KEY) {
      return jsonResponse({ error: "OPENROUTER_API_KEY is not configured" }, 500);
    }

    const stream = runLensStream(env, packageName, files, query ?? "");
    return new Response(stream, {
      status: 200,
      headers: {
        "Content-Type": "application/x-ndjson",
        "Cache-Control": "no-cache",
        ...CORS_HEADERS,
      },
    });
  },
};

function runLensStream(
  env: Env,
  packageName: string,
  files: LensFile[],
  query: string,
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();

  return new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (obj: unknown) => {
        controller.enqueue(encoder.encode(JSON.stringify(obj) + "\n"));
      };

      try {
        const fileMap = new Map<string, string>();
        for (const f of files) fileMap.set(f.path, f.content);

        const model = env.OPENROUTER_MODEL || "google/gemini-2.5-flash";
        const totalBytes = files.reduce((n, f) => n + f.content.length, 0);
        const trimmedQuery = query.trim();
        console.log(
          `[lens] package="${packageName}" files=${files.length} bytes=${totalBytes} model=${model}`,
        );
        if (trimmedQuery.length > 0) {
          console.log(`[lens] query: ${truncate(trimmedQuery, 200)}`);
        } else {
          console.log(`[lens] query: (default overview prompt)`);
        }

        const messages: ChatMessage[] = buildInitialMessages(
          packageName,
          files,
          trimmedQuery,
        );
        const tools = buildTools();

        for (let turn = 0; turn < MAX_TURNS; turn++) {
          console.log(`[lens] turn ${turn + 1}: calling model (${messages.length} msgs)`);
          const turnStart = Date.now();
          const orResponse = await fetch("https://openrouter.ai/api/v1/chat/completions", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
              "Content-Type": "application/json",
              "HTTP-Referer": "https://mip.sh",
              "X-OpenRouter-Title": "miplens",
            },
            body: JSON.stringify({ model, messages, tools }),
          });

          if (!orResponse.ok) {
            const detail = await orResponse.text();
            console.log(`[lens] openrouter error ${orResponse.status}: ${detail}`);
            emit({
              type: "error",
              message: `OpenRouter returned ${orResponse.status}: ${detail}`,
            });
            return;
          }

          const payload = (await orResponse.json()) as {
            choices?: { message?: ChatMessage }[];
            usage?: { prompt_tokens?: number; completion_tokens?: number };
          };
          const msg = payload.choices?.[0]?.message;
          const usage = payload.usage;
          const elapsed = Date.now() - turnStart;
          if (!msg) {
            console.log(`[lens] turn ${turn + 1}: no message in response`);
            emit({ type: "error", message: "OpenRouter response had no message" });
            return;
          }
          console.log(
            `[lens] turn ${turn + 1}: ${elapsed}ms${
              usage
                ? ` tokens=${usage.prompt_tokens ?? "?"}/${usage.completion_tokens ?? "?"}`
                : ""
            }`,
          );

          // Record the assistant turn (including tool_calls, if any).
          messages.push({
            role: "assistant",
            content: msg.content ?? "",
            tool_calls: msg.tool_calls,
          });

          const toolCalls = msg.tool_calls ?? [];
          if (toolCalls.length === 0) {
            const finalText = typeof msg.content === "string" ? msg.content : "";
            console.log(`[lens] done: ${finalText.length} chars`);
            emit({ type: "done", text: finalText });
            return;
          }

          console.log(
            `[lens] turn ${turn + 1}: ${toolCalls.length} tool call(s): ${toolCalls
              .map((tc) => `${tc.function.name}(${previewArgs(tc.function.arguments)})`)
              .join(", ")}`,
          );
          if (typeof msg.content === "string" && msg.content.trim().length > 0) {
            console.log(`[lens] assistant note: ${truncate(msg.content.trim(), 200)}`);
          }

          for (const tc of toolCalls) {
            const toolResult = runTool(tc, fileMap, emit);
            console.log(
              `[lens]   -> ${tc.function.name}(${previewArgs(
                tc.function.arguments,
              )}): ${toolResult.length} chars`,
            );
            messages.push({
              role: "tool",
              tool_call_id: tc.id,
              name: tc.function.name,
              content: toolResult,
            });
          }
        }

        console.log(`[lens] reached MAX_TURNS=${MAX_TURNS} without a final answer`);
        emit({
          type: "error",
          message: `Reached max turns (${MAX_TURNS}) without a final answer.`,
        });
      } catch (e) {
        console.log(`[lens] exception: ${String(e)}`);
        emit({ type: "error", message: String(e) });
      } finally {
        controller.close();
      }
    },
  });
}

function runTool(
  tc: ToolCall,
  fileMap: Map<string, string>,
  emit: (obj: unknown) => void,
): string {
  if (tc.function.name !== "read_file") {
    return `Error: unknown tool "${tc.function.name}"`;
  }
  let args: { path?: unknown };
  try {
    args = JSON.parse(tc.function.arguments);
  } catch {
    return "Error: tool arguments were not valid JSON";
  }
  const path = typeof args.path === "string" ? args.path : "";
  if (!path) {
    return "Error: missing 'path' argument";
  }
  emit({ type: "reading", path });
  const content = fileMap.get(path);
  if (content === undefined) {
    return `Error: no file with path "${path}" in the manifest`;
  }
  if (content.length > MAX_FILE_BYTES_IN_CONTEXT) {
    return (
      content.slice(0, MAX_FILE_BYTES_IN_CONTEXT) +
      `\n\n[... file truncated at ${MAX_FILE_BYTES_IN_CONTEXT} bytes ...]`
    );
  }
  return content;
}

function buildInitialMessages(
  packageName: string,
  files: LensFile[],
  query: string,
): ChatMessage[] {
  const manifest = files
    .map((f) => `  ${f.path}  (${f.content.length} bytes)`)
    .join("\n");

  const upfrontFiles = files.filter((f) => isUpfrontFile(f.path));
  const upfrontBody = upfrontFiles
    .map((f) => `--- ${f.path} ---\n${f.content}`)
    .join("\n\n");

  const systemMessage = [
    "You are miplens, an assistant that summarizes MATLAB packages in",
    "the MIP ecosystem (mip.sh). Each package is a directory of MATLAB",
    "source (.m) files, often grouped into +package namespaces, with",
    "README and manifest files (mip.yaml, mip.json).",
    "",
    "You receive a manifest of all files in the package, plus the full",
    "contents of the READMEs and mip.yaml/mip.json. If you need more,",
    "call the read_file tool with a path from the manifest. Only read",
    "what you actually need — for most packages a few files are enough.",
    "Do not invent functionality that is not in the sources.",
    "",
    "Scope: answer only questions about this specific package — what it",
    "does, how to use it, its API, its dependencies, and related how-tos",
    "grounded in the source. If the user's question is off-topic (general",
    "programming help, other software, chit-chat, jokes, tasks that don't",
    "require reading this package, etc.), do NOT attempt to answer it.",
    "Instead reply with a single short line of plain text explaining that",
    "miplens only answers questions about the current package and suggest",
    "they ask something package-specific. No code, no format scaffolding,",
    "no section labels in that case.",
    "",
    "Output format — plain text in MATLAB help style. Do NOT use markdown.",
    "Rules:",
    "  - No '#' headings, no '**bold**', no backticks, no fenced code",
    "    blocks, no bullet characters like '*' or '•'.",
    "  - First line: '<packageName>   One-line summary.' (no indent).",
    "  - Body paragraphs indented 3 spaces, wrapped at ~72 columns.",
    "  - Section labels ('Usage:', 'Examples:', 'Functions:', 'See also:',",
    "    etc.) at column 0, followed by a colon.",
    "  - CRITICAL: Code / example / command lines are ALWAYS at column 0",
    "    (zero leading spaces), even inside an 'Examples:' or 'Usage:'",
    "    section. Separate them from surrounding prose with a blank line",
    "    above and below. This is so users can copy-paste them straight",
    "    into the Command Window without stripping whitespace.",
    "  - Function and file names appear as plain identifiers (e.g.",
    "    memorygraph.build, +miplens/getlens.m) — no quoting or markup.",
    "",
    "Here is a complete example of the exact formatting to use. Notice",
    "that every non-blank code line starts at column 0 with NO leading",
    "spaces, while prose lines inside sections are indented 3 spaces:",
    "",
    "example_pkg   Short utilities for doing X with Y.",
    "",
    "   A slightly longer paragraph describing what the package is for",
    "   and the kinds of problems it solves. Wrapped at ~72 columns and",
    "   indented 3 spaces.",
    "",
    "Usage:",
    "",
    "   Load the package and call the main entry point:",
    "",
    "example_pkg.load();",
    "result = example_pkg.run(data);",
    "",
    "Functions:",
    "",
    "   - example_pkg.load   - initialize internal state",
    "   - example_pkg.run    - process a data struct and return a result",
    "",
    "Examples:",
    "",
    "data = struct('x', 1:10);",
    "result = example_pkg.run(data);",
    "disp(result);",
    "",
    "See also: mip, mip.install",
    "",
    "End of example. Match this layout exactly — especially the flush-left",
    "code lines with blank lines around them.",
    "",
    `=== Package: ${packageName} ===`,
    "",
    "File manifest:",
    manifest,
    "",
    "Initial file contents (READMEs and manifests):",
    "",
    upfrontBody || "(no README or mip.yaml found)",
  ].join("\n");

  const userContent =
    query.length > 0
      ? query
      : `Give me an overview of the ${packageName} package: what it does, its main functionality, and typical usage. Use read_file to inspect source files when needed.`;

  return [
    { role: "system", content: systemMessage },
    { role: "user", content: userContent },
  ];
}

function buildTools() {
  return [
    {
      type: "function",
      function: {
        name: "read_file",
        description:
          "Read the full contents of a file from the package. The path must be one of the paths in the file manifest.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "File path, exactly as shown in the manifest.",
            },
          },
          required: ["path"],
        },
      },
    },
  ];
}

function previewArgs(argsJson: string): string {
  try {
    const parsed = JSON.parse(argsJson);
    return JSON.stringify(parsed);
  } catch {
    return truncate(argsJson, 80);
  }
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max) + "…";
}

function isUpfrontFile(path: string): boolean {
  const base = path.split("/").pop() ?? "";
  // Intro / overview docs. Matches case-insensitively, with or without
  // an extension: README, README.md, readme.txt, OVERVIEW, about.md, etc.
  if (/^(readme|overview|about|intro|description)(\.[^/]*)?$/i.test(base)) {
    return true;
  }
  // Package manifest files.
  if (/^mip\.(yaml|yml|json)$/i.test(base)) return true;
  return false;
}

function jsonResponse(data: unknown, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
    },
  });
}
