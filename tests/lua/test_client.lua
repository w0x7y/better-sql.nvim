vim.opt.runtimepath:append(vim.fn.getcwd())

local Client = require("better_sql.client")

local client = Client.new({ python = "python3" })
local reply
client:start()
local ping_id = client:request("ping", {}, function(err, result)
  assert(err == nil, vim.inspect(err))
  reply = result.pong
end)
assert(ping_id == 1)
assert(vim.wait(3000, function() return reply ~= nil end), "ping timed out")
assert(reply == true)
client:stop()

local decoded = Client.new({})
decoded.process = { write = function() end }
local delivered = {}
for index = 1, 3 do
  local id = decoded:request("ping", {}, function(err, result)
    delivered[#delivered + 1] = { id = index, err = err, result = result }
  end)
  assert(id == index)
end

local first = '{"id":1,"ok":true,"result":{"pong":1}}\n'
decoded:_on_stdout(first:sub(1, 8))
decoded:_on_stdout(first:sub(9, 19))
assert(#delivered == 0)
decoded:_on_stdout(first:sub(20))
decoded:_on_stdout('{"id":2,"ok":false,"error":{"code":"bad","message":"bad request"}}\n'
  .. '{"id":3,"ok":true,"result":{"pong":3}}\n')
assert(vim.wait(3000, function() return #delivered == 3 end), "framed replies timed out")
assert(delivered[1].id == 1 and delivered[1].result.pong == 1 and delivered[1].err == nil)
assert(delivered[2].id == 2 and delivered[2].err.code == "bad" and delivered[2].result == nil)
assert(delivered[3].id == 3 and delivered[3].result.pong == 3 and delivered[3].err == nil)
decoded:_on_stdout(first)
vim.wait(10)
assert(#delivered == 3, "duplicate reply invoked callback twice")

local exit_helper = vim.fn.tempname() .. ".py"
vim.fn.writefile({ "import sys", "sys.stdin.readline()" }, exit_helper)
local exited = Client.new({ python = "python3", helper = exit_helper })
local exit_error
local exit_status
exited:start(function(status)
  exit_status = status
end)
exited:request("ping", {}, function(err)
  exit_error = err
end)
assert(vim.wait(3000, function() return exit_error ~= nil and exit_status ~= nil end),
  "helper exit left request pending")
assert(exit_error.code == "helper_exited")
assert(exit_status.code == 0)
vim.fn.delete(exit_helper)

local restarting = Client.new({ python = "python3" })
local old_exit
restarting:start(function(status)
  old_exit = status
end)
assert(not pcall(restarting.start, restarting), "start accepted a second active process")
restarting:stop()
assert(not pcall(restarting.start, restarting), "start raced the old process exit")
assert(vim.wait(3000, function() return old_exit ~= nil end), "old helper did not exit")
local new_reply
restarting:start()
restarting:request("ping", {}, function(err, result)
  assert(err == nil, vim.inspect(err))
  new_reply = result.pong
end)
assert(vim.wait(3000, function() return new_reply ~= nil end), "restarted helper lost its request")
assert(new_reply == true)
restarting:stop()

local better_sql = require("better_sql")
better_sql.setup({ connections = { local_db = "service=local" } })
assert(better_sql.config.connections.local_db == "service=local")
assert(better_sql.config.python == "python3")
assert(better_sql.config.max_rows == 1000)
assert(better_sql.config.max_bytes == 4194304)
better_sql.setup({ python = "custom-python", max_rows = 50, max_bytes = 4096 })
assert(better_sql.config.python == "custom-python")
assert(better_sql.config.max_rows == 50 and better_sql.config.max_bytes == 4096)
assert(next(better_sql.config.connections) == nil)
