vim.opt.runtimepath:append(vim.fn.getcwd())

local better_sql = require("better_sql")
local python = vim.env.BETTER_SQL_PYTHON or ".venv/bin/python"

local function report(options)
  better_sql.setup(options)
  vim.cmd("checkhealth better_sql")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("bwipeout!")
  return text
end

local text = report({ python = python, connections = { dev = "service=dev password=hunter2", broken = "" } })
assert(text:find("OK Helper found on runtimepath", 1, true), text)
assert(text:find("OK Python 3%.%d+%.%d+ at "), text)
assert(text:find("OK Psycopg 3%.%d+"), text)
assert(text:find("OK Profiles: broken, dev", 1, true), text)
assert(text:find("ERROR These profiles need a nonempty libpq connection string or URI: broken", 1, true), text)
assert(text:find("Not connected", 1, true), text)
assert(not text:find("hunter2", 1, true), "health report printed a connection string")

text = report({ python = "better-sql-missing-python" })
assert(text:find("ERROR Python not found: better-sql-missing-python", 1, true), text)
assert(text:find("WARNING No connection profiles configured", 1, true), text)

-- An interpreter without Psycopg must be reported with install advice.
local bare = vim.fn.tempname()
vim.fn.writefile({ "#!/bin/sh", "exec python3 -I -S -c \"$2\"" }, bare)
vim.fn.setfperm(bare, "rwx------")
text = report({ python = bare })
assert(text:find("ERROR Psycopg is not installed for this Python", 1, true), text)
assert(text:find("-m pip install 'psycopg[binary]>=3.3,<4'", 1, true), text)
vim.fn.delete(bare)
