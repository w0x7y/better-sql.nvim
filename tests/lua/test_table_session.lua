vim.opt.runtimepath:append(vim.fn.getcwd())
local sessions = require("better_sql.table_session")
local columns = { { name = "id", editable = false }, { name = "value", editable = true } }
local relation = { schema = "public", name = "items", columns = columns, primary_key = { "id" } }
local function cell(text) return { text = text, is_null = false } end
local function row(handle, id, value)
  return { handle = handle, key = { cell(id) }, cells = { cell(id), cell(value) } }
end
local function page(rows, offset, more)
  return { columns = columns, rows = rows, offset = offset or 0, has_more = more or false, editable = true }
end
local function transport()
  local requests = {}
  return { request = function(_, method, params, callback)
    requests[#requests + 1] = { method = method, params = params, callback = callback }
  end }, requests
end

-- Sessions need no buffers; snapshots cannot mutate their originals or edits.
local client, requests = transport()
local left = sessions.new(client, relation, "test")
left:load(0)
requests[1].callback(nil, page({ row("left", "1", "original") }, 0, true))
assert(not left:stage("left", "value", "pending", false))
local snapshot = left:snapshot()
assert(snapshot.pending_count == 1 and snapshot.page.rows[1].cells[2].text == "pending")
snapshot.page.rows[1].cells[2].text = "mutated"
snapshot.page.rows[1].key[1].text = "wrong key"
snapshot.filters[1] = { column = "id", operator = "=", value = "99" }
assert(left:snapshot().page.rows[1].cells[2].text == "pending")
local old_prompt = left:guard()
left:load(100)
assert(not old_prompt(), "a prompt survived page navigation")
assert(left:stage("left", "value", "during loading", false), "loading accepted an edit")
requests[2].callback(nil, page({ row("last", "101", "last") }, 100))
left:load(0)
requests[3].callback(nil, page({ row("new", "1", "external") }, 0, true))
assert(left:snapshot().page.rows[1].handle == "left", "ordinary paging silently rebased a staged row")

-- Saving only clears submitted cells, allowing a newer edit to remain pending.
local calls = 0
left:save(function(err) assert(not err); calls = calls + 1 end)
assert(requests[4].params.edits[1].handle == "left")
left:stage("left", "value", "newer", false)
requests[4].callback(nil, { rows = { row("left", "1", "pending") } })
assert(calls == 1 and left:snapshot().pending_count == 1)
assert(left:snapshot().page.rows[1].cells[2].text == "newer")
left:discard("left", "value")
assert(left:snapshot().pending_count == 0)

-- Queued pages calculate retention after the preceding grid receives rows.
local right = sessions.new(client, relation, "test")
local third = sessions.new(client, relation, "test")
right:load(0)
third:load(0)
assert(#requests == 5)
requests[5].callback(nil, page({ row("right", "2", "right") }))
assert(#requests == 6)
assert(vim.deep_equal(requests[6].params.retain_handles, { "left", "right" }))
requests[6].callback(nil, page({ row("third", "3", "third") }))

-- Closing a queued or active grid completes immediately, exactly once.
right:load(100)
local queued_calls, queued_error = 0
third:load(100, nil, function(err) queued_calls, queued_error = queued_calls + 1, err end)
third:close()
assert(queued_calls == 1 and queued_error.code == "table_closed")
requests[7].callback(nil, page({ row("right_last", "102", "right last") }, 100))
assert(#requests == 7 and queued_calls == 1)
local active_calls, active_error = 0
right:load(0, nil, function(err) active_calls, active_error = active_calls + 1, err end)
local delayed = requests[8]
right:close()
assert(active_calls == 1 and active_error.code == "table_closed")
delayed.callback(nil, page({ row("late", "2", "late") }))
assert(active_calls == 1)

-- Connection loss also completes an in-flight save without waiting for transport.
left:stage("left", "value", "keep", false)
local save_calls, save_error = 0
left:save(function(err) save_calls, save_error = save_calls + 1, err end)
local lost_save = requests[9]
sessions.disconnect(client)
assert(save_calls == 1 and save_error.code == "connection_changed")
assert(left:snapshot().needs_reload and left:snapshot().pending_count == 1)
lost_save.callback(nil, { rows = { row("left", "1", "keep") } })
assert(save_calls == 1 and left:snapshot().pending_count == 1)

-- Filtered recovery scans hidden keys, retaining both visible and recovered rows.
local reconnected, fresh = transport()
sessions.set_connection(reconnected, "test")
left:reload()
fresh[1].callback(nil, page({ row("fresh", "1", "server") }))
left:load(0, { filters = { { column = "id", operator = "=", value = "205" } } })
fresh[2].callback(nil, page({ row("visible", "205", "visible") }))
left:reload()
fresh[3].callback(nil, page({ row("filtered", "205", "visible") }))
assert(#fresh == 4 and #fresh[4].params.filters == 0)
fresh[4].callback(nil, page({ row("recovered", "1", "server") }))
assert(left:snapshot().pending_count == 1 and left:snapshot().page.rows[1].handle == "filtered")
left:save()
assert(fresh[5].params.edits[1].handle == "recovered")
fresh[5].callback(nil, { rows = { row("recovered", "1", "keep") } })
assert(left:snapshot().loading and #fresh == 6)
local switch_error
sessions.before_switch(function() error("save refresh should not prompt") end, function(err) switch_error = err end)
assert(switch_error and switch_error.code == "busy", "switch abandoned a save during criteria refresh")
fresh[6].callback(nil, page({ row("filtered_again", "205", "visible") }))
assert(left:snapshot().pending_count == 0)
left:stage("filtered_again", "value", "committed", false)
local committed_calls, committed_error, committed_result = 0
left:save(function(err, result)
  committed_calls, committed_error, committed_result = committed_calls + 1, err, result
end)
local committed = { rows = { row("filtered_again", "205", "committed") } }
fresh[7].callback(nil, committed)
local abandoned_refresh = fresh[8]
sessions.disconnect(reconnected)
assert(committed_calls == 1 and committed_error.code == "refresh_failed" and committed_result == committed,
  "connection loss after commit did not distinguish the failed refresh")
abandoned_refresh.callback(nil, page({ row("late_refresh", "205", "committed") }))
assert(committed_calls == 1 and left:snapshot().pending_count == 0)
left:close()

-- Renderer failure and a throwing completion callback cannot stall other grids.
local other, pending = transport()
local broken = sessions.new(other, relation, "test", function() error("renderer failed") end)
local broken_error
broken:load(0, nil, function(err) broken_error = err end)
assert(broken_error.code == "render_error" and #pending == 0)
broken:close()
local first = sessions.new(other, relation, "test")
local second = sessions.new(other, relation, "test")
first:load(0, nil, function() error("completion failed") end)
second:load(0)
local ok = pcall(pending[1].callback, nil, page({ row("first", "1", "first") }))
assert(not ok and #pending == 2, "throwing callback stalled the helper queue")
pending[2].callback(nil, page({ row("second", "2", "second") }))
assert(not second:snapshot().loading)
first:close(); second:close()
-- A trigger can change the key while a newer edit is still staged.
local triggered, trigger_requests = transport()
local trigger_grid = sessions.new(triggered, relation, "test")
trigger_grid:load(0)
trigger_requests[1].callback(nil, page({ row("trigger", "1", "original") }))
trigger_grid:stage("trigger", "value", "submitted", false)
trigger_grid:save()
trigger_grid:stage("trigger", "value", "newer", false)
trigger_requests[2].callback(nil, { rows = { row("trigger", "2", "submitted") } })
trigger_grid:load(0)
trigger_requests[3].callback(nil, page({ row("new_handle", "2", "submitted") }))
assert(trigger_grid:snapshot().page.rows[1].handle == "trigger", "trigger key change rebased a newer pending edit")
sessions.disconnect(triggered)
local new_triggered, reload_requests = transport()
sessions.set_connection(new_triggered, "test")
trigger_grid:reload()
reload_requests[1].callback(nil, page({ row("fresh_trigger", "2", "submitted") }))
assert(not trigger_grid:snapshot().error and #trigger_grid:snapshot().page.rows == 1,
  "trigger key change made a surviving staged row unmatched")
assert(trigger_grid:snapshot().page.rows[1].cells[2].text == "newer")
trigger_grid:close()

-- A faulty caller cannot interrupt lifecycle invalidation of the other grids.
for _, change in ipairs({ "disconnect", "replace" }) do
  local source, source_requests = transport()
  local a = sessions.new(source, relation, "test")
  local b = sessions.new(source, relation, "test")
  local completions = 0
  a:load(0, nil, function(err)
    assert(err.code == "connection_changed")
    completions = completions + 1
    error("caller failed")
  end)
  b:load(0, nil, function(err)
    assert(err.code == "connection_changed")
    completions = completions + 1
  end)
  local ok = pcall(function()
    if change == "disconnect" then sessions.disconnect(source)
    else sessions.set_connection(transport(), "test") end
  end)
  assert(ok and completions == 2, "a callback exception interrupted connection invalidation")
  source_requests[1].callback(nil, page({ row("late", "1", "late") }))
  assert(completions == 2 and #source_requests == 1)
  assert(a:snapshot().needs_reload and b:snapshot().needs_reload)
  a:close(); b:close()
end

-- Discarding all edits removes review-only rows whose keys no longer exist.
local deleted, deleted_requests = transport()
local deleted_grid = sessions.new(deleted, relation, "test")
deleted_grid:load(0)
deleted_requests[1].callback(nil, page({ row("deleted", "1", "original") }))
deleted_grid:stage("deleted", "value", "pending", false)
deleted_grid:reload()
deleted_requests[2].callback(nil, page({}))
assert(deleted_grid:snapshot().pending_count == 1 and #deleted_grid:snapshot().page.rows == 1)
local discarded
sessions.before_switch(function(resolve) resolve("Discard") end, function(err) assert(not err); discarded = true end)
assert(discarded and deleted_grid:snapshot().pending_count == 0)
assert(#deleted_grid:snapshot().page.rows == 0, "discard left a deleted row editable in the grid")
deleted_grid:close()

-- An activation observer can open a grid already bound to the new helper.
local activated, activation_requests = transport()
local observer_grid = sessions.new(activated, relation, "test")
local observer_calls = 0
observer_grid:load(0, nil, function(err) assert(not err); observer_calls = observer_calls + 1 end)
sessions.set_connection(activated, "test")
assert(observer_calls == 0 and not observer_grid:snapshot().needs_reload,
  "activation invalidated a new grid already using its helper")
activation_requests[1].callback(nil, page({ row("observer", "1", "original") }))
assert(observer_calls == 1 and observer_grid:snapshot().page.rows[1].handle == "observer")
observer_grid:close()
print("table session tests passed")
