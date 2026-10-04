vim.opt.runtimepath:append(vim.fn.getcwd())
local Client = require("better_sql.client")
-- Replace only the helper process. Profile validation and activation stay real.
Client.new = function()
  return {
    start = function() end, stop = function() end, is_running = function() return true end,
    request = function(_, method, params, callback)
      if method == "connect" then
        assert(params.conninfo == "service=dev" or params.conninfo == "service=prod")
        callback(nil, { database = "test", user = "test" })
      elseif method == "catalog.load" then callback(nil, { schemas = {} })
      else error("unexpected helper request: " .. method) end
    end,
  }
end
local better_sql = require("better_sql")
better_sql.setup({ connections = { prod = "service=prod", dev = "service=dev" } })
vim.cmd.runtime("plugin/better_sql.lua")
local selections = 0
vim.ui.select = function(items, _, callback)
  selections = selections + 1
  assert(vim.deep_equal(items, { "dev", "prod" }), "picker profiles must be sorted")
  callback("prod")
end
vim.cmd("BetterSqlConnect dev")
assert(better_sql.active_profile == "dev" and selections == 0, "named connection must bypass the picker")
local matches = vim.fn.getcompletion("BetterSqlConnect d", "cmdline")
assert(vim.deep_equal(matches, { "dev" }), "command completion must match configured profiles")
vim.cmd.BetterSqlConnect()
assert(better_sql.active_profile == "prod" and selections == 1, "bare command must preserve the picker")
local notice
vim.notify = function(message, level) notice = { message = message, level = level } end
vim.cmd("BetterSqlConnect missing")
assert(better_sql.active_profile == "prod" and notice.level == vim.log.levels.ERROR,
  "unknown named profiles must report an error and keep the current connection")
print("named connection command passed")
