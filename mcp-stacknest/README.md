# stacknest MCP server

Operate a StackNest library over MCP (wraps `stacknest-cli` via subprocess).
StackNest.app must be running with "Settings ▸ General ▸ Local Access" turned ON.

## Setup

```bash
cd mcp-stacknest
python3 -m venv .venv
./.venv/bin/pip install -U pip
./.venv/bin/pip install -r requirements.txt
```

**To reinstall dependencies into an existing `.venv` without recreating it**, the command
depends on how that venv was created. The current `.venv` was built with `uv` and **does
not bundle `pip`**, so the command above fails with `No such file or directory`
(found while recovering it on 2026-08-08).

```bash
uv pip install -r requirements.txt --python .venv/bin/python
```

The quickest way to check whether the dependencies are broken is to see if `server.py`
can be imported:

```bash
./.venv/bin/python -c "import server; print('server module OK')"
```

## Registering with Claude Code (`mcpServers` in `~/.claude.json`)

```json
"stacknest": {
  "type": "stdio",
  "command": "<repo>/mcp-stacknest/.venv/bin/python",
  "args": ["<repo>/mcp-stacknest/server.py"]
}
```

`<repo>` is `.../homelab/stacknest`.

`STACKNEST_CLI` is **optional** (usually not needed).
At startup, the MCP resolves `stacknest-cli` in this order:

1. If the `STACKNEST_CLI` environment variable is set, use its value
2. Use the bundled CLI's absolute path that StackNest.app recorded at launch under
   `app.shelfsmith.stacknest` → `cli_path` (`StackNest.app/Contents/Helpers/stacknest-cli`)
3. Fall back to `stacknest-cli` on PATH

Normally just launching StackNest.app once is enough for the bundled CLI to resolve
automatically, so setting `STACKNEST_CLI` isn't needed.
Only set `env.STACKNEST_CLI` if you want to use a custom path:

```json
"stacknest": {
  "type": "stdio",
  "command": "<repo>/mcp-stacknest/.venv/bin/python",
  "args": ["<repo>/mcp-stacknest/server.py"],
  "env": { "STACKNEST_CLI": "/path/to/stacknest-cli" }
}
```

After registering, restart Claude Code to load the MCP.

## Tools

### Library and books (basics)

- `stacknest_libraries()` — list of libraries (id/name/bookCount/locked).
- `stacknest_list(library, query?, limit?)` — a page of books (items: id and metadata; total: overall count; limit maxes out at 500).
- `stacknest_detail(library, id)` — all metadata for one book.
- `stacknest_facets(library, field)` — distinct values for a field (e.g. author/genre).
- `stacknest_me()` — the connection token's permissions (role/tier/scope).
- `stacknest_add(library, paths[], preset?)` — add server-local paths (in place).
- `stacknest_set(library, id, title?/author?/series?/volume?/genre?/keyword_a?/keyword_b?/memo?/neta?/rating?/unseen?/book_type?/direction?)` — edit metadata. `unseen` is bool, `book_type` is an integer, `direction` is `ltr`/`rtl`.
- `stacknest_remove(library, ids[], trash?)` — remove (destructive; `trash=True` also moves the files to the macOS Trash).

### Shelf CRUD

- `stacknest_shelves(library)` — list of shelves (smart and manual).
- `stacknest_shelf_create(library, title, smart?, conditions?)` — create a shelf. `smart=True` makes a smart shelf; pass the condition dict via `conditions`.
- `stacknest_shelf_delete(library, shelf_id)` — delete a shelf (the books it contains stay in the library).
- `stacknest_shelf_rename(library, shelf_id, title)` — rename a shelf.
- `stacknest_shelf_conditions_get(library, shelf_id)` — get a smart shelf's condition JSON.
- `stacknest_shelf_conditions_set(library, shelf_id, conditions)` — update a smart shelf's condition JSON.
- `stacknest_shelf_add_books(library, shelf_id, ids[])` — add books to a manual shelf.
- `stacknest_shelf_remove_books(library, shelf_id, ids[])` — remove books from a manual shelf.

### Watched folders

- `stacknest_watch_get(library)` — get the watched-folder settings.
- `stacknest_watch_set(library, config)` — update the watched-folder settings. `config` has the shape `{"folders":["/path"],"preset":"standard"}`.

### Lock

- `stacknest_lock_set(library, password)` — set a password lock. **The password is passed via the CLI's stdin and never appears in the process's argv** (secure).
- `stacknest_lock_clear(library)` — remove the password lock.

### Import settings

- `stacknest_import_config_get(library)` — get the library's import settings.
- `stacknest_import_config_set(library, auto_classify?, thick?, preset?)` — update the library's import settings.
- `stacknest_import_config_global_get()` — get the global import settings.
- `stacknest_import_config_global_set(auto_classify?, thick?, preset?)` — update the global import settings.

### Relink and duplicate detection

- `stacknest_relink(library, id, new_path)` — repair a link after a file was moved (updates the book's absolute path).
- `stacknest_dedup_scan(library, query?)` — scan for duplicate candidates and return the list.

`library` is a library name or UUID (see `stacknest_libraries`). `id`/`shelf_id` come from each list/shelves tool.

## Lock security design

`stacknest_lock_set` uses the CLI mode that takes the password via the `--password-stdin` flag.
The password string is passed as **stdin** via `subprocess.run(..., input=password)`, so it never
appears in the process list (`ps aux`, etc.).

## Connection

The CLI auto-detects the connection from the same Mac's UserDefaults (`app.shelfsmith.stacknest`).
To use a remote server or similar, set `STACKNEST_URL` / `STACKNEST_TOKEN` in the environment and
they pass through to the CLI.

## Tests

```bash
./.venv/bin/python -m pytest tests/ -q
```
(Covers `cli.py`'s pure logic — building argv, parsing JSON, and converting exit codes to exceptions. subprocess is mocked.)
