vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd('runtime plugin/better_sql.lua')
local Client = require('better_sql.client')
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end

local malformed = Client.new({})
malformed.process = { write = function() end, kill = function() end }
local failure
malformed:request('ping', {}, function(err) failure = err end)
malformed:_on_stdout('password=never-print-this-secret\n')
assert(vim.wait(1000, function() return failure ~= nil end), 'malformed response left callback pending')
assert(failure.code == 'invalid_response')
assert(failure.message:find('JSON', 1, true))
assert(not failure.message:find('never-print-this-secret', 1, true))

local helper = vim.fn.tempname() .. '.py'
vim.fn.writefile({ 'import sys', 'sys.stdin.readline()',
  'sys.stderr.write("ModuleNotFoundError: No module named psycopg password=never-print-this-secret\\n")',
  'sys.exit(7)' }, helper)
local died = Client.new({ helper = helper })
local errors = {}
died:start()
for _ = 1, 2 do died:request('ping', {}, function(err) errors[#errors + 1] = err end) end
assert(vim.wait(3000, function() return #errors == 2 end), 'helper death left pending callbacks')
assert(errors[1].code == 'helper_exited')
assert(errors[1].message:find('psycopg', 1, true), 'stderr did not provide an actionable diagnostic')
assert(not vim.inspect(errors):find('never-print-this-secret', 1, true))
vim.fn.delete(helper)

local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn, 'BETTER_SQL_TEST_DSN is required')
local app = require('better_sql')
app.setup({ connections = { local_db = dsn } })
local connected
app.connect('local_db', function(err) assert(not err, vim.inspect(err)); connected = true end)
assert(vim.wait(3000, function() return connected and require('better_sql.schema').get_catalog() ~= nil end))
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'select pg_sleep(10)' })
app.run_buffer()
local responsive = false
vim.defer_fn(function() responsive = true; vim.cmd('BetterSqlCancel') end, 150)
assert(vim.wait(3000, function() return app.last_query_error ~= nil end), 'query cancellation timed out')
assert(responsive, 'editor event loop was blocked')
assert(app.last_query_error.error.code == 'cancelled')
assert(table.concat(vim.api.nvim_buf_get_lines(require('better_sql.results').current_buffer, 0, -1, false), '\n'):find('ancel', 1, true))
local usable
app.client:request('query.run', { sql = 'select 1' }, function(err, result)
  assert(not err, vim.inspect(err)); usable = result.sets[1].rows[1][1].text
end)
assert(vim.wait(3000, function() return usable end) and usable == '1')
local grid = require('better_sql.table')
local fixture_schema = 'better_sql_recovery_' .. vim.fn.getpid()
local function sql(text)
  local done, failure, result
  app.client:request('query.run', { sql = text }, function(err, value)
    done, failure, result = true, err, value
  end)
  assert(vim.wait(3000, function() return done end))
  assert(not failure, vim.inspect(failure))
  return result
end
sql('CREATE SCHEMA ' .. fixture_schema)
sql('CREATE TABLE ' .. fixture_schema .. '.items (id int primary key, value text)')
sql("INSERT INTO " .. fixture_schema .. ".items VALUES (1, 'original')")
local refreshed
app.refresh_schema(function(err) assert(not err); refreshed = true end)
assert(vim.wait(3000, function() return refreshed end))
local grid_buf = app.open_relation(fixture_schema, 'items')
local function grid_text()
  return table.concat(vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false), '\n')
end
assert(vim.wait(3000, function() return grid_text():find('Rows ', 1, true) end))
local old_handle = grid.current_cell().row_handle
grid.stage(old_handle, 'value', 'keep this staged text', false)
assert(grid.pending_count() == 1)
local dead = app.client
local drained
dead:request('query.run', { sql = 'select pg_sleep(10)' }, function(err) drained = err end)
dead.process:kill(9)
assert(vim.wait(3000, function() return drained and app.client == nil end))
assert(drained.code == 'helper_exited')
assert(grid.pending_count() == 1 and grid_text():find('keep this staged text', 1, true), 'helper death lost visible edits')
assert(table.concat(notices, '\n'):find('BetterSqlReconnect', 1, true), 'no reconnect advice on helper death')
vim.cmd('BetterSqlReconnect')
assert(vim.wait(3000, function() return app.client and app.client ~= dead end), 'reconnect failed')
assert(grid.pending_count() == 1 and grid_text():find('keep this staged text', 1, true))
local save_error
grid.save(function(err) save_error = err end)
assert(save_error and save_error.code == 'reload_required', 'reconnect allowed stale row handles to save')
grid.reload()
assert(vim.wait(3000, function()
  return grid_text():find('Rows ', 1, true) and not grid_text():find('Loading', 1, true)
end))
assert(grid.current_cell().row_handle ~= old_handle)
assert(grid.pending_count() == 1 and grid_text():find('keep this staged text', 1, true))
local saved
grid.save(function(err) assert(not err, vim.inspect(err)); saved = true end)
assert(vim.wait(3000, function() return saved end))
assert(sql('SELECT value FROM ' .. fixture_schema .. '.items').sets[1].rows[1][1].text == 'keep this staged text')
sql('DROP SCHEMA ' .. fixture_schema .. ' CASCADE')
app.client:stop()
print('recovery tests passed')
