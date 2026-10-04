local M = {}
local display = require("better_sql.display")

function M.copy(cell, register)
  vim.fn.setreg(register or '"', cell.is_null and "NULL" or cell.text, "v")
end

function M.show(column, cell, previous_window)
  if previous_window and vim.api.nvim_win_is_valid(previous_window) then
    vim.api.nvim_win_close(previous_window, true)
  end
  local parent = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local value = cell.is_null and "NULL" or cell.text
  local lines = vim.split(display.line(column) .. ": " .. value, "\n", { plain = true })
  display.set_lines(buf, 0, -1, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win", win = parent, row = 1, col = 1,
    width = math.max(1, math.min(80, vim.api.nvim_win_get_width(parent) - 2)),
    height = math.max(1, math.min(12, #lines, vim.api.nvim_win_get_height(parent) - 2)),
    border = "single", style = "minimal",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end,
    { buffer = buf, desc = "Close cell detail" })
  return win
end

return M
