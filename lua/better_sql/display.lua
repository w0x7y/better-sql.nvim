local M = {}

-- Keep every external label on one buffer line, just like cell values.
function M.line(value)
  return (tostring(value):gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t"))
end

function M.cell(text, is_null)
  if is_null then return "NULL" end
  if text == "" then return '""' end
  return M.line(text)
end

function M.set_lines(buf, first, last, lines)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, first, last, false, lines)
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = false end
  if not ok then error(err, 0) end
end

return M
