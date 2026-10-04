local M = {}
local display = require("better_sql.display")
local grid = require("better_sql.grid")

local state

local function current_view()
  if state and vim.api.nvim_get_current_buf() == state.buffer then return state end
end

function M.select_set(index)
  if not state or index < 1 or index > #state.sets then
    return
  end
  state.index = index
  local buf = state.buffer
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local set = state.sets[index]
  local prefix = { string.format("%s  Result %d/%d", display.line(state.profile or "PostgreSQL"), index, #state.sets),
    "Status: " .. display.line(set.status or "") }
  if set.truncated then prefix[#prefix + 1] = "Output truncated by the configured row or byte limit" end
  if #(set.columns or {}) > 0 then prefix[#prefix + 1] = "" end
  state.grid:render(set.columns or {}, set.rows or {}, { prefix = prefix, reset = true })
end

function M.show(result, profile_name)
  local sets = result.sets or {}
  if #sets == 0 then
    sets = { { columns = {}, rows = {}, status = "No result" } }
  end

  local old = state and state.buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "better_sql_results"
  vim.api.nvim_buf_set_name(buf, "better-sql://results/" .. buf)
  local old_window = old and vim.api.nvim_buf_is_valid(old) and vim.fn.bufwinid(old) or -1
  if old_window ~= -1 then
    vim.api.nvim_set_current_win(old_window)
  else
    vim.cmd("botright split")
  end
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.sidescrolloff = 0

  local view = { buffer = buf, sets = sets, index = 1, profile = profile_name }
  state = view
  M.current_buffer = buf
  view.grid = grid.new(buf)
  M.select_set(1)
  vim.keymap.set("n", "]r", function() M.select_set(view.index + 1) end, { buffer = buf, desc = "Next SQL result set" })
  vim.keymap.set("n", "[r", function() M.select_set(view.index - 1) end, { buffer = buf, desc = "Previous SQL result set" })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
    if state == view then state = nil end
  end })
  if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  return buf
end

function M.export_data()
  local view = current_view()
  if not view then return end
  local set = view.sets[view.index]
  if #(set.columns or {}) > 0 then return set.columns, set.rows or {} end
end

function M.show_error(err, profile_name)
  local message = err.message or "Query failed"
  if err.sqlstate then
    message = message .. " [" .. err.sqlstate .. "]"
  end
  local label = err.code == "cancelled" and "Cancelled: " or "Error: "
  return M.show({ sets = { { columns = {}, rows = {}, status = label .. message } } }, profile_name)
end

return M
