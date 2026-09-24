vim.opt.runtimepath:append(vim.fn.getcwd())

local clients = {}
package.loaded["better_sql.client"] = {
  new = function()
    local client = { stopped = false }
    function client:start(on_exit)
      self.on_exit = on_exit
    end
    function client:request(method, params, callback)
      if method == "connect" then
        self.conninfo = params.conninfo
        self.reply = callback
      elseif method == "catalog.load" then
        callback(nil, { schemas = {} })
      else
        error("unexpected method: " .. method)
      end
    end
    function client:stop()
      self.stopped = true
    end
    clients[#clients + 1] = client
    return client
  end,
}

local better_sql = require("better_sql")
better_sql.setup({ connections = { first = "dbname=first", second = "dbname=second" } })

local first_calls = 0
local first_error, first_result
local second_calls = 0
local second_result
better_sql.connect("first", function(err, result)
  first_calls = first_calls + 1
  first_error, first_result = err, result
end)
better_sql.connect("second", function(err, result)
  second_calls = second_calls + 1
  assert(err == nil)
  second_result = result
end)

clients[2].reply(nil, { database = "second", user = "test" })
assert(second_result.database == "second")
assert(second_calls == 1)
assert(better_sql.active_profile == "second")
assert(better_sql.client == clients[2])

clients[1].reply(nil, { database = "first", user = "test" })
assert(clients[1].stopped, "stale connection was not stopped")
assert(not clients[2].stopped, "latest connection was stopped")
assert(better_sql.active_profile == "second", "stale completion replaced active profile")
assert(better_sql.client == clients[2], "stale completion replaced active client")
assert(first_calls == 1, "superseded connection did not complete exactly once")
assert(first_error.code == "connect_superseded")
assert(type(first_error.message) == "string" and first_error.message ~= "")
assert(first_result == nil)
assert(second_calls == 1, "latest connection completed more than once")
