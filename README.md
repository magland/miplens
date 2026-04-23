# miplens

AI-generated overviews of MATLAB packages for the [MIP](https://mip.sh)
ecosystem.

## Installation

Install miplens from the `magland/magland` channel:

```matlab
mip install --channel magland/magland miplens
mip load miplens
```

## Usage

`miplens` looks up a package by name through mip, so the package you're
querying must also be installed and loaded. Install it, load it, then
run miplens on it:

```matlab
mip install export_fig
mip load export_fig
miplens export_fig
miplens export_fig how do I get started
```

Use the command form — it's the shortest and supports multi-word queries
without quoting:

```matlab
miplens export_fig
miplens export_fig what are the exported functions
miplens /path/to/package_dir
```

The directory form (`miplens /path/to/package_dir`) does not require
installation — it reads whatever is in the given directory.

Function form works too:

```matlab
miplens('export_fig')
miplens('export_fig', 'what are the exported functions?')
text = miplens('export_fig');   % capture instead of printing
```

As the backend reads files you'll see lines like:

```
  reading export_fig.m
  reading README.md
```

## How it works

1. `miplens` collects the `.m`, `.md`, `.yaml`, `.json`, and `README*`
   files under the package directory (recursively, skipping `.git`,
   `node_modules`, etc.).
2. It POSTs them to the miplens backend (see `miplens-backend/`).
3. The backend gives the model a file manifest plus the READMEs and
   `mip.yaml`, and exposes a `read_file` tool. The model reads the
   source files it needs and returns a MATLAB help-style overview.
4. Progress and the final text are streamed back as newline-delimited
   JSON and printed live.

See `miplens-backend/README.md` for backend deployment.
