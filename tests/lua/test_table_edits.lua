vim.opt.runtimepath:append(vim.fn.getcwd())
local grid = require("better_sql.table")
local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function cell(text, null) return { text = text, is_null = null or false } end
local columns = {
  { name = "id", editable = false, read_only_reason = "primary_key" },
  { name = "username", editable = true }, { name = "email", editable = true },
  { name = "generated", editable = false, read_only_reason = "generated" },
}
local function row(handle, id, username)
  return { handle = handle, key = { cell(id) }, cells = { cell(id), cell(username), cell("mail"), cell("computed") } }
end
local function page(rows, offset, more)
  return { columns = columns, rows = rows, offset = offset or 0, has_more = more or false, editable = true }
end
local requests = {}
local client = { request = function(_, method, params, callback)
  requests[#requests + 1] = { method = method, params = params, callback = callback }
end }
local buf = grid.open(client, { schema = "public", name = "users", columns = columns, primary_key = { "id" } }, "test")
requests[#requests].callback(nil, page({ row("r1", "1", "one"), row("r2", "2", "two") }, 0, true))
assert(type(grid.stage) == "function", "table.stage is missing")
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
key("e")
assert(grid.pending_count() == 0)
assert(table.concat(notices):find("primary", 1, true), "blocked cell reason missing")
key("l")
vim.ui.input = function(options, callback)
  assert(options.default == "one")
  callback("")
end
key("e")
assert(grid.pending_count() == 1)
assert(content(buf):find('*""', 1, true), "empty staged cell marker missing")
assert(content(buf):find("Pending: 1", 1, true))
key("lN")
assert(grid.pending_count() == 2)
assert(content(buf):find("*NULL", 1, true))
key("u")
assert(grid.pending_count() == 1)
local delayed_input
vim.ui.input = function(_, callback) delayed_input = callback end
key("e")
key("]p")
grid.stage("r2", "username", "while loading", false)
assert(grid.pending_count() == 1, "paging accepted an edit for a handle being evicted")
assert(vim.deep_equal(requests[#requests].params.retain_handles, { "r1" }), "next page lost staged original")
requests[#requests].callback(nil, page({ row("r101", "101", "last") }, 100))
delayed_input("late input from old page")
assert(grid.pending_count() == 1, "old cell input was applied after page navigation")
grid.stage("r2", "username", "evicted original", false)
assert(grid.pending_count() == 1, "an evicted row handle remained editable")
key("[p")
assert(vim.deep_equal(requests[#requests].params.retain_handles, { "r1" }), "previous page lost staged original")
requests[#requests].callback(nil, page({ row("new1", "1", "external"), row("new2", "2", "two") }, 0, true))
key("h")
assert(grid.current_cell().row_handle == "r1", "paging rebased the original version without review")
assert(grid.current_cell().cell.text == "", "staged text lost after paging")
key("s")
local save = requests[#requests]
assert(save.method == "table.save")
assert(vim.deep_equal(save.params.edits, { { handle = "r1", changes = { { column = "username", text = "", is_null = false } } } }))
save.callback({ code = "database_error", message = "bad input", handle = "r1", column = "username", sqlstate = "22P02" })
assert(grid.pending_count() == 1)
assert(content(buf):find("Column: username", 1, true) and content(buf):find("22P02", 1, true) and content(buf):find("Row: [1]", 1, true))
grid.save()
requests[#requests].callback({ code = "database_error", message = "bad input", handle = "r1", columns = { "username", "email" } })
assert(content(buf):find("Columns: username, email", 1, true), "save omitted the affected columns")
grid.save()
local in_flight = requests[#requests]
grid.stage("r1", "username", "later", false)
local refreshed = row("r1", "1", "")
refreshed.xmin = "new-version"
in_flight.callback(nil, { rows = { refreshed } })
assert(grid.pending_count() == 1, "save cleared a newer edit")
assert(grid.current_cell().cell.text == "later")
grid.save()
requests[#requests].callback(nil, { rows = { row("r1", "1", "later") } })
assert(grid.pending_count() == 0)
assert(not content(buf):find("*later", 1, true))
key("llN")
assert(grid.pending_count() == 0 and table.concat(notices):find("generated", 1, true))
-- Cancellation leaves the cell alone; off-page staged rows recover by key too.
key("hh")
vim.ui.input = function(_, callback) callback(nil) end
key("e")
assert(grid.pending_count() == 0)
grid.stage("r1", "username", "first recovered", false)
key("]p")
requests[#requests].callback(nil, page({ row("r101", "101", "last") }, 100))
grid.stage("r101", "username", "last recovered", false)
grid.disconnect(client)
grid.set_connection(client, "test")
local before = #requests
grid.save()
assert(#requests == before, "disconnected originals were sent to save")
key("r")
assert(vim.deep_equal(requests[#requests].params.retain_handles, {}), "reload sent stale handles")
requests[#requests].callback(nil, page({ row("fresh1", "1", "server first") }, 0, true))
assert(requests[#requests].params.offset == 100, "reload stopped before recovering off-page edits")
assert(vim.deep_equal(requests[#requests].params.retain_handles, { "fresh1" }))
requests[#requests].callback(nil, page({ row("fresh101", "101", "server last") }, 100))
assert(grid.pending_count() == 2)
grid.save()
local recovered_save = requests[#requests]
assert(recovered_save.params.edits[1].handle == "fresh1" and recovered_save.params.edits[2].handle == "fresh101")
recovered_save.callback({ code = "helper_exited", message = "helper process exited" })
assert(grid.pending_count() == 2)
-- Failed reloads must leave staged text visible, including off-page originals.
key("r")
requests[#requests].callback({ code = "database_error", message = "reload failed" })
assert(content(buf):find("first recovered", 1, true) and content(buf):find("last recovered", 1, true),
  "failed reload hid the retained staged text")
-- A completed reload cannot find either original key because both rows were deleted.
key("r")
requests[#requests].callback(nil, page({ row("reload1", "50", "other first") }, 0, true))
requests[#requests].callback(nil, page({ row("reload101", "150", "other row") }, 100))
assert(content(buf):find("Unmatched rows", 1, true))
-- Unmatched pending cells remain visible and selectable on every page.
key("]p")
requests[#requests].callback(nil, page({ row("page101", "150", "other row") }, 100))
assert(content(buf):find("first recovered", 1, true) and content(buf):find("last recovered", 1, true),
  "next page hid unmatched edits")
key("[p")
requests[#requests].callback(nil, page({ row("page1", "50", "other first") }, 0, true))
assert(content(buf):find("first recovered", 1, true) and content(buf):find("last recovered", 1, true),
  "previous page hid unmatched edits")
local unmatched_save_count = #requests
grid.save()
assert(#requests == unmatched_save_count, "paging allowed a save with unmatched handles")
vim.api.nvim_win_set_cursor(0, { 7, 0 }); key("lu")
assert(grid.pending_count() == 1, "unmatched edit was not selectable after paging")
assert(content(buf):find("last recovered", 1, true))
vim.api.nvim_buf_delete(buf, { force = true })

-- A profile switch cannot abandon edits entered after its save started.
buf = grid.open(client, { schema = "public", name = "users", columns = columns, primary_key = { "id" } }, "test")
requests[#requests].callback(nil, page({ row("race1", "1", "original") }))
grid.stage("race1", "username", "save first", false)
vim.ui.select = function(_, _, callback) callback("Save") end
local switch_done, switch_error
grid.before_switch(function(err) switch_done, switch_error = true, err end)
local switching_save = requests[#requests]
grid.stage("race1", "username", "new pending", false)
switching_save.callback(nil, { rows = { row("race1", "1", "save first") } })
assert(switch_done and switch_error, "profile switch ignored edits entered during save")
assert(grid.pending_count() == 1)
-- Discard cannot undo an UPDATE already submitted to the helper.
grid.save()
local current_save = requests[#requests]
vim.ui.select = function(_, _, callback) callback("Discard") end
local busy_error
grid.before_switch(function(err) busy_error = err end)
assert(busy_error and grid.pending_count() == 1, "switch discarded an in-flight save")
current_save.callback(nil, { rows = { row("race1", "1", "new pending") } })
vim.api.nvim_buf_delete(buf, { force = true })

-- Each queued page computes retained handles only after the preceding grid loads.
local queued_relation = { schema = "public", name = "users", columns = columns, primary_key = { "id" } }
local request_start = #requests
local queued_left = grid.open(client, queued_relation, "test")
local queued_right = grid.open(client, queued_relation, "test")
assert(#requests == request_start + 1, "two page requests were sent concurrently")
requests[#requests].callback(nil, page({ row("queued_left", "1", "left") }))
assert(#requests == request_start + 2)
assert(vim.deep_equal(requests[#requests].params.retain_handles, { "queued_left" }),
  "queued page did not retain the newly loaded grid")
requests[#requests].callback(nil, page({ row("queued_right", "2", "right") }))
vim.api.nvim_buf_delete(queued_left, { force = true })
vim.api.nvim_buf_delete(queued_right, { force = true })
-- Wiping a queued grid skips its request without blocking the next live grid.
request_start = #requests
queued_left = grid.open(client, queued_relation, "test")
local wiped = grid.open(client, queued_relation, "test")
queued_right = grid.open(client, queued_relation, "test")
vim.api.nvim_buf_delete(wiped, { force = true })
requests[#requests].callback(nil, page({ row("surviving_left", "1", "left") }))
assert(#requests == request_start + 2, "wiped grid was requested or live grid stalled")
requests[#requests].callback(nil, page({ row("surviving_right", "2", "right") }))
assert(content(queued_right):find("Rows ", 1, true))
vim.api.nvim_buf_delete(queued_left, { force = true })
vim.api.nvim_buf_delete(queued_right, { force = true })
-- Helper exit drains queued requests without attempting another write to it.
request_start = #requests
queued_left = grid.open(client, queued_relation, "test")
queued_right = grid.open(client, queued_relation, "test")
requests[#requests].callback({ code = "helper_exited", message = "helper process exited" })
assert(#requests == request_start + 1, "queued page was sent to an exited helper")
assert(content(queued_right):find("helper process exited", 1, true), "queued view remained loading after exit")
vim.api.nvim_buf_delete(queued_left, { force = true })
vim.api.nvim_buf_delete(queued_right, { force = true })

-- Real milestone flow validates the Lua/helper/database boundary, transaction rollback,
-- replacement versions, reconnect recovery and profile resolution.
local better_sql = require("better_sql")
local dsn = assert(vim.env.BETTER_SQL_TEST_DSN)
better_sql.setup({ connections = { local_db = dsn, other_db = dsn }, python = ".venv/bin/python" })
local function connect(name)
  local done, failure
  better_sql.connect(name, function(err) done, failure = true, err end)
  assert(vim.wait(3000, function() return done end), "connect timed out")
  assert(not failure, vim.inspect(failure))
end
connect("local_db")
local function sql(statement)
  local done, failure, result
  better_sql.client:request("query.run", { sql = statement, max_rows = 1000, max_bytes = 65536 }, function(err, value)
    done, failure, result = true, err, value
  end)
  assert(vim.wait(3000, function() return done end), "SQL timed out")
  assert(not failure, vim.inspect(failure))
  return result
end
local schema_name = "better_sql_edits_" .. vim.fn.getpid()
sql("CREATE SCHEMA " .. schema_name)
sql("CREATE TABLE " .. schema_name .. ".users (tenant text, id int, username text CHECK (username <> 'blocked'), email text, amount integer, PRIMARY KEY (tenant, id))")
sql("INSERT INTO " .. schema_name .. ".users VALUES ('a',1,'first','mail',0),('b',1,'second','mail',0)")
local refreshed_catalog
better_sql.refresh_schema(function(err) assert(not err); refreshed_catalog = true end)
assert(vim.wait(3000, function() return refreshed_catalog end))
buf = better_sql.open_relation(schema_name, "users")
local function loaded()
  return vim.wait(3000, function() return (content(buf):find("Rows ", 1, true) or content(buf):find("Unmatched rows", 1, true)) and not content(buf):find("Loading", 1, true) end)
end
assert(loaded())
key("ll")
local first_handle = grid.current_cell().row_handle
grid.stage(first_handle, "username", "", false)
key("j")
local second_handle = grid.current_cell().row_handle
grid.stage(second_handle, "email", "", true)
sql("UPDATE " .. schema_name .. ".users SET username='external' WHERE tenant='b'")
local function save_grid()
  local calls, failure = 0
  grid.save(function(err) calls, failure = calls + 1, err end)
  assert(vim.wait(3000, function() return calls > 0 end), "save timed out")
  assert(calls == 1, "save callback completed more than once")
  assert(not vim.bo[buf].modifiable, "save left grid modifiable")
  return failure
end
assert(save_grid().code == "edit_conflict")
assert(grid.pending_count() == 2)
local actual = sql("SELECT username,email FROM " .. schema_name .. ".users ORDER BY tenant").sets[1].rows
assert(actual[1][1].text == "first" and actual[2][1].text == "external" and actual[2][2].text == "mail", "batch did not roll back")
key("r")
assert(loaded())
assert(grid.pending_count() == 2)
assert(not save_grid())
assert(grid.pending_count() == 0)
actual = sql("SELECT username,email FROM " .. schema_name .. ".users ORDER BY tenant").sets[1].rows
assert(actual[1][1].text == "" and not actual[1][1].is_null)
assert(actual[2][1].text == "external" and actual[2][2].is_null)
-- Another save must use the refreshed xmin.
grid.stage(grid.current_cell().row_handle, "username", "second saved", false)
assert(not save_grid())

-- A real conversion error includes the invalid value's newline.
local invalid_handle = grid.current_cell().row_handle
grid.stage(invalid_handle, "amount", "bad\nvalue", false)
local conversion_error = save_grid()
assert(conversion_error and conversion_error.sqlstate == "22P02")
assert(grid.pending_count() == 1)
assert(content(buf):find("bad\\nvalue", 1, true))
grid.discard(invalid_handle, "amount")
assert(grid.pending_count() == 0)

-- After reconnect, saving is blocked until explicit reload. Composite keys must
-- not mix the two rows that share id=1; SQL NULL stays distinct from empty text.
key("k")
local old_handle = grid.current_cell().row_handle
grid.stage(old_handle, "username", "recovered first", false)
key("j")
grid.stage(grid.current_cell().row_handle, "username", "deleted pending", false)
sql("DELETE FROM " .. schema_name .. ".users WHERE tenant='b'")
local old_client = better_sql.client
old_client:stop()
assert(vim.wait(3000, function() return better_sql.client == nil end))
assert(grid.pending_count() == 2)
connect("local_db")
local sent_saves = {}
local original_request = better_sql.client.request
better_sql.client.request = function(self, method, params, callback)
  if method == "table.save" then sent_saves[#sent_saves + 1] = params end
  return original_request(self, method, params, callback)
end
assert(save_grid(), "save should require reload")
assert(#sent_saves == 0)
key("r")
assert(loaded())
assert(content(buf):find("deleted pending", 1, true), "unmatched staged value disappeared")
assert(content(buf):find("recovered first", 1, true))
assert(save_grid(), "unmatched key should block atomic save")
assert(#sent_saves == 0)
-- The unmatched row remains selectable so u can discard its pending cell.
vim.api.nvim_win_set_cursor(0, { 7, 0 })
key("llu")
assert(grid.pending_count() == 1)
assert(not save_grid())
assert(#sent_saves == 1 and sent_saves[1].edits[1].handle ~= old_handle)
actual = sql("SELECT username FROM " .. schema_name .. ".users").sets[1].rows
assert(actual[1][1].text == "recovered first")

-- A new edit during connection setup must still be resolved before activation.
vim.api.nvim_win_set_cursor(0, { 6, 0 }); key("ll")
vim.ui.select = function(_, _, callback) callback("Stay") end
local delayed_done, delayed_error
better_sql.connect("other_db", function(err) delayed_done, delayed_error = true, err end)
grid.stage(grid.current_cell().row_handle, "username", "arrived while connecting", false)
assert(vim.wait(3000, function() return delayed_done end))
assert(delayed_error and better_sql.active_profile == "local_db" and grid.pending_count() == 1,
  "connection activation bypassed a newly staged edit")
grid.discard(grid.current_cell().row_handle, "username")

-- Profile switching: stay, failed save, successful save, then discard.
vim.api.nvim_win_set_cursor(0, { 6, 0 }); key("ll")
grid.stage(grid.current_cell().row_handle, "username", "switch save", false)
vim.ui.select = function(items, _, callback) assert(vim.tbl_contains(items, "Stay")); callback("Stay") end
local cancelled
better_sql.connect("other_db", function(err) cancelled = err end)
assert(cancelled and better_sql.active_profile == "local_db" and grid.pending_count() == 1)
vim.ui.select = function(_, _, callback) callback("Save") end
grid.stage(grid.current_cell().row_handle, "username", "blocked", false)
local switch_failed
better_sql.connect("other_db", function(err) switch_failed = err end)
assert(vim.wait(3000, function() return switch_failed ~= nil end))
assert(better_sql.active_profile == "local_db" and grid.pending_count() == 1)
grid.stage(grid.current_cell().row_handle, "username", "switch save", false)
connect("other_db")
assert(grid.pending_count() == 0)
actual = sql("SELECT username FROM " .. schema_name .. ".users").sets[1].rows
assert(actual[1][1].text == "switch save")
connect("local_db")
key("r"); assert(loaded())
grid.stage(grid.current_cell().row_handle, "username", "discard me", false)
vim.ui.select = function(_, _, callback) callback("Discard") end
connect("other_db")
assert(grid.pending_count() == 0)
actual = sql("SELECT username FROM " .. schema_name .. ".users").sets[1].rows
assert(actual[1][1].text == "switch save")
-- Two grids opened before either page returns must both keep usable originals.
sql("INSERT INTO " .. schema_name .. ".users VALUES ('b',1,'second grid','mail',0)")
local relation = { schema = schema_name, name = "users", columns = {}, primary_key = { "tenant", "id" } }
local left = grid.open(better_sql.client, relation, "other_db")
local right = grid.open(better_sql.client, relation, "other_db")
assert(vim.wait(3000, function()
  return content(left):find("Rows ", 1, true) and content(right):find("Rows ", 1, true)
end), "overlapping grids did not load")
vim.api.nvim_set_current_win(vim.fn.bufwinid(left)); key("ll")
grid.stage(grid.current_cell().row_handle, "username", "left grid saved", false)
local left_error = save_grid()
assert(not left_error, "overlapping grid lost its handle: " .. vim.inspect(left_error))
vim.api.nvim_set_current_win(vim.fn.bufwinid(right)); key("jll")
grid.stage(grid.current_cell().row_handle, "username", "right grid saved", false)
assert(not save_grid(), "second grid lost its handle")
actual = sql("SELECT username FROM " .. schema_name .. ".users ORDER BY tenant").sets[1].rows
assert(actual[1][1].text == "left grid saved" and actual[2][1].text == "right grid saved")
sql("DROP SCHEMA " .. schema_name .. " CASCADE")
better_sql.client:stop()
print("table edit tests passed")
