vim.opt.runtimepath:append(vim.fn.getcwd())

local app = require('better_sql')
app.setup({ connections = { local_db = 'password=delivery-secret' } })
local original_system, original_schedule = vim.system, vim.schedule
local helpers, scheduled = {}, {}
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
vim.system = function(_, options, on_exit)
  local helper = { options = options, on_exit = on_exit, requests = {} }
  local process = {}
  function process:write(line) helper.requests[#helper.requests + 1] = vim.json.decode(line) end
  function process:kill() helper.killed = true end
  helper.process = process
  helpers[#helpers + 1] = helper
  return process
end
local function deliver(helper, result)
  local request = helper.requests[#helper.requests]
  helper.options.stdout(nil, vim.json.encode({ id = request.id, ok = true, result = result }) .. '\n')
end
local function drain()
  local errors = {}
  while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    local ok, err = pcall(callback)
    if not ok then errors[#errors + 1] = err end
  end
  return errors
end

-- Keep a usable connection so a dying replacement must not activate or stop it.
local ready
app.connect('local_db', function(err) assert(not err); ready = true end)
local original = helpers[#helpers]
deliver(original, { database = 'postgres', user = 'tester' })
assert(#drain() == 0)
assert(original.requests[#original.requests].method == 'catalog.load')
deliver(original, { schemas = {} })
assert(#drain() == 0 and ready)
local original_client = app.client

local failures = {}
for _, stage in ipairs({ 'connect', 'catalog' }) do
  local ok, err = pcall(function()
    local calls, failure, result = 0, nil, nil
    app.connect('local_db', function(e, value)
      calls, failure, result = calls + 1, e, value
    end)
    local helper = helpers[#helpers]
    deliver(helper, { database = 'postgres', user = 'tester' })
    if stage == 'catalog' then
      assert(#drain() == 0)
      assert(helper.requests[#helper.requests].method == 'catalog.load')
      deliver(helper, { schemas = {} })
    end
    -- Exit arrives after stdout parsing, before either response callback runs.
    helper.on_exit({ code = 7, signal = 0 })
    local errors = drain()
    assert(#errors == 0, stage .. ': continuation raised: ' .. table.concat(errors, '\n'))
    assert(calls == 1, stage .. ': connect callback did not complete exactly once')
    assert(failure and failure.code == 'helper_exited' and result == nil,
      stage .. ': connection did not report a structured helper-exit error')
    assert(failure.message:find('BetterSqlReconnect', 1, true))
    assert(not failure.message:find('delivery-secret', 1, true))
    assert(app.client == original_client and not original.killed, stage .. ': dead helper replaced the usable connection')
    assert(#drain() == 0 and calls == 1, stage .. ': duplicate callback')
  end)
  if not ok then failures[#failures + 1] = err end
end
-- Exit can also happen while profile-switch confirmation holds activation.
local grid = require('better_sql.table')
local original_before_switch = grid.before_switch
local switch_calls, activate = 0, nil
grid.before_switch = function(callback)
  switch_calls = switch_calls + 1
  if switch_calls == 1 then callback(nil) else activate = callback end
end
app.config.connections.other_db = 'password=delivery-secret'
local waiting_calls, waiting_error = 0, nil
app.connect('other_db', function(err)
  waiting_calls, waiting_error = waiting_calls + 1, err
end)
local waiting = helpers[#helpers]
deliver(waiting, { database = 'postgres', user = 'tester' })
assert(#drain() == 0)
deliver(waiting, { schemas = {} })
assert(#drain() == 0 and activate and waiting_calls == 0)
waiting.on_exit({ code = 7, signal = 0 })
assert(#drain() == 0 and waiting_calls == 1 and waiting_error.code == 'helper_exited')
activate(nil)
assert(waiting_calls == 1 and app.client == original_client and not original.killed,
  'late profile confirmation activated a dead helper')
grid.before_switch = original_before_switch

vim.system, vim.schedule = original_system, original_schedule
assert(#failures == 0, table.concat(failures, '\n'))
print('callback delivery race tests passed')
