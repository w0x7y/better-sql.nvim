vim.opt.runtimepath:append(vim.fn.getcwd())

-- Keep the real Client, connection and sessions; control only transport and choices.
local original_system, original_schedule, original_select = vim.system, vim.schedule, vim.ui.select
local helpers, scheduled, choices, default_choices = {}, {}, {}, {}
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
vim.system = function(_, options, on_exit)
  local helper = { options = options, on_exit = on_exit, requests = {} }
  local process = {}
  function process:write(line) helper.requests[#helper.requests + 1] = vim.json.decode(line) end
  function process:kill() helper.killed = true end
  helpers[#helpers + 1] = helper
  return process
end
vim.ui.select = function(items, options, resolve)
  default_choices[#default_choices + 1] = { items = items, options = options, resolve = resolve }
end
local function drain()
  while #scheduled > 0 do table.remove(scheduled, 1)() end
end
local function reply(helper, request, result, err)
  helper.options.stdout(nil, vim.json.encode({ id = request.id, ok = not err, result = result, error = err }) .. '\n')
  drain()
end
local function ready(helper, name)
  reply(helper, helper.requests[1], { database = name, user = 'tester' })
  reply(helper, helper.requests[2], { schemas = {} })
end
local connection = require('better_sql.connection')
local sessions = require('better_sql.table_session')
local config = {
  connections = { first = 'dbname=first', second = 'dbname=second' },
  choose_pending_edits = function(resolve) choices[#choices + 1] = resolve end,
}
connection.connect('first', config, function(err) assert(not err) end)
local first = helpers[1]
ready(first, 'first')
local columns = { { name = 'id', editable = false }, { name = 'value', editable = true } }
local relation = { schema = 'public', name = 'items', columns = columns }
local function row(value)
  return { handle = 'row', key = { { text = '1', is_null = false } }, cells = {
    { text = '1', is_null = false }, { text = value, is_null = false },
  } }
end
local grid = sessions.new(connection.snapshot().client, relation, 'first', nil, {
  columns = columns, rows = { row('original') }, offset = 0, has_more = false, editable = true,
})
local function stage(value) assert(not grid:stage('row', 'value', value, false)) end

-- Stay checks staged cells before starting a helper and keeps the active session.
stage('keep')
local calls, switch_error = 0, nil
connection.connect('second', config, function(err) calls, switch_error = calls + 1, err end)
assert(#choices == 1 and #default_choices == 0, 'connection ignored the configured session chooser')
assert(#helpers == 1 and calls == 0, 'helper started before the staged-edit choice')
choices[1]('Stay')
choices[1]('Discard')
assert(calls == 1 and switch_error.code == 'switch_cancelled')
assert(grid:snapshot().pending_count == 1 and connection.snapshot().profile == 'first' and not first.killed)

-- Save completes its request before connection work, then checks newly staged edits.
calls, switch_error = 0, nil
connection.connect('second', config, function(err) calls, switch_error = calls + 1, err end)
choices[2]('Save')
local save_request = first.requests[#first.requests]
assert(save_request.method == 'table.save' and #helpers == 1 and calls == 0)
assert(save_request.params.edits[1].changes[1].text == 'keep')
reply(first, save_request, { rows = { row('keep') } })
local candidate = helpers[#helpers]
assert(#helpers == 2 and grid:snapshot().pending_count == 0)
stage('during connect')
ready(candidate, 'second')
assert(#choices == 3 and calls == 0 and connection.snapshot().profile == 'first',
  'activation skipped edits staged during connection and catalog loading')
choices[3]('Stay')
choices[3]('Save')
assert(calls == 1 and switch_error.code == 'switch_cancelled' and candidate.killed and not first.killed)
assert(grid:snapshot().pending_count == 1)

-- Failed saves leave both staged cells and the current connection in place.
calls, switch_error = 0, nil
local helper_count = #helpers
connection.connect('second', config, function(err) calls, switch_error = calls + 1, err end)
choices[4]('Save')
save_request = first.requests[#first.requests]
reply(first, save_request, nil, { code = 'conflict', message = 'row changed' })
assert(calls == 1 and switch_error.code == 'conflict' and #helpers == helper_count)
assert(grid:snapshot().pending_count == 1 and not first.killed)

-- A save in flight blocks the switch without opening another chooser.
local save_calls = 0
grid:save(function(err) assert(not err); save_calls = save_calls + 1 end)
save_request = first.requests[#first.requests]
calls, switch_error = 0, nil
connection.connect('second', config, function(err) calls, switch_error = calls + 1, err end)
assert(calls == 1 and switch_error.code == 'busy' and #choices == 4 and #helpers == helper_count)
reply(first, save_request, { rows = { row('during connect') } })
assert(save_calls == 1)

-- A newer edit while saving cannot be silently carried into another profile.
stage('submitted')
calls, switch_error = 0, nil
connection.connect('second', config, function(err) calls, switch_error = calls + 1, err end)
choices[5]('Save')
save_request = first.requests[#first.requests]
stage('newer')
reply(first, save_request, { rows = { row('submitted') } })
assert(calls == 1 and switch_error.code == 'pending_changed' and #helpers == helper_count)
assert(grid:snapshot().page.rows[1].cells[2].text == 'newer')

-- Superseded choices cannot start stale work, including a reentrant attempt.
local old_calls, middle_calls, latest_calls = 0, 0, 0
local latest_error
connection.connect('second', config, function(err)
  old_calls = old_calls + 1
  assert(err.code == 'connect_superseded')
  connection.connect('second', config, function(err2)
    latest_calls, latest_error = latest_calls + 1, err2
  end)
end)
local old_choice = choices[6]
connection.connect('second', config, function(err)
  middle_calls = middle_calls + 1
  assert(err.code == 'connect_superseded')
end)
assert(old_calls == 1 and middle_calls == 1 and latest_calls == 0)
assert(#choices == 7, 'superseded middle attempt opened another staged-edit chooser')
old_choice('Discard')
assert(#helpers == helper_count and old_calls == 1, 'obsolete choice started a helper')
assert(grid:snapshot().pending_count == 1, 'obsolete choice discarded the active session edits')
choices[#choices]('Discard')
candidate = helpers[#helpers]
ready(candidate, 'second')
assert(latest_calls == 1 and not latest_error and first.killed and not candidate.killed)
assert(grid:snapshot().pending_count == 0 and grid:snapshot().needs_reload)
grid:close()

-- The default presentation keeps the established Vim chooser and cancellation.
local default_grid = sessions.new(connection.snapshot().client, relation, 'second', nil, {
  columns = columns, rows = { row('original') }, offset = 0, has_more = false, editable = true,
})
assert(not default_grid:stage('row', 'value', 'default pending', false))
local default_config = { connections = config.connections }
calls, switch_error = 0, nil
connection.connect('first', default_config, function(err) calls, switch_error = calls + 1, err end)
assert(#default_choices == 1)
assert(vim.deep_equal(default_choices[1].items, { 'Save', 'Discard', 'Stay' }))
assert(default_choices[1].options.prompt == 'Pending table edits before switching profiles:')
default_choices[1].resolve(nil)
assert(calls == 1 and switch_error.code == 'switch_cancelled' and default_grid:snapshot().pending_count == 1)
default_grid:close()

assert(package.loaded['better_sql.table'] == nil, 'connection loaded the table renderer')
local app = require('better_sql')
app.setup(config)
assert(app.config.choose_pending_edits == config.choose_pending_edits, 'setup dropped the session choice adapter')
vim.system, vim.schedule, vim.ui.select = original_system, original_schedule, original_select
print('connection session choice tests passed')
