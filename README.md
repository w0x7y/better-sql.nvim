# better-sql.nvim

Run SQL, browse schemas and edit table rows in PostgreSQL without leaving Neovim.

![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?logo=neovim&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)
![Release](https://img.shields.io/github/v/release/w0x7y/better-sql.nvim)
![License](https://img.shields.io/badge/license-MIT-green)

## Install

It needs Python 3.10+ with Psycopg:

```
python3 -m venv ~/.local/share/better-sql-venv
~/.local/share/better-sql-venv/bin/python -m pip install "psycopg[binary]>=3.3,<4"
```

**With lazy.nvim:**

```lua
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
}
```

Then run `:checkhealth better_sql`.

## Connections

`connections` maps a name to a libpq connection string or a `postgres://` URI. Keep passwords out of your config: put the connection in `~/.pg_service.conf` and the password in `~/.pgpass` (`chmod 600 ~/.pgpass`).

```ini
# ~/.pg_service.conf
[devdb]
host=localhost
port=5432
dbname=appdb
user=appuser
```

```
# ~/.pgpass
localhost:5432:appdb:appuser:your-password
```

For Supabase, copy the Session pooler host and user from the project's Connect dialog and add `sslmode=require`.

## Usage

Open a `.sql` file, run `:BetterSqlConnect`, put the cursor on a statement and run `:BetterSqlRun`.

| Command                    | Description                                         |
| -------------------------- | --------------------------------------------------- |
| `:BetterSqlConnect [name]` | Connect to a profile                                |
| `:BetterSqlRun`            | Run the statement under the cursor, or a line range |
| `:BetterSqlRunBuffer`      | Run the whole buffer                                |
| `:BetterSqlCancel`         | Cancel the running query                            |
| `:BetterSqlSchema`         | Browse schemas; `<CR>` opens a table                |
| `:BetterSqlRefreshSchema`  | Reload the schema after `CREATE` or `ALTER`         |
| `:BetterSqlReconnect`      | Restart the connection                              |
| `:BetterSqlExport[!] file` | Save the results or table page as CSV               |

`<leader>sr` runs the selected text in Visual mode. Type `.` after a table or alias for completion, or press `<C-x><C-o>`.

In results and tables:

| Key             | Description                     |
| --------------- | ------------------------------- |
| `h` `j` `k` `l` | Move between cells              |
| `K`             | Show the full value             |
| `yc`            | Copy the value                  |
| `]r` `[r`       | Next or previous result set     |
| `]p` `[p`       | Next or previous page           |
| `f` `F`         | Filter a column, or clear all   |
| `o`             | Sort by a column                |
| `e`             | Edit the cell                   |
| `N`             | Set the cell to `NULL`          |
| `u`             | Undo the cell's edit            |
| `s`             | Save all edits                  |
| `r`             | Reload rows                     |

Only tables with a primary key can be edited. Edits are saved together in one transaction, and a save fails if someone changed the row since you loaded it; press `r` and save again.

Results show up to 1,000 rows or 4 MiB. Change that with `max_rows` and `max_bytes` in `opts`.

## License

[MIT](LICENSE)
