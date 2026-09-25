# better-sql.nvim

Browse PostgreSQL schemas, run SQL, complete table and column names, and edit existing table cells in Neovim. Query results are read-only. Table edits stay staged until you save them together.

## Quick start

1. Install Neovim 0.10 or newer and Python 3.10 or newer. Make sure Neovim can reach your PostgreSQL database. Create a Python environment for the plugin:

   ```sh
   python3 -m venv ~/.local/share/better-sql-venv
   ~/.local/share/better-sql-venv/bin/python -m pip install "psycopg[binary]>=3.3,<4"
   ```

2. If your Lazy setup imports `lua/plugins`, create `~/.config/nvim/lua/plugins/better_sql.lua` with this content. Otherwise, add the inner plugin spec to your Lazy plugin list:

   ```lua
   return {
     {
       "w0x7y/better-sql.nvim",
       main = "better_sql",
       lazy = false,
       opts = {
         python = vim.fn.expand("~/.local/share/better-sql-venv/bin/python"),
         connections = {
           dev = "service=devdb",
         },
       },
     },
   }
   ```

   This repository is private. Make sure Git can access it before Lazy installs it; if you use GitHub CLI, run [`gh auth setup-git`](https://cli.github.com/manual/gh_auth_setup-git).

3. Define `devdb` in `~/.pg_service.conf`. If the server needs a password, add it to `~/.pgpass`. See [Connections and credentials](#connections-and-credentials).
4. Open a `.sql` file, run `:BetterSqlConnect`, and select `dev`. Type `SELECT current_database();`, put the cursor on that statement, and run `:BetterSqlRun`. Results open below your SQL window.
5. Run `:BetterSqlSchema` to browse the database. Select a table or view and press `<CR>` to open its rows.

`psql` and a completion plugin are not required. If your chosen Python already has Psycopg 3.3 or newer, set `python` to that interpreter. You can also install the repository as a normal Neovim package instead of using `lazy.nvim`.

## Connections and credentials

`connections` maps the names shown by `:BetterSqlConnect` to libpq connection strings or PostgreSQL URIs. Keep passwords out of your Neovim configuration. For the quick-start profile, a service file can hold the connection settings:

```ini
# ~/.pg_service.conf
[devdb]
host=localhost
port=5432
dbname=appdb
user=appuser
```

If the server needs a password, add a matching entry to `~/.pgpass`:

```text
localhost:5432:appdb:appuser:your-password
```

Run `chmod 600 ~/.pgpass` on Unix. Libpq also supports `PGSERVICEFILE` and `PGPASSFILE` for custom file locations, plus standard variables such as `PGHOST`, `PGPORT`, `PGDATABASE`, and `PGUSER`. The Python helper inherits Neovim's environment.

A profile can also use a connection string directly, for example `"host=localhost port=5432 dbname=appdb user=appuser"`. The plugin does not save passwords or log connection strings. One profile is active at a time; its name appears in SQL winbars, results, schema trees, and table grids. When you switch profiles with staged edits, choose **Save**, **Discard**, or **Stay**. A failed save leaves the current profile and edits in place.

If `:BetterSqlConnect` reports a missing Python dependency, install Psycopg into the exact interpreter set by `python`. The default is `python3`.

### Supabase

In your Supabase project, open **Connect** and choose **Session pooler**. Copy the host and username from the connection string shown there. Replace the `dev` entry in the quick-start `connections` table with a profile like this:

```lua
supabase = "host=YOUR_POOLER_HOST port=5432 dbname=postgres user=postgres.YOUR_PROJECT_REF sslmode=require",
```

The matching `~/.pgpass` entry is:

```text
YOUR_POOLER_HOST:5432:postgres:postgres.YOUR_PROJECT_REF:YOUR_DATABASE_PASSWORD
```

Use the exact host, port, database, and username from your project's [Connect dialog](https://supabase.com/docs/guides/database/connecting-to-postgres). The shared pooler username includes the project ref. Keep the database password out of your Lua configuration, and run `chmod 600 ~/.pgpass` after saving the password file.

## Browse schemas and rows

Run `:BetterSqlSchema` after connecting. The tree opens in a right-side split, half the terminal width, with long lines wrapped. Press `<CR>` on a schema to expand or collapse it. Press `<CR>` on a table or view to open its grid and toggle its column list. The tree includes non-system schemas, ordinary and partitioned tables, views, column names, and column types.

The schema cache loads when you connect. Run `:BetterSqlRefreshSchema` after `CREATE`, `ALTER`, or `DROP`, including changes made outside Neovim. Running DDL does not refresh the cache automatically. Completion uses the same cache.

Table grids load up to 100 rows per page. Use `]p` and `[p` to move between pages. Tables with a primary key are ordered by that key. Views and tables without a primary key have no guaranteed paging order. The grid shows the selected cell's value near the top and keeps column headers in the winbar as you scroll sideways. Grid cells are clipped to 24 display columns; press `K` for the full value, then `q` to close its detail window.

## Run SQL and read results

Put the cursor inside a statement and run `:BetterSqlRun`. The statement finder handles semicolons inside strings, quoted identifiers, dollar quotes, line comments, and nested block comments. Use `:BetterSqlRunBuffer` for the whole buffer. In Visual mode, select text and press `<leader>sr` to run exactly that selection, including a characterwise selection. `:BetterSqlRun` with an Ex range, including Vim's `'<,'>` Visual range, runs complete selected lines.

Queries run exactly as entered. The plugin does not add `LIMIT` or prevent writes. The results window opens below the SQL window and shows command status, column headers, and rows. For a request with several result sets, press `]r` or `[r` to move between them. `NULL` appears as `NULL`; an empty string appears as `""`. Newlines and tabs are escaped for display.

Database errors appear in the results window with their SQL state. When PostgreSQL supplies an error position, the cursor moves to that position in the source SQL window. Use `:BetterSqlCancel` to request cancellation of a running query.

## Complete names while writing SQL

In a buffer with `filetype=sql`, type `.` to open Neovim's built-in completion menu when matches are available. Press `<C-x><C-o>` for a partial name. Completion suggests schemas and relations after `FROM` or `JOIN`, relations after `schema.`, and columns after `table.` or a recognized alias:

```sql
SELECT u.
FROM public.users AS u;
```

Completion reads the schema cache. If a new table or column is missing, run `:BetterSqlRefreshSchema` and try again. It does not offer names in every SQL context.

## Edit and save table cells

Open a table from the schema tree. Use `h` and `l` to change cells, or `j` and `k` to change rows while keeping the selected column. Press `e` to enter a replacement value. Enter PostgreSQL text input without SQL string quotes, such as `true`, `2026-09-24`, or `{"enabled":true}`. An empty input means an empty string. Press `N` to stage SQL `NULL`; typing `NULL` in the prompt passes the text `NULL` to the column's input conversion.

An edited cell shows `*`, and the grid shows the pending cell count. Edits remain staged while you change pages. Press `u` on a cell to discard its pending edit, or `s` to save all pending edits in that grid, including edits on other pages. The save uses bound values and one database transaction. If any value conversion, constraint, permission, or concurrent edit fails, the whole save rolls back and staged values remain visible. Press `r` to reload rows and review staged text against fresh row versions before retrying. If a row no longer matches, discard its staged cells with `u`.

The grid can update existing, non-key cells in ordinary or partitioned tables with a primary key. Views, tables without a primary key, primary-key columns, and generated columns are read-only. The grid shows a reason when editing is blocked. Supported editable types are text, varchar, char, integers, floating-point types, numeric, boolean, uuid, date, time, timetz, timestamp, timestamptz, enum, json, and jsonb. Arrays, binary data, domains, intervals, and other custom or complex types are read-only. Use SQL to insert or delete rows.

Finish an explicit SQL transaction with `COMMIT` or `ROLLBACK` before saving table edits. Staged edits live only in the grid buffer. Closing the grid wipes them, and restarting Neovim does not restore them.

## Command and key reference

| Command | Action |
| --- | --- |
| `:BetterSqlConnect` | Select a configured profile and load its schema cache. |
| `:BetterSqlSchema` | Open the cached schema tree. |
| `:BetterSqlRefreshSchema` | Reload the schema cache. |
| `:BetterSqlRun` | Run the statement under the cursor, or the complete lines in an Ex range. |
| `:BetterSqlRunBuffer` | Run the entire buffer. |
| `:BetterSqlCancel` | Request cancellation of the running query. |
| `:BetterSqlReconnect` | Restart the last selected profile's connection. |

| View | Key | Action |
| --- | --- | --- |
| SQL, Visual mode | `<leader>sr` | Run the selected text. |
| SQL, Insert mode | `<C-x><C-o>` | Complete a partial name. |
| Results | `]r`, `[r` | Next, previous result set. |
| Schema tree | `<CR>` | Toggle a schema, or open a relation and toggle its columns. |
| Table grid | `h`, `l` | Previous, next cell. |
| Table grid | `j`, `k` | Next, previous row. |
| Table grid | `]p`, `[p` | Next, previous page. |
| Table grid | `K` | Show the full cell value. |
| Cell detail | `q` | Close the detail window. |
| Table grid | `e` | Stage an edited cell value. |
| Table grid | `N` | Stage SQL `NULL`. |
| Table grid | `u` | Discard the selected cell's pending edit. |
| Table grid | `s` | Save all pending edits in this grid. |
| Table grid | `r` | Reload rows and reapply staged text for review. |

## Limits and recovery

`max_rows` defaults to 1,000 and `max_bytes` to 4 MiB. Set them in `setup()` if you need different display caps:

```lua
require("better_sql").setup({
	python = vim.fn.expand("~/.local/share/better-sql-venv/bin/python"),
	connections = { dev = "service=devdb" },
	max_rows = 2000,
	max_bytes = 8388608,
})
```

The nonnegative caps apply across all result sets in one query request. The byte cap counts serialized row data, not column metadata or protocol framing. Zero allows no row data. Results mark truncation, and collection stops at the cap, so later result sets may not appear. These caps do not add a SQL `LIMIT` or bound all PostgreSQL and client memory use. Table paging is separate.

One database operation runs at a time. Wait for it to finish, or use `:BetterSqlCancel` for a running query. Cancellation appears in the results window. It rolls back an open user transaction; the helper restores the connection or reconnects before the next operation if needed. Otherwise, SQL follows PostgreSQL transaction rules.

If the helper exits, run `:BetterSqlReconnect`. Visible staged edits survive the disconnection. Select each affected grid and press `r` to reload and review them before saving. If a row cannot be matched after reload, use `u` to discard its pending cells. The plugin blocks saving until the reload is complete.

## Development and release checks

Use a disposable PostgreSQL database where the test role can create schemas and tables. From the checkout, create `.venv`, install the runtime dependency, and set `BETTER_SQL_TEST_DSN` to a real connection. A service name keeps credentials out of shell history:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
export PATH="$PWD/.venv/bin:$PATH"
export BETTER_SQL_TEST_DSN='service=better_sql_test'
export BETTER_SQL_PYTHON="$PWD/.venv/bin/python"
set -e
PYTHONPATH=python python3 -m unittest discover -s tests/python -v
PYTHONPATH=python python3 -m unittest discover -s tests/integration -v
for test_file in tests/lua/test_*.lua; do
	nvim --headless -u NONE -l "$test_file"
done
git diff --check
```

Run the checks sequentially. The end-to-end Lua test creates an isolated schema, exercises the main workflows, and removes its fixture even after a failed assertion. It requires a live DSN and fails if the database is unavailable.
