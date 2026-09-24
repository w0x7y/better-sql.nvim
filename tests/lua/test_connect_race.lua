vim.opt.runtimepath:append(vim.fn.getcwd())

local clients = {}
package.loaded["better_sql.client"] = {
  new = function()
    local client = { stopped = false }
    function client:start(on_exit)
      self.on_exit = on_exit
    end
    function client:request(method, params, callback)
      assert(method == "connect")
      self.conninfo = params.conninfo
      self.reply = callback
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

local first_called = false
local second_result
better_sql.connect("first", function()
  first_called = true
end)
better_sql.connect("second", function(err, result)
  assert(err == nil)
  second_result = result
end)

clients[2].reply(nil, { database = "second", user = "test" })
assert(second_result.database == "second")
assert(better_sql.active_profile == "second")
assert(better_sql.client == clients[2])

clients[1].reply(nil, { database = "first", user = "test" })
assert(clients[1].stopped, "stale connection was not stopped")
assert(not clients[2].stopped, "latest connection was stopped")
assert(better_sql.active_profile == "second", "stale completion replaced active profile")
assert(better_sql.client == clients[2], "stale completion replaced active client")
assert(not first_called, "stale completion was delivered")
