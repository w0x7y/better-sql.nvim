local M = {}

local function quoted(value)
  return '"' .. value:gsub('"', '""') .. '"'
end

-- Quote every non-null value. An unquoted empty field denotes SQL NULL,
-- while a quoted empty field denotes an empty string, as in PostgreSQL COPY.
function M.encode(columns, rows)
  local lines, headers = {}, {}
  for _, column in ipairs(columns) do headers[#headers + 1] = quoted(column.name) end
  lines[1] = table.concat(headers, ",")
  for _, row in ipairs(rows) do
    local fields = {}
    for col in ipairs(columns) do
      local cell = row[col]
      fields[col] = cell.is_null and "" or quoted(cell.text)
    end
    lines[#lines + 1] = table.concat(fields, ",")
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

function M.write(path, columns, rows, overwrite)
  -- Serialize before opening, so invalid data cannot truncate an existing file.
  local data = M.encode(columns, rows)
  local fd, err = vim.uv.fs_open(path, overwrite and "w" or "wx", 420)
  if not fd then return err end
  local offset = 0
  while offset < #data do
    local written
    written, err = vim.uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written == 0 then break end
    offset = offset + written
  end
  local closed, close_error = vim.uv.fs_close(fd)
  if offset < #data then return err or "Could not write the complete CSV file" end
  if not closed then return close_error end
end

return M
