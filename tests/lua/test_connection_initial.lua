vim.opt.runtimepath:append(vim.fn.getcwd())

-- The command facade can load after the connection module is already active.
local connection = require("better_sql.connection")
local config = {
  connections = { test = assert(vim.env.BETTER_SQL_TEST_DSN) },
  python = assert(vim.env.BETTER_SQL_PYTHON),
}
local calls, failure = 0
connection.connect("test", config, function(err) calls, failure = calls + 1, err end)
assert(vim.wait(3000, function() return calls == 1 end), "connection timed out")
assert(not failure, vim.inspect(failure))
local app = require("better_sql")
assert(app.client == connection.snapshot().client and app.active_profile == "test",
  "late facade load lost the active connection")
app.client:stop()
assert(vim.wait(3000, function() return app.client == nil end), "facade did not observe disconnect")
print("initial connection snapshot tests passed")
