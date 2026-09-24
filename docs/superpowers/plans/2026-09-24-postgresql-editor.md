# PostgreSQL Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved PostgreSQL editor with query results, schema browsing, editable table rows, and schema-aware completion.

**Architecture:** Neovim Lua owns buffers, commands, and completion. A long-running Python helper owns one Psycopg connection and answers newline-delimited JSON requests. The table browser stages changes in Lua and saves them through one Python transaction.

**Tech Stack:** Neovim 0.10+, Lua, Python 3.10+, Psycopg 3, PostgreSQL, Python `unittest`, headless Neovim tests.

**Spec:** `docs/superpowers/specs/2026-09-24-postgresql-editor-design.md`

## Global constraints

- PostgreSQL only; no required Neovim plugin dependency.
- Require Neovim 0.10+, Python 3.10+, and Psycopg 3. Recommend `psycopg[binary]` in installation docs.
- Keep passwords and connection strings out of logs. Use libpq connection settings and password files.
- Query results are read-only. Only existing, non-key cells in primary-key tables are editable. Views, generated columns, arrays, binary values, and unsupported custom types are read-only.
- Use bound Psycopg parameters for values and `psycopg.sql.Identifier` for identifiers. Never build SQL with user cell text.
- A table save is atomic and checks the original primary key and `xmin`. Preserve pending edits on failure.
- Table pages contain 100 rows. Query results default to 1,000 rows and 4 MiB of serialized output, with configurable caps.
- Completion uses Neovim's built-in UI. Schema refresh is explicit after DDL.

## File map and contracts

| File | Responsibility |
| --- | --- |
| `plugin/better_sql.lua` | Register user commands once. |
| `lua/better_sql/init.lua` | Configuration, active profile, orchestration. |
| `lua/better_sql/client.lua` | Python process, JSON framing, request IDs, callbacks. |
| `lua/better_sql/statement.lua` | Find the SQL statement at the cursor. |
| `lua/better_sql/results.lua` | Render read-only query result sets. |
| `lua/better_sql/schema.lua` | Render catalog tree and hold completion cache. |
| `lua/better_sql/table.lua` | Render paged grid and retain staged edits. |
| `lua/better_sql/completion.lua` | Detect SQL name context and provide omnifunc candidates. |
| `python/better_sql_helper.py` | Start the helper using Python's script-directory import path. |
| `python/better_sql/protocol.py` | Read/write one JSON object per line. |
| `python/better_sql/session.py` | Own connection and dispatch methods. |
| `python/better_sql/query.py` | Run user SQL and serialize result sets. |
| `python/better_sql/catalog.py` | Read schemas, relations, columns, types, and keys. |
| `python/better_sql/tables.py` | Page table rows and retain original row identity. |
| `python/better_sql/edits.py` | Validate and atomically apply staged edits. |
| `tests/python/`, `tests/integration/`, `tests/lua/` | Unit, database, and headless editor tests. |
| `tests/integration/support.py` | Shared DSN guard and isolated database fixture. |
| `README.md` | Install, configuration, workflow, limits, troubleshooting. |

The wire request is `{"id":1,"method":"query.run","params":{"sql":"select 1","max_rows":1000,"max_bytes":4194304}}`. A reply is `{"id":1,"ok":true,"result":{"sets":[]}}` or `{"id":1,"ok":false,"error":{"code":"database_error","message":"permission denied","sqlstate":"42501","position":null}}`. A cell is `{"text":"idan","is_null":false}`. Preserve column order with arrays. Lua's `Client:request(method, params, callback)` invokes `callback(error, result)`. Python's `Session.handle(method, params)` returns a result dict or raises a structured helper error.

The tasks below share one transport and build on earlier deliverables. Keep them in this order. Run the named focused test after each code change, then the full test command at each milestone boundary.

---

## Milestone 1: connection and query results

### Task 1: JSON helper protocol

**Files:**
- Create: `python/better_sql_helper.py`
- Create: `python/better_sql/__init__.py`
- Create: `python/better_sql/protocol.py`
- Test: `tests/python/test_protocol.py`

**Interfaces:**
- Produces: `serve(reader, writer, handler) -> None`, where `handler(method: str, params: dict) -> dict`.
- Produces: `ProtocolError(code: str, message: str)` and `encode_error(exc) -> dict`.

- [ ] **Step 1: Write a failing protocol test.**

```python
def test_one_request_one_response(self):
    source = io.StringIO('{"id":7,"method":"ping","params":{}}\n')
    sink = io.StringIO()
    serve(source, sink, lambda method, params: {"pong": method == "ping"})
    self.assertEqual(json.loads(sink.getvalue()), {
        "id": 7, "ok": True, "result": {"pong": True}
    })
```

Also test malformed JSON, missing method, and an exception from the handler. Each must produce one structured error line without writing protocol noise to stdout.

- [ ] **Step 2: Run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_protocol.py' -v`.** Expect import or assertion failure.
- [ ] **Step 3: Implement the framing and entry point.** Use `json.loads(line)`, emit `json.dumps(response, ensure_ascii=False) + "\n"`, and flush after each reply. The entry point passes requests to a temporary `ping` handler; an unknown method raises `ProtocolError("unknown_method", method)`. Keep imports of Psycopg out of this task so the protocol test can run before installing it.

```python
def reply(writer, request_id, result=None, error=None):
    message = {"id": request_id, "ok": error is None}
    message["result" if error is None else "error"] = result if error is None else error
    writer.write(json.dumps(message, ensure_ascii=False) + "\n")
    writer.flush()
```
- [ ] **Step 4: Run the focused test again and `PYTHONPATH=python python3 -m unittest discover -s tests/python -v`.** Expect all tests to pass.
- [ ] **Step 5: Commit with `git add python tests/python/test_protocol.py` and `git commit -m "feat: add Python JSON protocol"`.**

### Task 2: Lua process client and connection profiles

**Files:**
- Create: `lua/better_sql/client.lua`
- Create: `lua/better_sql/init.lua`
- Test: `tests/lua/test_client.lua`

**Interfaces:**
- Consumes: Task 1's line-delimited protocol.
- Produces: `Client.new({python = string, helper = string})`, `Client:start(on_exit)`, `Client:request(method, params, callback) -> integer`, `Client:stop()`.
- Produces: `require("better_sql").setup({connections = {name = conninfo}, python = "python3", max_rows = 1000, max_bytes = 4194304})`. Task 3 adds `connect(name, callback)` and registers the user command.

- [ ] **Step 1: Write a failing headless Neovim test.**

```lua
local Client = require("better_sql.client")
local client = Client.new({ python = "python3", helper = "python/better_sql_helper.py" })
local reply
client:start()
client:request("ping", {}, function(err, result)
  assert(err == nil)
  reply = result.pong
end)
assert(vim.wait(3000, function() return reply ~= nil end))
assert(reply == true)
client:stop()
```

Add a decoder test that feeds one JSON line in three chunks and two lines in one chunk. Check that callbacks fire once and in request-ID order.

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_client.lua`.** Expect module-not-found failure.
- [ ] **Step 3: Implement the client using `vim.system({python, "-u", helper}, {stdin = true, stdout = on_chunk, stderr = on_stderr}, on_exit)`. Buffer incomplete chunks until newline, decode complete lines with `vim.json.decode`, then `vim.schedule` callback delivery. Send with `process:write(vim.json.encode(request) .. "\n")`. Locate the helper with `vim.api.nvim_get_runtime_file("python/better_sql_helper.py", false)[1]`. Keep conninfo out of process arguments. Task 3 registers the profile picker and database connect behavior.

```lua
function Client:request(method, params, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.callbacks[id] = callback
  self.process:write(vim.json.encode({ id = id, method = method, params = params }) .. "\n")
  return id
end
```
- [ ] **Step 4: Run the focused Lua test and the Python protocol tests.** Expect both to pass.
- [ ] **Step 5: Commit with `git add lua tests/lua/test_client.lua` and `git commit -m "feat: connect Neovim to helper process"`.**

### Task 3: Psycopg connection and query execution

**Files:**
- Create: `requirements.txt`
- Create: `.gitignore`
- Create: `python/better_sql/session.py`
- Create: `python/better_sql/query.py`
- Modify: `python/better_sql_helper.py`
- Modify: `lua/better_sql/init.lua`
- Create: `plugin/better_sql.lua`
- Test: `tests/python/test_query.py`
- Test: `tests/integration/test_query.py`
- Test: `tests/integration/support.py`

**Interfaces:**
- Consumes: `serve` from Task 1 and the configured profiles from Task 2.
- Produces: `require("better_sql").connect(name, callback)`, which starts the client and sends the `connect` request.
- Produces: `Session.handle("connect", {"conninfo": str}) -> {"database": str, "user": str}`.
- Produces: `Session.handle("query.run", {"sql": str, "max_rows": int, "max_bytes": int}) -> {"sets": [ResultSet]}`.
- `ResultSet` has `columns: [{name, type_oid}]`, `rows: [[Cell]]`, `status: str`, and `truncated: bool`.
- Internal helper: `read_result_set(cursor, rows_left, bytes_left, cell_encoder) -> (ResultSet, used_rows, used_bytes)`. It consumes no rows for a command without `cursor.description`.

- [ ] **Step 1: Create `requirements.txt` containing `psycopg[binary]>=3.3,<4`, add `.venv/` and `__pycache__/` to `.gitignore`, and write failing tests for `NULL`, empty string, command status, multiple result sets, and caps.** In `tests/integration/support.py`, define a `unittest.TestCase` base that skips without `BETTER_SQL_TEST_DSN`, opens two connections when needed, and creates/drops an isolated test schema.

```python
def test_null_and_empty_are_distinct(self):
    result = run_query(self.conn, "select null::text as a, ''::text as b", 1000, 4194304)
    cells = result["sets"][0]["rows"][0]
    self.assertEqual(cells, [
        {"text": "", "is_null": True},
        {"text": "", "is_null": False},
    ])
```

Use `BETTER_SQL_TEST_DSN` for real PostgreSQL integration tests. Skip those tests when it is absent, but keep fake-cursor unit tests runnable everywhere.

- [ ] **Step 2: Install `python3 -m pip install -r requirements.txt` in a virtual environment, then run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_query.py' -v`.** Expect failure before implementation.
- [ ] **Step 3: Implement `Session` with `psycopg.connect(conninfo, autocommit=True)`. Implement `run_query` with a normal cursor, `cursor.execute(sql_text)`, `fetchmany()`, and `cursor.nextset()`. Serialize each value as text plus null flag. Apply the row and serialized-byte caps across all sets; set `truncated` when capped. Do not add `LIMIT` to user SQL. Use `cursor.description` and `cursor.statusmessage` for metadata and command status. Convert Psycopg errors to code `database_error` with SQLSTATE and statement position; keep conninfo out of the error.

```python
def cell(value):
    if value is None:
        return {"text": "", "is_null": True}
    if isinstance(value, (dict, list)):
        return {"text": json.dumps(value, ensure_ascii=False), "is_null": False}
    if isinstance(value, bytes):
        return {"text": "\\x" + value.hex(), "is_null": False}
    return {"text": str(value), "is_null": False}

def run_query(conn, sql_text, max_rows=1000, max_bytes=4194304):
    with conn.cursor() as cur:
        cur.execute(sql_text)
        sets = []
        rows_left, bytes_left = max_rows, max_bytes
        while True:
            result, used_rows, used_bytes = read_result_set(cur, rows_left, bytes_left, cell)
            sets.append(result)
            rows_left -= used_rows
            bytes_left -= used_bytes
            if result["truncated"]:
                return {"sets": sets}
            if not cur.nextset():
                return {"sets": sets}
```

In `init.lua`, `connect(name, callback)` sends `connect` with the selected profile's conninfo and records the active profile only after a successful response. Register `:BetterSqlConnect` in `plugin/better_sql.lua` with `vim.ui.select` for profile selection.
- [ ] **Step 4: Run focused unit tests and, when `BETTER_SQL_TEST_DSN` is set, `PYTHONPATH=python python3 -m unittest discover -s tests/integration -v`.** Verify DDL status and multiple results against PostgreSQL.
- [ ] **Step 5: Commit with `git add .gitignore requirements.txt python lua/better_sql/init.lua plugin/better_sql.lua tests/python/test_query.py tests/integration/test_query.py tests/integration/support.py` and `git commit -m "feat: execute PostgreSQL queries"`.**

### Task 4: PostgreSQL statement selection

**Files:**
- Create: `lua/better_sql/statement.lua`
- Test: `tests/lua/test_statement.lua`

**Interfaces:**
- Produces: `statement.at_cursor(lines: string[], row: integer, col: integer) -> {sql: string, start_row: integer, start_col: integer, end_row: integer, end_col: integer}|nil`. Rows and columns are zero-based byte offsets.

- [ ] **Step 1: Write failing examples for semicolons in ordinary text, single quotes, doubled quotes, dollar quotes, line comments, nested block comments, and quoted identifiers.**

```lua
local statement = require("better_sql.statement")
local lines = { "select ';' as value;", "select 2;" }
local hit = statement.at_cursor(lines, 1, 3)
assert(hit.sql == "select 2;")
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_statement.lua`.** Expect module-not-found failure.
- [ ] **Step 3: Implement one left-to-right lexical scan of the buffer.** Track states `normal`, `single_quote`, `double_quote`, `dollar_quote(tag)`, `line_comment`, and `block_comment(depth)`. Only a semicolon in `normal` ends a statement. Preserve original SQL bytes; trim only surrounding whitespace when returning a slice. Include the cursor's statement even when the cursor sits on its final semicolon.

```lua
if state == "normal" and char == ";" then
  spans[#spans + 1] = { first = statement_start, last = byte_index }
  statement_start = byte_index + 1
end
```

The scanner must consume doubled quote characters as one escaped quote, match the opening dollar tag exactly, and increment/decrement depth for nested block comments.
- [ ] **Step 4: Run the focused Lua test.** Expect all examples to pass.
- [ ] **Step 5: Commit with `git add lua/better_sql/statement.lua tests/lua/test_statement.lua` and `git commit -m "feat: select SQL statement at cursor"`.**

### Task 5: Query commands and result grid

**Files:**
- Create: `lua/better_sql/results.lua`
- Modify: `lua/better_sql/init.lua`
- Modify: `plugin/better_sql.lua`
- Test: `tests/lua/test_results.lua`

**Interfaces:**
- Consumes: `Client:request`, `statement.at_cursor`, and Task 3's `query.run` result.
- Produces: `results.show(result, profile_name) -> buffer` and `results.select_set(index)`.
- Produces: `:BetterSqlRun` and `:BetterSqlRunBuffer`.

- [ ] **Step 1: Write failing UI tests for two result sets, a command status, `NULL`, empty string, truncated data, and read-only buffers.**

```lua
local results = require("better_sql.results")
local buf = results.show({
  sets = {{ columns = {{ name = "id" }}, rows = {{{ text = "7", is_null = false }}},
    status = "SELECT 1", truncated = false }}
}, "local")
assert(vim.bo[buf].modifiable == false)
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("id"))
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_results.lua`.** Expect failure.
- [ ] **Step 3: Render each set in a scratch split using measured display widths, horizontal scrolling, a visible `NULL` marker, and a distinct empty-string cell. Show `Result 1/N`, status, and truncation. Register commands: use the active visual range when present, otherwise `statement.at_cursor`; `:BetterSqlRunBuffer` sends the entire buffer. Pass configured `max_rows` and `max_bytes` with every request. Keep the source buffer unchanged. Add next/previous result-set mappings local to the result buffer.

```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].bufhidden = "wipe"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
vim.bo[buf].modifiable = false
```

For visual selections, use the command range provided by Neovim rather than stale `'<`/`'>` marks. Map database errors back to the source buffer retained by the request.
- [ ] **Step 4: Run the focused Lua test and the milestone-1 smoke test: connect to `BETTER_SQL_TEST_DSN`, run `select 1 as id`, inspect the result buffer, and run a DDL statement.** Expect both row output and command status.
- [ ] **Step 5: Commit with `git add lua plugin tests/lua/test_results.lua` and `git commit -m "feat: show SQL query results"`.**

---

## Milestone 2: schema tree and table browsing

### Task 6: PostgreSQL catalog model

**Files:**
- Create: `python/better_sql/catalog.py`
- Modify: `python/better_sql/session.py`
- Test: `tests/python/test_catalog.py`
- Test: `tests/integration/test_catalog.py`

**Interfaces:**
- Produces: `load_catalog(conn) -> {"schemas": [Schema]}` and `Session.handle("catalog.load", {}) -> catalog`.
- `Schema` has `name` and `relations`. Each relation has `schema`, `name`, `kind`, `primary_key: [column_name]`, and ordered `columns`. Each column has `name`, `type_schema`, `type_name`, `type_label`, `editable`, and `read_only_reason`.

- [ ] **Step 1: Write tests for an ordinary table, composite primary key, quoted names, generated column, view, and an unsupported array column.**

```python
def test_primary_key_order(self):
    catalog = load_catalog(self.conn)
    public = next(s for s in catalog["schemas"] if s["name"] == "public")
    table = next(r for r in public["relations"] if r["name"] == "orders")
    self.assertEqual(table["primary_key"], ["tenant_id", "order_id"])
    generated = next(c for c in table["columns"] if c["name"] == "generated_total")
    self.assertFalse(generated["editable"])
```

- [ ] **Step 2: Run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_catalog.py' -v`.** Expect failure.
- [ ] **Step 3: Query `pg_namespace`, `pg_class`, `pg_attribute`, `pg_type`, and `pg_constraint`. Filter system schemas and dropped columns. Preserve `attnum` and primary-key constraint order; do not alphabetize columns. Mark only base and partitioned tables with primary keys as potentially editable. Build the type allowlist from type OIDs and `typtype`; exclude generated and key columns. Use a version-aware catalog query for servers that lack `pg_attribute.attgenerated`. Return the full tree in one response.

```sql
SELECT n.nspname, c.relname, c.relkind, a.attname, a.attnum,
       tn.nspname AS type_schema, t.typname AS type_name,
       t.typtype
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.oid
JOIN pg_catalog.pg_type AS t ON t.oid = a.atttypid
JOIN pg_catalog.pg_namespace AS tn ON tn.oid = t.typnamespace
WHERE c.relkind IN ('r', 'p', 'v')
  AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, c.relname, a.attnum;
```

Read primary-key position from `pg_constraint.conkey` for `contype = 'p'` in a second query; include key columns in constraint order.
For the first release, accept `pg_catalog` type names `text`, `varchar`, `bpchar`, `int2`, `int4`, `int8`, `numeric`, `float4`, `float8`, `bool`, `uuid`, `date`, `time`, `timetz`, `timestamp`, `timestamptz`, `json`, and `jsonb`, plus enum types with `typtype = 'e'`. Mark other types read-only with a reason.
- [ ] **Step 4: Run focused unit and integration tests, then inspect a real catalog JSON response.** Expect ordered columns, keys, type names, and read-only reasons.
- [ ] **Step 5: Commit with `git add python/better_sql/catalog.py python/better_sql/session.py tests/python/test_catalog.py tests/integration/test_catalog.py` and `git commit -m "feat: inspect PostgreSQL catalog"`.**

### Task 7: Schema browser and cache

**Files:**
- Create: `lua/better_sql/schema.lua`
- Modify: `lua/better_sql/init.lua`
- Modify: `plugin/better_sql.lua`
- Test: `tests/lua/test_schema.lua`

**Interfaces:**
- Consumes: Task 6's `catalog.load` response.
- Produces: `schema.set_catalog(catalog)`, `schema.get_catalog() -> catalog|nil`, and `schema.show(on_open_relation) -> buffer`.
- Produces: `:BetterSqlSchema` and `:BetterSqlRefreshSchema`.
- Internal helper: `render_tree(state)` updates the scratch buffer and its line-to-node map.

- [ ] **Step 1: Write a failing tree test.**

```lua
local schema = require("better_sql.schema")
schema.set_catalog({ schemas = {{ name = "public", relations = {
  { schema = "public", name = "users", kind = "table",
    columns = {{ name = "id", type_label = "integer" }} }
}}} })
local buf = schema.show(function() end)
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:find("users", 1, true))
assert(text:find("id", 1, true))
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_schema.lua`.** Expect failure.
- [ ] **Step 3: Render a scratch tree with stable node IDs in buffer-local state. `<CR>` expands a schema or relation and opens a relation through `on_open_relation(schema, name)`. Keep the catalog immutable in the cache. `:BetterSqlRefreshSchema` calls `catalog.load` again and replaces the cache; do not infer schema refresh from user SQL. Show connection and loading/error state.

```lua
local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
if node.kind == "relation" then
  state.on_open_relation(node.schema, node.name)
else
  state.expanded[node.id] = not state.expanded[node.id]
  render_tree(state)
end
```
- [ ] **Step 4: Run the focused Lua test and open the tree against an integration database.** Expect schemas, tables, views, columns, and a working explicit refresh.
- [ ] **Step 5: Commit with `git add lua/better_sql/schema.lua lua/better_sql/init.lua plugin/better_sql.lua tests/lua/test_schema.lua` and `git commit -m "feat: browse PostgreSQL schema"`.**

### Task 8: Paged table reads and row handles

**Files:**
- Create: `python/better_sql/tables.py`
- Modify: `python/better_sql/session.py`
- Test: `tests/python/test_tables.py`
- Test: `tests/integration/test_tables.py`

**Interfaces:**
- Consumes: relation metadata from `load_catalog`.
- Produces: `TableStore.page(conn, relation, offset: int, limit: int = 100, retain_handles: list[str] | None = None) -> Page` and `Session.handle("table.page", {"schema": str, "table": str, "offset": int, "retain_handles": [str]}) -> Page`.
- `Page` has `columns`, `rows: [{handle, key, cells}]`, `offset`, `has_more`, `editable`, and `read_only_reason`. `key` is an ordered array of primary-key `Cell` values. It is empty for views and keyless tables. Lua keeps it to match staged edits after reconnect.

- [ ] **Step 1: Write failing tests for 101 rows, composite-key ordering, a view, a keyless table, quoted identifiers, and explicit null cells.**

```python
def test_page_has_more(self):
    first = self.store.page(self.conn, self.users, 0, 100)
    self.assertEqual(len(first["rows"]), 100)
    self.assertTrue(first["has_more"])
    second = self.store.page(self.conn, self.users, 100, 100)
    self.assertEqual(len(second["rows"]), 1)
```

- [ ] **Step 2: Run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_tables.py' -v`.** Expect failure.
- [ ] **Step 3: Build the relation and key SQL with `psycopg.sql.Identifier`. Fetch `limit + 1` rows using bound `LIMIT` and `OFFSET`. Order editable tables by all key columns. Include `xmin::text` only for editable base tables; views and keyless tables return no editable handles. Return ordered key cells with each editable row. Keep typed original row values, key values, and `xmin` in a map keyed by opaque handles. On page change, discard old unpinned handles but retain every handle named in `retain_handles`.

```python
relation_id = sql.Identifier(relation["schema"], relation["name"])
order = sql.SQL(", ").join(sql.Identifier(name) for name in relation["primary_key"])
query = sql.SQL("SELECT *, xmin::text FROM {} ORDER BY {} LIMIT %s OFFSET %s").format(
    relation_id, order
)
cur.execute(query, (limit + 1, offset))
```

Use a separate `SELECT * FROM {} LIMIT %s OFFSET %s` query for views and keyless tables; display their unstable paging order as a read-only warning.
- [ ] **Step 4: Run unit and integration tests.** Verify exactly 100 displayed rows, correct `has_more`, and preserved raw values for later edits.
- [ ] **Step 5: Commit with `git add python/better_sql/tables.py python/better_sql/session.py tests/python/test_tables.py tests/integration/test_tables.py` and `git commit -m "feat: page table rows"`.**

### Task 9: Table grid and paging controls

**Files:**
- Create: `lua/better_sql/table.lua`
- Modify: `lua/better_sql/init.lua`
- Modify: `lua/better_sql/schema.lua`
- Test: `tests/lua/test_table.lua`

**Interfaces:**
- Consumes: `table.page` and `schema.show(on_open_relation)`.
- Produces: `table.open(client, relation) -> buffer`, `table.render(page) -> buffer`, `table.next_page()`, and `table.previous_page()`.

- [ ] **Step 1: Write a failing table-grid test.**

```lua
local grid = require("better_sql.table")
local buf = grid.render({
  columns = {{ name = "id" }, { name = "username" }},
  rows = {{ handle = "r1", cells = {
    { text = "1", is_null = false }, { text = "idan", is_null = false }
  }}}, offset = 0, has_more = false, editable = true
})
assert(vim.bo[buf].modifiable == false)
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("idan", 1, true))
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_table.lua`.** Expect failure.
- [ ] **Step 3: Render a fixed-header scratch grid with horizontal scroll and per-cell cursor navigation. Add `]p` and `[p` for page requests. Include the current pending row handles in each `table.page` request's `retain_handles` field. Show active profile, relation name, page range, loading state, and read-only reason. Treat `NULL` and empty string distinctly; show full clipped cell text in a small detail view. Preserve the selected column when changing rows and pages.

```lua
vim.keymap.set("n", "]p", function() table_view.next_page() end, { buffer = buf })
vim.keymap.set("n", "[p", function() table_view.previous_page() end, { buffer = buf })
vim.bo[buf].modifiable = false
```

Keep a separate mapping from screen columns to `{row_handle, column_name}`, so navigation never infers a cell from printed separator characters.
- [ ] **Step 4: Run the focused Lua test and milestone-2 smoke flow: open the schema tree, open a table, advance and return a page, and open a view read-only.** Expect the same column order and correct page indicators.
- [ ] **Step 5: Commit with `git add lua/better_sql/table.lua lua/better_sql/init.lua lua/better_sql/schema.lua tests/lua/test_table.lua` and `git commit -m "feat: browse table rows in a grid"`.**

---

## Milestone 3: staged table editing

### Task 10: Atomic save and conflict detection

**Files:**
- Create: `python/better_sql/edits.py`
- Modify: `python/better_sql/tables.py`
- Modify: `python/better_sql/session.py`
- Test: `tests/python/test_edits.py`
- Test: `tests/integration/test_edits.py`

**Interfaces:**
- Consumes: `TableStore` row handles and Task 6's column metadata.
- Produces: `save_edits(conn, store, relation, edits: list[dict]) -> {"rows": [updated_row]}`.
- Produces: `Session.handle("table.save", {"schema": str, "table": str, "edits": [{"handle": str, "changes": [{"column": str, "text": str, "is_null": bool}]}]}) -> result`.

- [ ] **Step 1: Write failing tests for a successful two-row save, invalid numeric text, a constraint error, a concurrent update, a deleted row, quoted identifiers, and a `NULL` assignment.**

```python
def test_conflict_rolls_back_other_rows(self):
    rows = self.store.page(self.conn, self.table, 0)["rows"]
    first, stale = rows[0]["handle"], rows[1]["handle"]
    self.other_conn.execute("update public.users set username = 'other' where id = 2")
    with self.assertRaises(EditConflict):
        save_edits(self.conn, self.store, self.table, [
            {"handle": first, "changes": [
                {"column": "username", "text": "mine", "is_null": False}
            ]},
            {"handle": stale, "changes": [
                {"column": "username", "text": "mine", "is_null": False}
            ]}
        ])
    self.assertEqual(self.username_for(1), "original")
    self.assertEqual(self.username_for(2), "other")
```

- [ ] **Step 2: Run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_edits.py' -v`.** Expect failure.
- [ ] **Step 3: Validate every handle and column against stored metadata. Compose one `UPDATE` per changed row with quoted schema/table/column/type identifiers, `%s` values cast to the column type, original key predicates, and `xmin = %s::xid`. Require one `RETURNING` row. Execute all updates inside `with conn.transaction():` on the autocommit connection. Raise `EditConflict` on zero rows; allow database errors to roll back the whole batch. Refresh stored originals and versions only after commit.

```python
assignments = sql.SQL(", ").join(
    sql.SQL("{} = %s::{}").format(
        sql.Identifier(column["name"]),
        sql.Identifier(column["type_schema"], column["type_name"]),
    )
    for column in changed_columns
)
query = sql.SQL("UPDATE {} SET {} WHERE {} AND xmin = %s::xid RETURNING *, xmin::text").format(
    sql.Identifier(relation["schema"], relation["name"]), assignments, key_predicate
)
with conn.transaction():
    cur.execute(query, tuple(new_values + original_key_values + [original_xmin]))
    if cur.rowcount != 1:
        raise EditConflict("row changed since it was loaded")
```

Build `key_predicate` from each primary-key column as `identifier = %s::type_identifier` joined with `AND`. This explicit cast also covers enum keys. Repeat the update for every dirty row inside the same transaction.
- [ ] **Step 4: Run focused and real PostgreSQL integration tests.** Confirm a failed second update leaves the first unchanged and no dirty value is silently accepted.
- [ ] **Step 5: Commit with `git add python/better_sql/edits.py python/better_sql/tables.py python/better_sql/session.py tests/python/test_edits.py tests/integration/test_edits.py` and `git commit -m "feat: save table edits atomically"`.**

### Task 11: Stage, review, save, and recover cell edits

**Files:**
- Modify: `lua/better_sql/table.lua`
- Modify: `lua/better_sql/init.lua`
- Test: `tests/lua/test_table_edits.lua`

**Interfaces:**
- Consumes: Task 10's `table.save`.
- Produces: `table.stage(handle, column, text, is_null)`, `table.discard(handle, column)`, `table.pending_count() -> integer`, and `table.save(callback)`.

- [ ] **Step 1: Write failing tests for `e`, `N`, `u`, save success, save failure, paging away and back, and connection switching with pending edits.**

```lua
local grid = require("better_sql.table")
grid.stage("r1", "username", "", false)
assert(grid.pending_count() == 1)
grid.stage("r1", "email", "", true)
assert(grid.pending_count() == 2)
grid.discard("r1", "username")
assert(grid.pending_count() == 1)
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_table_edits.lua`.** Expect failure.
- [ ] **Step 3: Use `vim.ui.input` for `e`, a separate `N` action for SQL `NULL`, `u` for one-cell discard, and `s` for one atomic `table.save` request. Mark staged cells and show pending count. Keep the map keyed by row handle and column across pages, with the row's ordered key cells alongside it. On server error, retain the map and show row/column details. On success, replace changed rows and clear only saved edits. Before changing profiles, prompt to save, discard, or stay. After reconnect, reload rows and match staged values by original primary key for review; never send stale handles.

```lua
function table_view.stage(handle, column, text, is_null)
  state.pending[handle] = state.pending[handle] or {}
  state.keys[handle] = state.loaded_rows[handle].key
  state.pending[handle][column] = { text = text, is_null = is_null }
  render_grid(state)
end
```

Build one `table.save` request from `state.pending`. Clear entries only when its response succeeds; keep the old map unchanged on error or disconnect.
- [ ] **Step 4: Run focused Lua tests and milestone-3 integration flow: edit two rows, force a conflict, verify rollback, reload, restage, and save.** Expect the exact database values and a clean grid after success.
- [ ] **Step 5: Commit with `git add lua/better_sql/table.lua lua/better_sql/init.lua tests/lua/test_table_edits.lua` and `git commit -m "feat: stage and save table cell edits"`.**

---

## Milestone 4: completion, reliability, and release checks

### Task 12: Schema-aware completion

**Files:**
- Create: `lua/better_sql/completion.lua`
- Modify: `lua/better_sql/init.lua`
- Test: `tests/lua/test_completion.lua`

**Interfaces:**
- Consumes: `schema.get_catalog()` and the SQL lexical rules from `statement.lua`.
- Produces: `completion.suggest(line: string, cursor_col: integer, catalog: table) -> string[]` and `completion.omnifunc(findstart, base)`.

- [ ] **Step 1: Write failing completion examples for `FROM us`, `JOIN us`, `users.`, `u.` after `FROM users u`, schema-qualified names, comments, and string literals.**

```lua
local completion = require("better_sql.completion")
local names = completion.suggest("SELECT users.", #"SELECT users.", catalog)
assert(vim.tbl_contains(names, "username"))
assert(not vim.tbl_contains(names, "orders"))
```

- [ ] **Step 2: Run `nvim --headless -u NONE -l tests/lua/test_completion.lua`.** Expect failure.
- [ ] **Step 3: Reuse the statement scanner's token states to suppress completion inside quotes and comments. Resolve a qualifier to a table name or an alias from `FROM` and `JOIN` clauses in the current statement. Build candidates from the cached catalog, respecting schema qualification and prefix. Set `omnifunc` only on SQL buffers. Schedule `vim.fn.complete(start_col, matches)` after `.` in insert mode, after confirming the cursor still occupies the same buffer and position; do not override an existing popup.

```lua
local relation_name = aliases[qualifier] or qualifier
local relation = find_relation(catalog, schema_name, relation_name)
if relation then
  for _, column in ipairs(relation.columns) do
    if vim.startswith(column.name, prefix) then
      matches[#matches + 1] = column.name
    end
  end
end
```

`find_relation` and `aliases` are local helpers in `completion.lua`. Tests must cover quoted relation names and no suggestions inside a comment.
- [ ] **Step 4: Run focused Lua tests and manually type `SELECT users.` and `SELECT u.` after `FROM users u` in a headless or interactive test database.** Expect only matching columns.
- [ ] **Step 5: Commit with `git add lua/better_sql/completion.lua lua/better_sql/init.lua tests/lua/test_completion.lua` and `git commit -m "feat: complete schema names in SQL"`.**

### Task 13: Cancellation, reconnect, and diagnostics

**Files:**
- Modify: `python/better_sql/protocol.py`
- Modify: `python/better_sql/session.py`
- Modify: `lua/better_sql/client.lua`
- Modify: `lua/better_sql/init.lua`
- Modify: `lua/better_sql/results.lua`
- Test: `tests/python/test_cancel.py`
- Test: `tests/integration/test_cancel.py`
- Test: `tests/lua/test_recovery.lua`

**Interfaces:**
- Produces: `Session.cancel(target_id: int) -> {"cancel_requested": bool}` and `Client:cancel(target_id, callback)`.
- Extends protocol with `query.cancel`, which can be processed while another request is running.

- [ ] **Step 1: Write failing tests for a long-running `pg_sleep` query, cancellation, a usable connection afterward, helper death with pending callbacks, and redaction of a conninfo password.**

```python
def test_cancel_keeps_session_usable(self):
    request_id = self.start_query("select pg_sleep(10)")
    self.cancel(request_id)
    self.assertEqual(self.run_query("select 1")["sets"][0]["rows"][0][0]["text"], "1")
```

- [ ] **Step 2: Run `PYTHONPATH=python python3 -m unittest discover -s tests/python -p 'test_cancel.py' -v` and `nvim --headless -u NONE -l tests/lua/test_recovery.lua`.** Expect failure.
- [ ] **Step 3: Let the protocol reader remain active while one worker thread runs the database request. Reject another normal request with `busy`; let `query.cancel` call `conn.cancel_safe()` when available, otherwise `conn.cancel()`. Guard response writes with a lock so JSON lines never interleave. On helper exit, fail all outstanding Lua callbacks, keep visible staged edits, and offer reconnect. Map Psycopg diagnostics to `sqlstate` and `position`, jump to the SQL source position where available, and omit credentials from messages and stderr.

```python
def cancel_active(self, target_id):
    if target_id != self.active_request_id:
        return {"cancel_requested": False}
    cancel = getattr(self.connection, "cancel_safe", self.connection.cancel)
    cancel()
    return {"cancel_requested": True}
```

The main protocol loop handles `query.cancel` immediately; a worker executes other methods. After cancellation, classify SQLSTATE `57014` as cancelled and test a following `select 1` on the same session.
- [ ] **Step 4: Run focused tests and the integration cancellation test.** Confirm the editor responds during `pg_sleep`, cancellation returns, the next query works, and no secret appears in captured output.
- [ ] **Step 5: Commit with `git add python lua tests/python/test_cancel.py tests/integration/test_cancel.py tests/lua/test_recovery.lua` and `git commit -m "feat: cancel queries and recover connections"`.**

### Task 14: Documentation and end-to-end release gate

**Files:**
- Create: `README.md`
- Create: `tests/lua/test_e2e.lua`
- Modify: `requirements.txt` if installation testing finds a missing runtime package

**Interfaces:**
- Consumes all public commands and the documented configuration from Tasks 1–13.
- Produces a reproducible end-to-end test and complete installation guide.

- [ ] **Step 1: Write a failing end-to-end test against `BETTER_SQL_TEST_DSN`.**

```lua
require("better_sql").setup({
  connections = { test = vim.env.BETTER_SQL_TEST_DSN },
  python = vim.env.BETTER_SQL_PYTHON or "python3",
})
local connected = false
require("better_sql").connect("test", function(err)
  assert(err == nil)
  connected = true
end)
assert(vim.wait(5000, function() return connected end))
```

Extend this script to create a temporary test table, run a query, refresh and inspect the schema, page the table, stage and save a cell, and ask completion for its column. Clean up the table in the test fixture. Do not skip this script when the DSN is configured.

- [ ] **Step 2: With `BETTER_SQL_TEST_DSN` exported, run `nvim --headless -u NONE -l tests/lua/test_e2e.lua`.** Expect an initial failure at the first missing integration behavior.
- [ ] **Step 3: Write `README.md` with `pip install "psycopg[binary]"`, a named-connection `setup` example, libpq password-file guidance, every command and grid key, data-type and edit limits, result caps, schema refresh, and a short SQL-to-table-edit walkthrough. Resolve any end-to-end failure in the module that owns the failing behavior, then rerun the test. Keep runtime installation to Python and Psycopg only.

```lua
require("better_sql").setup({
  python = vim.fn.exepath("python3"),
  connections = {
    localdb = "service=localdb",
  },
  max_rows = 1000,
  max_bytes = 4194304,
})
```

Document that the connection profile's service name resolves through libpq and that a password file can provide credentials without storing them in Neovim configuration.
- [ ] **Step 4: Run all Python unit tests, all headless Lua tests, all PostgreSQL integration tests with a real DSN, and the end-to-end script. Also run `git diff --check` and inspect the full diff for missing spec requirements.** Use the commands below and record their outcomes in the final implementation report.

```bash
PYTHONPATH=python python3 -m unittest discover -s tests/python -v
PYTHONPATH=python python3 -m unittest discover -s tests/integration -v
for test_file in tests/lua/test_*.lua; do nvim --headless -u NONE -l "$test_file"; done
nvim --headless -u NONE -l tests/lua/test_e2e.lua
git diff --check
```
- [ ] **Step 5: Commit with `git add README.md requirements.txt tests/lua/test_e2e.lua lua python tests` and `git commit -m "docs: document and verify PostgreSQL editor"`.**

## Execution notes

Start each task by reading the approved spec and the relevant interfaces above. Keep commits scoped to the task; when a test exposes a defect in an earlier task, fix that defect in the current task and mention it in the commit. Do not commit real DSNs, passwords, or generated database dumps.

Each Lua test begins with `vim.opt.rtp:append(vim.fn.getcwd())` before requiring the plugin. Tests that start the Python helper set `python` to the interpreter where Psycopg was installed. Integration tests use `BETTER_SQL_TEST_DSN` and must not silently skip during the final release gate.

The current workspace has Neovim 0.12.5 and Python 3.14.7. Psycopg and `psql` are unavailable here. Unit and headless Lua tests can begin immediately; the database integration gate needs a real PostgreSQL DSN when implementation starts.
