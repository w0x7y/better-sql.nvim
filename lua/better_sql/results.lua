local M = {}

local state

local function display(text, is_null)
  if is_null then
    return "NULL"
  end
  if text == "" then
    return '""'
  end
  return tostring(text):gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
end

local function render(set, index, count, profile)
  local lines = { string.format("%s  Result %d/%d", profile or "PostgreSQL", index, count) }
  lines[#lines + 1] = "Status: " .. (set.status or "")
  if set.truncated then
    lines[#lines + 1] = "Output truncated by the configured row or byte limit"
  end

  local columns = set.columns or {}
  if #columns > 0 then
    local widths = {}
    local rows = {}
    for col, column in ipairs(columns) do
      widths[col] = vim.fn.strdisplaywidth(column.name)
    end
    for _, row in ipairs(set.rows or {}) do
      local cells = {}
      for col, cell in ipairs(row) do
        cells[col] = display(cell.text, cell.is_null)
        widths[col] = math.max(widths[col], vim.fn.strdisplaywidth(cells[col]))
      end
      rows[#rows + 1] = cells
    end
    local function formatted(cells)
      local fields = {}
      for col, value in ipairs(cells) do
        fields[col] = value .. string.rep(" ", widths[col] - vim.fn.strdisplaywidth(value))
      end
      return table.concat(fields, " | ")
    end
    local headers = {}
    for _, column in ipairs(columns) do
      headers[#headers + 1] = column.name
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = formatted(headers)
    for _, cells in ipairs(rows) do
      lines[#lines + 1] = formatted(cells)
    end
  end
  return lines
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
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render(state.sets[index], index, #state.sets, state.profile))
  vim.bo[buf].modifiable = false
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
  vim.api.nvim_buf_set_name(buf, "better-sql://results/" .. buf)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.sidescrolloff = 0

  state = { buffer = buf, sets = sets, index = 1, profile = profile_name }
  M.current_buffer = buf
  M.select_set(1)
  vim.keymap.set("n", "]r", function() M.select_set(state.index + 1) end, { buffer = buf, desc = "Next SQL result set" })
  vim.keymap.set("n", "[r", function() M.select_set(state.index - 1) end, { buffer = buf, desc = "Previous SQL result set" })
  if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  return buf
end

function M.show_error(err, profile_name)
  local message = err.message or "Query failed"
  if err.sqlstate then
    message = message .. " [" .. err.sqlstate .. "]"
  end
  return M.show({ sets = { { columns = {}, rows = {}, status = "Error: " .. message } } }, profile_name)
end

return M
