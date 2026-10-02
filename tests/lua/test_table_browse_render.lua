vim.opt.runtimepath:append(vim.fn.getcwd())
local grid = require("better_sql.table")
local display = require("better_sql.display")
local columns = { { name = "id", editable = false }, { name = "value", editable = true } }
local function row(handle, value)
  return { handle = handle, key = { { text = "1", is_null = false } }, cells = {
    { text = "1", is_null = false }, { text = value, is_null = false },
  } }
end
local function page(value)
  return { columns = columns, rows = { value }, offset = 0, has_more = false, editable = true }
end
local real_set_lines = display.set_lines

for _, phase in ipairs({ "start", "finish", "database" }) do
  local requests = {}
  local client = { request = function(_, method, params, callback)
    requests[#requests + 1] = { method = method, params = params, callback = callback }
  end }
  local buf = grid.open(client, { schema = "public", name = "items", columns = columns, primary_key = { "id" } }, "test")
  requests[#requests].callback(nil, page(row("original", "old")))
  vim.ui.select = function(_, _, callback) callback("Ascending") end
  grid.sort()
  requests[#requests].callback(nil, page(row("sorted", "old")))
  grid.stage("sorted", "value", "saved", false)
  local calls, save_error, saved_result = 0
  grid.save(function(err, result) calls, save_error, saved_result = calls + 1, err, result end)
  local save_reply = requests[#requests]
  local saved = { rows = { row("sorted", "saved") } }
  if phase ~= "start" then save_reply.callback(nil, saved) end
  if phase ~= "database" then display.set_lines = function() error("test render failure") end end
  local ok, failure = pcall(function()
    if phase == "start" then save_reply.callback(nil, saved)
    elseif phase == "database" then requests[#requests].callback({ code = "database_error", message = "permission denied" })
    else requests[#requests].callback(nil, page(row("refreshed", "saved"))) end
  end)
  display.set_lines = real_set_lines
  assert(ok, "refresh renderer escaped its callback: " .. tostring(failure))
  assert(calls == 1, "render failure lost or repeated the save callback")
  assert(save_error and save_error.code == "refresh_failed", "refresh failure was reported as a successful refresh")
  assert(save_error.message:find("saved", 1, true), "error did not explain that database edits committed")
  assert(saved_result == saved and grid.pending_count() == 0)
  if phase == "database" then
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(content:find("edits saved", 1, true), "grid did not distinguish a committed save from a failed refresh")
  end
  local previous = #requests
  grid.reload()
  assert(#requests == previous + 1, "render failure stalled the page queue")
  requests[#requests].callback(nil, page(row("reloaded", "saved")))
  assert(grid.current_cell().row_handle == "reloaded")
  assert(calls == 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end
print("table refresh rendering recovery tests passed")
