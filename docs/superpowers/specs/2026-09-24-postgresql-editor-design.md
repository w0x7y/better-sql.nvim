# PostgreSQL editor for Neovim

## Goal

Make Neovim a useful PostgreSQL workspace for writing and running SQL, inspecting query results, browsing the schema, completing database names, and editing rows in a table browser. The first release supports PostgreSQL only.

## Requirements and scope

- Neovim 0.10 or newer, Python 3.10 or newer, and Psycopg 3 are required. Recommend `psycopg[binary]` for a simple install. There is no required Neovim plugin dependency.
- Users configure named connection profiles with libpq connection information or a service name. Standard libpq environment variables and password files remain available. The plugin does not save passwords or log connection strings.
- One profile is active at a time. Switching profiles closes the previous connection after the user resolves pending table edits.
- Query results are read-only. The table browser supports updating existing non-key cells. It does not insert or delete rows, edit primary keys, or edit arbitrary query results in this release.
- Tables without a primary key and views open read-only. Generated columns open read-only. The browser reports why a cell cannot be edited.
- Text, numeric, boolean, UUID, date/time, enum, JSON, and JSONB columns can be edited using PostgreSQL's text input syntax. Arrays, binary data, and other complex or custom types are read-only in this release. A failed conversion leaves pending edits intact and displays the server error.

## User workflow

1. `:BetterSqlConnect` selects a configured profile and starts a Python helper. The active connection is visible in the SQL and grid views.
2. `:BetterSqlRun` runs a visual selection when one exists; otherwise it runs the SQL statement under the cursor. `:BetterSqlRunBuffer` runs the whole buffer. Statement selection recognizes quoted strings and identifiers, dollar-quoted strings, line comments, nested block comments, and semicolons outside those constructs.
3. A result split shows column names, rows, command status, and errors. If a selection or buffer returns multiple result sets, the user can switch among them. Query execution never silently rewrites the user's SQL.
4. `:BetterSqlSchema` opens a tree of schemas, tables, views, and columns. Opening a table shows 100 rows per page, ordered by its primary key, with next and previous page actions. Views and tables without primary keys can be inspected but not edited.
5. In the table grid, `e` opens a cell editor, `u` discards a pending cell edit, `s` saves all pending edits for that table, and `N` sets a cell to SQL `NULL`. Dirty cells are marked. Empty string and `NULL` stay distinct. Pending edits remain staged when the user changes pages.
6. Completion suggests schema and table names in relation positions such as `FROM` and `JOIN`. After `users.` or a recognized table alias followed by `.`, it suggests that table's columns. The built-in completion menu opens automatically after `.` and is also available through Neovim's omnifunc. Completion does not require `nvim-cmp`.

The schema cache loads on connect. `:BetterSqlRefreshSchema` reloads it after schema changes. Successful DDL does not implicitly refresh the cache in the first release.

## Architecture

The Lua side owns commands, buffer and window layout, keyboard actions, result rendering, completion context, and the statement scanner. It communicates with one long-running Python process per active connection through newline-delimited JSON on standard input and output. Each request has an ID and a method; each response has the same ID and either a result or a structured error. The Python process owns the Psycopg connection, catalog queries, query execution, table paging, and updates. Standard output carries protocol messages only; diagnostics go to standard error.

The Python process uses an autocommit connection for user-run SQL and catalog reads, so a long-lived editor session does not remain idle in a transaction. Table saves use an explicit transaction. One database operation runs at a time. The protocol can accept a cancellation request while an operation is running; the helper requests cancellation through Psycopg and then restores a usable connection state. A broken connection reports an error and can be restarted without closing Neovim.

Result messages contain ordered column metadata and ordered cell values. Each cell has a display string and an explicit null flag. The table browser also receives an opaque row handle. The helper retains the original typed values, primary key, and row version for loaded rows with pending edits, even when the user changes pages. The Lua UI treats rendered strings as presentation data, never as trusted SQL or typed input. Query results default to limits of 1,000 rows and 4 MiB of serialized data, both configurable; reaching either limit is shown clearly, and the helper stops collecting more result data.

## Table save rules

Pending edits remain in the Lua grid until a save succeeds or the user discards them. For each changed row, the helper builds one `UPDATE` using identifiers composed with `psycopg.sql.Identifier` and values passed as bound parameters. User-entered text is cast to the column's PostgreSQL type. The helper never concatenates a cell value into SQL.

The `UPDATE` locates the row by its original primary key and original `xmin` row version. It requires exactly one updated row. Zero rows means the row was changed or deleted after loading; more than one row is treated as an internal error. All changed rows save in one transaction. Any conversion, constraint, permission, or conflict error rolls the transaction back. On success, the helper returns refreshed rows and versions and the UI clears dirty markers. On failure, the UI keeps the pending values and identifies the affected row and column when possible.

A disconnect does not silently discard visible pending edits. After reconnect, the user must reload the table; the UI can then reapply staged text to matching keys for review, but it does not save against an old row version.

## Errors and limits

- Database errors show the server message and SQL state. Where PostgreSQL supplies a statement position, the editor points to it. Connection strings and passwords are redacted from logs and errors.
- Query cancellation is visible and leaves the editor responsive. If cancellation breaks the connection, the plugin reconnects before another request.
- A configured display cap protects the grid from very large results. The UI states when output is truncated; it never presents a partial result as complete. Table browsing always uses database-side paging.
- The query result cap limits what the helper serializes and Neovim renders. It does not rewrite the user's SQL with `LIMIT`, so a query can still use substantial server or client resources before the cap is reached.
- SQL scripts use PostgreSQL's normal transaction semantics. Only the table browser promises atomic save of staged edits.

## Testing and delivery

- Python unit tests cover protocol framing, catalog to model conversion, SQL identifier composition, value conversion, and save conflict handling.
- PostgreSQL integration tests cover multiple result sets, `NULL` versus empty string, type errors, transaction rollback, concurrent row updates, paging, and cancellation.
- Headless Neovim tests cover command registration, statement selection, schema and completion context, grid rendering, and pending edit state.
- The README documents installation, connection profiles, commands and keys, editing limits, and a short end-to-end example.

Implementation proceeds in four milestones: connection and query results; schema tree and table paging; staged editing and atomic save; schema-aware completion and polish. Each milestone leaves a usable path that can be exercised against PostgreSQL.

## References

- [Neovim Lua process API](https://neovim.io/doc/user/lua/#vim.system())
- [Psycopg parameter binding and SQL composition](https://www.psycopg.org/psycopg3/docs/basic/params.html)
- [Psycopg transaction management](https://www.psycopg.org/psycopg3/docs/basic/transactions.html)
- [Psycopg multiple result sets](https://www.psycopg.org/psycopg3/docs/basic/from_pg2.html#multiple-results-returned-from-multiple-statements)
- [PostgreSQL system columns](https://www.postgresql.org/docs/current/ddl-system-columns.html)
