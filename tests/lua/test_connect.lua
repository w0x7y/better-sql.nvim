vim.opt.runtimepath:append(vim.fn.getcwd())

local better_sql = require("better_sql")
local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn and dsn ~= "", "BETTER_SQL_TEST_DSN required")
local secret = "do-not-put-this-in-argv"
better_sql.setup({ connections = { local_db = dsn .. " password=" .. secret }, python = ".venv/bin/python" })

local original_system = vim.system
local argv
vim.system = function(command, options, callback)
  argv = command
  return original_system(command, options, callback)
end

local error_result, connect_result
better_sql.connect("local_db", function(err, result)
  error_result, connect_result = err, result
end)
assert(vim.wait(3000, function() return connect_result ~= nil or error_result ~= nil end), "connect timed out")
assert(error_result == nil, vim.inspect(error_result))
local identity
better_sql.client:request("query.run", {
  sql = "select current_database(), current_user",
  max_rows = 1,
  max_bytes = 4096,
}, function(err, result)
  assert(err == nil, vim.inspect(err))
  identity = result.sets[1].rows[1]
end)
assert(vim.wait(3000, function() return identity ~= nil end), "identity query timed out")
assert(connect_result.database == identity[1].text)
assert(connect_result.user == identity[2].text)
assert(better_sql.active_profile == "local_db")
assert(not table.concat(argv, " "):find(secret, 1, true), "password leaked to process arguments")

local missing_error
better_sql.connect("missing", function(err)
  missing_error = err
end)
assert(missing_error and missing_error.code == "unknown_profile")
assert(better_sql.active_profile == "local_db")

vim.ui.select = function(items, _, callback)
  assert(vim.tbl_contains(items, "local_db"))
  callback("local_db")
end
vim.cmd.runtime("plugin/better_sql.lua")
assert(vim.fn.exists(":BetterSqlConnect") == 2)
local original_connect = better_sql.connect
local selected_name
better_sql.connect = function(name, callback)
  selected_name = name
  callback(nil, connect_result)
end
vim.cmd.BetterSqlConnect()
assert(selected_name == "local_db")
better_sql.connect = original_connect

better_sql.client:stop()
vim.system = original_system
