vim.opt.runtimepath:append(vim.fn.getcwd())

-- Exercise lifecycle behavior with the real Client and a controlled transport.
local original_system, original_schedule, original_notify = vim.system, vim.schedule, vim.notify
local notices = {}
vim.notify = function(message) notices[message] = (notices[message] or 0) + 1 end
local helpers, scheduled = {}, {}
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
vim.system = function(_, options, on_exit)
  local helper = { options = options, on_exit = on_exit, requests = {} }
  local process = {}
  function process:write(line)
    if helper.write_failure then error('pipe closed: password=never-print-this-secret') end
    helper.requests[#helper.requests + 1] = vim.json.decode(line)
  end
  function process:kill() helper.killed = true end
  helpers[#helpers + 1] = helper
  return process
end
local function drain(allow_errors)
  local errors = {}
  while #scheduled > 0 do
    local ok, err = pcall(table.remove(scheduled, 1))
    if not ok then errors[#errors + 1] = err end
  end
  if not allow_errors then assert(#errors == 0, table.concat(errors, '\n')) end
  return errors
end
local function reply(helper, request, result)
  helper.options.stdout(nil, vim.json.encode({ id = request.id, ok = true, result = result }) .. '\n')
  drain()
end
local function ready(helper, name)
  reply(helper, helper.requests[1], { database = name, user = 'tester' })
  reply(helper, helper.requests[2], { schemas = {{ name = name, relations = {} }} })
end

local app = require('better_sql')
app.setup({ connections = { first = 'dbname=first', second = 'dbname=second' } })
local connected
app.connect('first', function(err) assert(not err); connected = true end)
local first = helpers[1]
ready(first, 'first')
assert(connected)

-- Losing the supersession branch must leave this assertion failing.
local old_calls, old_error = 0, nil
app.refresh_schema(function(err) old_calls, old_error = old_calls + 1, err end)
local old_request = first.requests[#first.requests]
local new_calls = 0
app.refresh_schema(function(err) assert(not err); new_calls = new_calls + 1 end)
local new_request = first.requests[#first.requests]
assert(old_calls == 1 and old_error.code == 'catalog_superseded', 'supersession waited for the old helper reply')
reply(first, old_request, { schemas = {{ name = 'obsolete', relations = {} }} })
assert(old_calls == 1 and old_error and old_error.code == 'catalog_superseded',
  'superseded schema refresh must complete exactly once with a structured error')
reply(first, new_request, { schemas = {{ name = 'current', relations = {} }} })
assert(new_calls == 1)

local connection = require('better_sql.connection')
assert(connection.get_catalog().schemas[1].name == 'current', 'stale refresh replaced catalog')
local copy = connection.get_catalog()
copy.schemas[1].name = 'corrupted'
assert(connection.get_catalog().schemas[1].name == 'current', 'catalog getter leaked cache ownership')

local disconnected_calls, disconnected_error = 0, nil
connection.refresh_schema(function(err) disconnected_calls, disconnected_error = disconnected_calls + 1, err end)
local disconnected_request = first.requests[#first.requests]
first.on_exit({ code = 7, signal = 0 })
drain()
assert(disconnected_calls == 1 and disconnected_error.code == 'helper_exited',
  'disconnect dropped the pending schema callback')
assert(connection.snapshot().client == nil and connection.get_catalog() == nil)
reply(first, disconnected_request, { schemas = {{ name = 'dead', relations = {} }} })
assert(disconnected_calls == 1 and connection.get_catalog() == nil, 'late refresh changed disconnected state')

local reconnected
connection.reconnect(app.config, function(err) assert(not err); reconnected = true end)
local recovered = helpers[#helpers]
ready(recovered, 'first')
assert(reconnected and connection.snapshot().profile == 'first')

local switched_calls, switched_error = 0, nil
connection.refresh_schema(function(err) switched_calls, switched_error = switched_calls + 1, err end)
local switched_request = recovered.requests[#recovered.requests]
local switched
connection.connect('second', app.config, function(err) assert(not err); switched = true end)
local second = helpers[#helpers]
ready(second, 'second')
assert(switched and switched_calls == 1 and switched_error.code == 'catalog_superseded',
  'profile activation dropped a pending refresh callback')
reply(recovered, switched_request, { schemas = {{ name = 'old profile', relations = {} }} })
assert(switched_calls == 1 and connection.get_catalog().schemas[1].name == 'second')

-- The switch guard must run before work begins and again after catalog load.
local grid = require('better_sql.table')
local original_guard = grid.before_switch
local guards = {}
grid.before_switch = function(callback) guards[#guards + 1] = callback end
local guarded_calls, guarded_error = 0, nil
local helper_count = #helpers
connection.connect('first', app.config, function(err) guarded_calls, guarded_error = guarded_calls + 1, err end)
assert(#helpers == helper_count and #guards == 1, 'switch started before dirty-edit guard')
guards[1](nil)
ready(helpers[#helpers], 'first')
assert(#guards == 2 and guarded_calls == 0 and connection.snapshot().profile == 'second',
  'candidate activated before checking edits made during connection setup')
guards[2]({ code = 'switch_cancelled', message = 'keep edits' })
assert(guarded_calls == 1 and guarded_error.code == 'switch_cancelled')
assert(connection.snapshot().profile == 'second' and not second.killed)
guards[2](nil)
assert(guarded_calls == 1, 'duplicate switch confirmation completed callback twice')
grid.before_switch = original_guard

-- Presentation errors must not interrupt completion of database operations.
local fail_render = true
connection.subscribe(function() if fail_render then error('injected schema render failure') end end)
local rendered_calls = 0
local refresh_started = pcall(function()
  connection.refresh_schema(function(err, result)
    assert(not err)
    rendered_calls = rendered_calls + 1
    result.schemas[1].name = 'caller mutation'
  end)
end)
assert(refresh_started, 'schema rendering failure interrupted refresh request')
reply(second, second.requests[#second.requests], { schemas = {{ name = 'rendered', relations = {} }} })
assert(rendered_calls == 1 and connection.get_catalog().schemas[1].name == 'rendered',
  'schema rendering failure interrupted refresh callback')
fail_render = false

-- Supersession callbacks may start a third attempt before the second begins.
local first_attempt_calls, middle_attempt_calls, latest_attempt_calls = 0, 0, 0
local latest_helper
connection.connect('second', app.config, function(err)
  first_attempt_calls = first_attempt_calls + 1
  assert(err.code == 'connect_superseded')
  connection.connect('second', app.config, function(latest_error)
    assert(not latest_error)
    latest_attempt_calls = latest_attempt_calls + 1
  end)
  latest_helper = helpers[#helpers]
  ready(latest_helper, 'latest')
end)
local stale_helper = helpers[#helpers]
local before_middle = #helpers
connection.connect('second', app.config, function(err)
  middle_attempt_calls = middle_attempt_calls + 1
  assert(err.code == 'connect_superseded')
end)
assert(first_attempt_calls == 1 and middle_attempt_calls == 1 and latest_attempt_calls == 1)
assert(#helpers == before_middle + 1, 'superseded middle attempt started a helper after reentrant connect')
assert(connection.get_catalog().schemas[1].name == 'latest')
reply(stale_helper, stale_helper.requests[1], { database = 'stale', user = 'tester' })
assert(first_attempt_calls == 1 and connection.get_catalog().schemas[1].name == 'latest')

local old_refresh_calls, middle_refresh_calls, latest_refresh_calls = 0, 0, 0
connection.refresh_schema(function(err)
  old_refresh_calls = old_refresh_calls + 1
  assert(err.code == 'catalog_superseded')
  connection.refresh_schema(function(latest_error)
    assert(not latest_error)
    latest_refresh_calls = latest_refresh_calls + 1
  end)
end)
local before_refresh = #latest_helper.requests
connection.refresh_schema(function(err)
  middle_refresh_calls = middle_refresh_calls + 1
  assert(err.code == 'catalog_superseded')
end)
assert(#latest_helper.requests == before_refresh + 1, 'superseded reentrant refresh sent an obsolete request')
reply(latest_helper, latest_helper.requests[#latest_helper.requests], { schemas = {{ name = 'newest refresh', relations = {} }} })
assert(old_refresh_calls == 1 and middle_refresh_calls == 1 and latest_refresh_calls == 1)

-- Refresh cancellation during activation can synchronously activate a newer helper.
local replaced_connect_calls, nested_connect_calls, activating_refresh_calls = 0, 0, 0
local nested_helper
local facade_coherent
connection.refresh_schema(function(err)
  activating_refresh_calls = activating_refresh_calls + 1
  assert(err.code == 'catalog_superseded')
  facade_coherent = app.client == connection.snapshot().client
    and app.active_profile == connection.snapshot().profile
  connection.connect('second', app.config, function(nested_error)
    assert(not nested_error)
    nested_connect_calls = nested_connect_calls + 1
  end)
  nested_helper = helpers[#helpers]
  ready(nested_helper, 'nested activation')
end)
connection.connect('second', app.config, function(err)
  replaced_connect_calls = replaced_connect_calls + 1
  assert(err.code == 'connect_superseded')
end)
local replaced_helper = helpers[#helpers]
ready(replaced_helper, 'replaced activation')
assert(replaced_connect_calls == 1 and nested_connect_calls == 1 and activating_refresh_calls == 1)
assert(facade_coherent, 'refresh cancellation callback observed the previous facade connection')
assert(connection.get_catalog().schemas[1].name == 'nested activation')
assert(replaced_helper.killed and latest_helper.killed and not nested_helper.killed,
  'reentrant activation leaked an old helper or stopped the newest helper')

local resilient_connect_calls = 0
local sessions = require('better_sql.table_session')
local loading_grid = sessions.new(connection.snapshot().client, { schema = 'public', name = 'fixture', columns = {} }, 'second')
local rebound_coherent
loading_grid:load(0, nil, function(err)
  assert(err.code == 'connection_changed')
  rebound_coherent = app.client == connection.snapshot().client and app.client ~= nil
end)
connection.refresh_schema(function() error('injected superseded callback failure') end)
connection.connect('second', app.config, function(err)
  assert(not err)
  resilient_connect_calls = resilient_connect_calls + 1
end)
nested_helper = helpers[#helpers]
ready(nested_helper, 'resilient activation')
assert(resilient_connect_calls == 1 and connection.get_catalog().schemas[1].name == 'resilient activation',
  'throwing refresh cancellation callback interrupted connection activation')
assert(rebound_coherent, 'grid invalidation callback observed the previous facade connection')
loading_grid:close()

-- A throwing caller must not prevent other pending requests from completing.
local raw_client = require('better_sql.client').new()
raw_client:start()
local raw_helper = helpers[#helpers]
local drained_calls, drained_error = 0, nil
raw_client:request('ping', {}, function() error('injected caller failure') end)
raw_client:request('ping', {}, function(err) drained_calls, drained_error = drained_calls + 1, err end)
raw_helper.on_exit({ code = 7, signal = 0 })
drain(true)
assert(drained_calls == 1 and drained_error.code == 'helper_exited',
  'one throwing callback prevented the remaining pending requests from completing')
drain(true)
assert(drained_calls == 1)

-- A pipe that closes after the running check still completes the operation.
local disconnecting_grid = sessions.new(connection.snapshot().client, { schema = 'public', name = 'fixture', columns = {} }, 'second')
local disconnected_coherent
disconnecting_grid:load(0, nil, function(err)
  assert(err)
  disconnected_coherent = app.client == nil and connection.snapshot().client == nil
end)
nested_helper.write_failure = true
local write_calls, write_error = 0, nil
local write_accepted = pcall(function()
  connection.refresh_schema(function(err) write_calls, write_error = write_calls + 1, err end)
end)
assert(write_accepted and write_calls == 1 and write_error.code == 'helper_exited',
  'closed request pipe raised instead of completing the schema operation')
assert(not write_error.message:find('never-print-this-secret', 1, true))
nested_helper.on_exit({ code = 7, signal = 0 })
drain()
assert(write_calls == 1, 'pipe failure and subsequent helper exit completed callback twice')
assert(disconnected_coherent, 'grid disconnect callback observed a dead facade connection')
disconnecting_grid:close()

assert(notices['Could not update the SQL connection view'] == 2)
assert(notices['A SQL connection callback failed'] == 1, 'unexpected connection callback failure')
assert(notices['A SQL request callback failed'] == 1, 'unexpected request callback failure')

vim.system, vim.schedule, vim.notify = original_system, original_schedule, original_notify
print('connection lifecycle tests passed')
