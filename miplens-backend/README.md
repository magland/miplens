# miplens-backend

Cloudflare Worker that generates AI overviews of MATLAB packages. The model
receives a manifest of all files up front, plus the full contents of any
READMEs and `mip.yaml`/`mip.json`, and uses a `read_file` tool to pull in
additional source as needed. Progress is streamed back as newline-delimited
JSON.

## Endpoint

```
POST /lens
Content-Type: application/json

{
  "packageName": "memorygraph",
  "files": [
    { "path": "README.md", "content": "..." },
    { "path": "+memorygraph/build.m", "content": "..." }
  ]
}
```

Response: `HTTP 200`, `Content-Type: application/x-ndjson`, one JSON
object per line:

```
{"type":"reading","path":"+memorygraph/build.m"}
{"type":"reading","path":"+memorygraph/query.m"}
{"type":"done","text":"memorygraph   ...\n"}
```

On failure the stream emits `{"type":"error","message":"..."}` and closes.

## Local development

```bash
npm install
echo 'OPENROUTER_API_KEY=sk-or-...' > .dev.vars
npm run dev        # listens on http://localhost:8787
```

To point MATLAB at your local dev server instead of the deployed one:

```matlab
setenv('MIPLENS_BACKEND_URL', 'http://localhost:8787/lens');
```

## Deploy

```bash
npx wrangler secret put OPENROUTER_API_KEY
npm run deploy
```

Override the model by editing `OPENROUTER_MODEL` in `wrangler.toml`.
