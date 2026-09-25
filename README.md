# better-sql.nvim

Run PostgreSQL queries, browse schemas, complete database names, and edit existing table rows from Neovim. Query results are read-only. The table browser stages cell changes and saves them in one transaction.

## Installation

Requirements:

- Neovim 0.10 or newer.
- Python 3.10 or newer.
- Psycopg 3.3 or newer, below version 4.
- A PostgreSQL database reachable from the machine running Neovim.

Install this repository with your Neovim plugin manager, or place the checkout in `~/.local/share/nvim/site/pack/plugins/start/better-sql.nvim`. No other Neovim plugin is required. The built-in menus handle profile selection, cell input, and completion.

Install Psycopg into the Python environment you will configure:

```sh
python3 -m venv ~/.local/share/better-sql-venv
~/.local/share/better-sql-venv/bin/python -m pip install "psycopg[binary]>=3.3,<4"
```

The binary extra supplies the PostgreSQL client library. You do not need `psql` to use the plugin. From a repository checkout, `python -m pip install -r requirements.txt` installs the same runtime dependency.

Add this to your Neovim configuration after the plugin is on `runtimepath`:

```lua
require("better_sql").setup({
  python = vim.fn.expand("~/.local/share/better-sql-venv/bin/python"),
  connections = {
    localdb = "service=localdb",
    reporting = "host=localhost port=5432 dbname=reporting user=reader",
  },
  max_rows = 1000,
  max_bytes = 4194304,
})
```

`python` defaults to `python3`. If that interpreter already has Psycopg, you can use `python = vim.fn.exepath("python3")`. A missing dependency error usually means Psycopg was installed into a different interpreter.

## Connections and credentials

The keys in `connections` are profile names displayed by `:BetterSqlConnect`. Each value is a nonempty libpq connection string or PostgreSQL URI. One profile is active at a time. SQL windows show its name in the winbar; results, schema trees, and table grids also show the profile.

Libpq resolves `service=localdb` through its service configuration. For example, put this in `~/.pg_service.conf`:

```ini
[localdb]
host=localhost
port=5432
dbname=my_database
user=my_user
```

Use a libpq password file to keep credentials out of your Neovim configuration. On Unix, `~/.pgpass` contains lines in this format:

```text
hostname:port:database:username:password
```

Set its permissions with `chmod 600 ~/.pgpass`. Libpq also accepts `PGPASSFILE` for a custom password file and `PGSERVICEFILE` for a custom service file. Other standard libpq environment variables, such as `PGHOST`, `PGPORT`, `PGDATABASE`, and `PGUSER`, supply omitted connection settings. Neovim's Python helper inherits its environment.

The plugin does not save passwords or log connection strings. When you switch profiles with pending table edits, choose **Save**, **Discard**, or **Stay**. A failed save leaves the current profile and edits in place.

## Commands

| Command | Action |
| --- | --- |
| `:BetterSqlConnect` | Select a configured profile and load its schema cache. |
| `:BetterSqlRun` | Run the SQL statement under the cursor. An Ex range runs those complete lines. |
| `:BetterSqlRunBuffer` | Run the entire current buffer. |
| `:BetterSqlSchema` | Open the cached schema tree. |
| `:BetterSqlRefreshSchema` | Reload the schema cache from PostgreSQL. |
| `:BetterSqlCancel` | Request cancellation of the running query. |
| `:BetterSqlReconnect` | Restart the connection using the last selected profile. |

In Visual mode, `<leader>sr` runs the selected text, including characterwise selections. Typing `:BetterSqlRun` from Visual mode uses Vim's `'<,'>` line range, so it runs the complete selected lines. Statement detection understands quoted identifiers, strings, dollar quotes, line comments, nested block comments, and semicolons within them.

Queries run exactly as entered. Results show command status, column headers, and rows. `NULL` is displayed as `NULL`; an empty string is displayed as `""`. Newlines and tabs are escaped for display. Database errors include the SQL state, and the cursor moves to the server's error position when available.

## Keys

| View | Key | Action |
| --- | --- | --- |
| SQL, Visual mode | `<leader>sr` | Run selected SQL. |
| SQL, Insert mode | `<C-x><C-o>` | Open built-in omnifunc completion. |
| Results | `]r` / `[r` | Next / previous result set. |
| Schema tree | `<CR>` on a schema | Expand or collapse it. |
| Schema tree | `<CR>` on a table or view | Open its grid and toggle its column list. |
| Table grid | `h` / `l` | Previous / next cell. |
| Table grid | `j` / `k` | Next / previous row, keeping the selected column. |
| Table grid | `]p` / `[p` | Next / previous page. |
| Table grid | `K` | Open the full cell value in a detail window. |
| Cell detail | `q` | Close the detail window. |
| Table grid | `e` | Edit the selected cell with a text prompt. |
| Table grid | `N` | Stage SQL `NULL` for the selected cell. |
| Table grid | `u` | Discard the selected cell's pending edit. |
| Table grid | `s` | Save all pending edits in this grid, including other pages. |
| Table grid | `r` | Reload from page one and reapply pending text to matching primary keys for review. |

Table pages contain up to 100 rows, ordered by the primary key. Views and tables without a primary key have no guaranteed paging order. Column headers stay visible in the winbar. Cells are clipped to 24 display columns in the grid; the cell detail shows the complete value. A `*` marks a staged cell, and the grid shows the pending cell count.

## Completion and schema refresh

In buffers with `filetype=sql`, completion suggests schemas and tables after `FROM` and `JOIN`, tables after `schema.`, and columns after `table.` or a recognized alias such as `u.`. Typing a dot opens Neovim's built-in completion menu automatically. Use `<C-x><C-o>` for a partial name. No completion plugin is required.

The cache loads on connect. Run `:BetterSqlRefreshSchema` after `CREATE`, `ALTER`, or `DROP`, including changes made outside Neovim. Running DDL does not automatically refresh the tree or completion cache.

## Editing rules

Only existing, non-key cells in tables with a primary key can be updated. Query results, views, tables without primary keys, primary-key columns, and generated columns are read-only. The grid explains why editing a cell is blocked. Row insertion and deletion are outside the table editor's scope; use SQL commands for those operations.

Editable types include `text`, `varchar`, `char`, integer and floating-point types, `numeric`, `boolean`, `uuid`, `date`, `time`, `timetz`, `timestamp`, `timestamptz`, enum, `json`, and `jsonb`. Arrays, binary data, domains, intervals, and other complex or custom types are read-only.

Enter PostgreSQL text input, such as `true`, `2026-09-24`, or `{"enabled":true}`. Enter text values without SQL string quotes. An empty input stages an empty string. Use `N` for SQL `NULL`; typing `NULL` into the prompt supplies text to the column's input conversion.

Pending edits stay staged as you change pages. Saving binds cell values as parameters and updates rows using their original primary key and row version. A concurrent change or deletion causes a conflict. Any conversion, constraint, permission, or conflict error rolls back the entire save and keeps staged values visible. Review the error, then use `r` to reload before retrying, or `u` to discard a cell. Finish an explicit SQL transaction with `COMMIT` or `ROLLBACK` before saving table edits.

Staged edits live in the grid buffer and are not persisted across Neovim restarts. Closing a grid wipes its staged edits. Resolve them with `s` or `u` before closing that grid.

## Query limits and recovery

`max_rows` defaults to 1,000 and `max_bytes` to 4 MiB. These nonnegative limits apply across the result sets of one query request. The byte budget counts serialized row data, excluding column metadata and protocol framing. A zero limit allows no row data. The results view clearly marks truncation, and collection stops at the cap, so later result sets may not be displayed.

These are display limits. They do not add a SQL `LIMIT`, prevent statements from executing, or bound all PostgreSQL or client memory use. Table browsing uses database-side pages independently of the query caps.

One database operation runs at a time. Wait for it to finish, or use `:BetterSqlCancel` for a running query. Cancellation is shown in the result view; the helper restores a usable connection and reconnects before the next operation if the connection broke. Cancellation rolls back an open user transaction. User-run scripts otherwise follow PostgreSQL's transaction semantics; the table save action provides the atomic edit batch.

If the helper exits, use `:BetterSqlReconnect`. Visible staged edits survive disconnection. After reconnecting, select the table grid and press `r` to reload rows and review reapplied text. Saving is blocked until reload; unmatched rows remain visible so you can discard their pending cells with `u`. A reload uses fresh row versions.

## Walkthrough

1. Open `demo.sql`, ensure `:set filetype=sql`, and run `:BetterSqlConnect` to choose a development database.
2. Put this SQL in the buffer and run `:BetterSqlRunBuffer`:

   ```sql
   CREATE TABLE public.better_sql_demo (
     id integer PRIMARY KEY,
     note text,
     enabled boolean DEFAULT true
   );
   INSERT INTO public.better_sql_demo (id, note)
   SELECT n, 'row ' || n FROM generate_series(1, 101) AS n;
   SELECT * FROM public.better_sql_demo ORDER BY id;
   ```

3. Use `]r` to reach the `SELECT` result. Run `:BetterSqlRefreshSchema`, then `:BetterSqlSchema`. Press `<CR>` on `better_sql_demo` to open its table grid.
4. Move to `note` with `l`, press `e`, and enter new text. Try `]p` and `[p` to see that the edit survives page changes. Press `s` to save.
5. Back in the SQL buffer, run `SELECT * FROM public.better_sql_demo WHERE id = 1;` with `:BetterSqlRun` to verify the change. In `SELECT d. FROM public.better_sql_demo AS d`, type the dot after `d` to complete a column.
6. When finished, run `DROP TABLE public.better_sql_demo;`, then `:BetterSqlRefreshSchema`.

## Release checks

Use a disposable PostgreSQL database where the test role can create schemas and tables. From the checkout, create `.venv` and install `requirements.txt`, then set a real `BETTER_SQL_TEST_DSN`. A service name keeps credentials out of shell history:

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

Run these sequentially. The end-to-end script creates an isolated schema, runs and inspects results, refreshes the tree, pages a table, stages and saves a cell, checks completion, and removes its fixture even after an assertion fails. It requires a DSN and fails rather than silently skipping if the database is unavailable.
