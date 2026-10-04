vim.opt.runtimepath:append(vim.fn.getcwd())
local sessions = require("better_sql.table_session")
local columns = { { name = "id", editable = false }, { name = "value", editable = true } }
local relation = { schema = "public", name = "items", columns = columns, primary_key = { "id" } }
local function cell(text) return { text = text, is_null = false } end
local function row(handle, id)
  return { handle = handle, key = { cell(id) }, cells = { cell(id), cell("server " .. id) } }
end
local function page(rows, offset, next_offset)
  return { columns = columns, rows = rows, offset = offset, page_size = 3,
    next_offset = next_offset or vim.NIL, has_more = next_offset ~= nil, editable = true }
end
local function transport()
  local requests = {}
  return { request = function(_, method, params, callback)
    requests[#requests + 1] = { method = method, params = params, callback = callback }
  end }, requests
end
local tests = {}

function tests.navigation_uses_helper_metadata_and_preserves_failed_page()
  local client, requests = transport()
  local grid = sessions.new(client, relation, "paging")
  grid:load(4)
  requests[1].callback(nil, page({ row("four", "4"), row("five", "5"), row("six", "6") }, 4, 7))
  local calls, failure = 0
  grid:next_page(function(err) calls, failure = calls + 1, err end)
  assert(requests[2].params.offset == 7, "next page ignored the helper offset")
  requests[2].callback({ code = "database_error", message = "retry me" })
  assert(calls == 1 and failure.code == "database_error")
  assert(grid:snapshot().page.offset == 4, "failed navigation changed the current page")
  grid:next_page()
  assert(requests[3].params.offset == 7, "retry skipped the failed page")
  requests[3].callback(nil, page({ row("seven", "7") }, 7))
  grid:next_page()
  assert(#requests == 3, "terminal page requested another page")
  grid:previous_page()
  assert(requests[4].params.offset == 4, "previous page used the short last-page row count")
  requests[4].callback(nil, page({ row("four_again", "4") }, 4, 7))
  grid:load(0, { filters = { { column = "id", operator = "=", value = "missing" } } })
  requests[5].callback(nil, page({}, 0))
  grid:next_page(); grid:previous_page()
  assert(#requests == 5, "empty filtered results advanced the page")
  grid:close()
end

function tests.filtered_recovery_follows_small_pages_and_retains_queued_originals()
  local old_client, old_requests = transport()
  local grid = sessions.new(old_client, relation, "paging")
  grid:load(3)
  old_requests[1].callback(nil, page({ row("old_five", "5"), row("deleted", "99") }, 3))
  grid:stage("old_five", "value", "pending five", false)
  grid:stage("deleted", "value", "pending deleted", false)
  grid:load(0, { filters = { { column = "id", operator = "=", value = "missing" } } })
  old_requests[2].callback(nil, page({}, 0))
  sessions.disconnect(old_client)
  local client, requests = transport()
  sessions.set_connection(client, "paging")
  local other = sessions.new(client, relation, "paging")
  local completed = 0
  grid:reload(function(err) assert(not err); completed = completed + 1 end)
  other:load(0)
  requests[1].callback(nil, page({}, 0))
  assert(#requests == 2 and #requests[2].params.filters == 0)
  requests[2].callback(nil, page({ row("other", "20") }, 0))
  assert(#requests == 3 and requests[3].params.offset == 0 and #requests[3].params.filters == 0)
  requests[3].callback(nil, page({ row("first", "1") }, 0, 3))
  assert(requests[4].params.offset == 3, "recovery assumed a 100-row page")
  assert(vim.deep_equal(requests[4].params.retain_handles, { "other" }))
  requests[4].callback(nil, page({ row("fresh_five", "5") }, 3, 6))
  assert(requests[5].params.offset == 6)
  assert(vim.deep_equal(requests[5].params.retain_handles, { "fresh_five", "other" }),
    "recovery evicted a recovered pending original or another grid's rows")
  requests[5].callback(nil, page({ row("last", "7") }, 6))
  local snapshot = grid:snapshot()
  assert(completed == 1 and snapshot.pending_count == 2 and snapshot.page.offset == 0)
  assert(snapshot.page.page_size == 3 and snapshot.page.next_offset == vim.NIL)
  assert(#snapshot.page.rows == 1 and snapshot.page.rows[1].cells[2].text == "pending deleted")
  grid:next_page()
  assert(#requests == 5, "unmatched review rows advanced empty filtered results")
  grid:load(0, { filters = {} })
  requests[6].callback(nil, page({ row("one", "1"), row("two", "2"), row("three", "3") }, 0, 3))
  assert(#grid:snapshot().page.rows == 4, "unmatched review row disappeared on navigation")
  grid:next_page()
  assert(requests[7].params.offset == 3, "review rows changed the next page offset")
  assert(vim.deep_equal(requests[7].params.retain_handles, { "fresh_five", "other" }))
  requests[7].callback(nil, page({ row("new_five", "5") }, 3))
  assert(grid:snapshot().page.rows[1].handle == "fresh_five", "paging rebased the staged original")
  grid:previous_page()
  assert(requests[8].params.offset == 0, "review rows changed the previous page offset")
  requests[8].callback(nil, page({ row("one_again", "1") }, 0, 3))
  grid:discard("deleted", "value")
  grid:save()
  assert(requests[9].params.edits[1].handle == "fresh_five")
  grid:stage("fresh_five", "value", "newer five", false)
  requests[9].callback(nil, { rows = { row("fresh_five", "5") } })
  assert(grid:snapshot().pending_count == 1, "save erased a concurrent newer edit")
  grid:close(); other:close()
end

function tests.recovery_retry_restarts_from_the_visible_page()
  local client, requests = transport()
  local grid = sessions.new(client, relation, "paging")
  grid:load(3)
  requests[1].callback(nil, page({ row("old", "5") }, 3))
  grid:stage("old", "value", "keep", false)
  local failure
  grid:reload(function(err) failure = err end)
  requests[2].callback(nil, page({ row("first", "1") }, 0, 3))
  assert(requests[3].params.offset == 3, "retry setup skipped the hidden row page")
  requests[3].callback({ code = "database_error", message = "scan failed" })
  assert(failure.code == "database_error" and grid:snapshot().pending_count == 1)
  assert(grid:snapshot().page.rows[2].cells[2].text == "keep", "failed scan hid a pending row")
  grid:reload()
  assert(requests[4].params.offset == 0)
  requests[4].callback(nil, page({ row("retry_first", "1") }, 0, 3))
  assert(requests[5].params.offset == 3)
  requests[5].callback(nil, page({ row("recovered", "5") }, 3))
  assert(not grid:snapshot().error and grid:snapshot().pending_count == 1)
  assert(grid:snapshot().page.offset == 0 and grid:snapshot().page.next_offset == 3,
    "hidden recovery scan changed the visible page")
  grid:save()
  assert(requests[6].params.edits[1].handle == "recovered")
  requests[6].callback(nil, { rows = { row("recovered", "5") } })
  grid:close()
end

local failed = 0
for name, test in pairs(tests) do
  local ok, err = pcall(test)
  if not ok then failed = failed + 1; print(name .. ": " .. tostring(err)) end
end
assert(failed == 0, tostring(failed) .. " paging tests failed")
print("table paging tests passed")
