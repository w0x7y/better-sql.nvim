-- Owns cell geometry and interaction for result sets and table snapshots.
local M = {}
local display = require("better_sql.display")
local cell_view = require("better_sql.cell")

local function slice_width(value, left, width)
  local result, position = {}, 0
  for index = 0, vim.fn.strchars(value) - 1 do
    local character = vim.fn.strcharpart(value, index, 1)
    local size = vim.fn.strdisplaywidth(character)
    if position + size > left and position < left + width then result[#result + 1] = character end
    position = position + size
    if position >= left + width then break end
  end
  return table.concat(result)
end

local function fit(value, width)
  if vim.fn.strdisplaywidth(value) > width then
    local result, used = {}, 0
    for index = 0, vim.fn.strchars(value) - 1 do
      local character = vim.fn.strcharpart(value, index, 1)
      local size = vim.fn.strdisplaywidth(character)
      if used + size > width - 1 then break end
      result[#result + 1], used = character, used + size
    end
    value = table.concat(result) .. "…"
  end
  return value .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(value)))
end

function M.new(buf, options)
  options = options or {}
  local view = { columns = {}, rows = {}, row = 1, col = 1, positions = {}, data_start = 1 }

  local function window()
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == buf then return current end
    local visible = vim.fn.bufwinid(buf)
    if visible ~= -1 then return visible end
  end

  local function selected()
    local row, column = view.rows[view.row], view.columns[view.col]
    if row and column and row[view.col] then
      return { row_index = view.row, column_index = view.col, column_name = column.name, cell = row[view.col] }
    end
  end

  local function update_header(win)
    vim.wo[win].wrap = false
    vim.wo[win].sidescrolloff = 0
    if options.sticky_header and view.header then
      local left = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
      vim.wo[win].winbar = slice_width(view.header, left, vim.api.nvim_win_get_width(win)):gsub("%%", "%%%%")
    end
  end

  local function publish(selection)
    if options.on_select then options.on_select(selection) end
  end

  local function place(win, row, col)
    row, col = row or view.row, col or view.col
    local position = view.positions[row]
    if position and position[col] then
      vim.api.nvim_win_set_cursor(win, { view.data_start + row - 1, position[col].start })
    end
    update_header(win)
  end

  local function selection_at(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row = cursor[1] - view.data_start + 1
    local spans = view.positions[row]
    if not spans or not view.rows[row] then return end
    local nearest, distance = 1, math.huge
    for col, span in ipairs(spans) do
      local gap = math.max(span.start - cursor[2], cursor[2] - span.finish, 0)
      if gap < distance then nearest, distance = col, gap end
    end
    return { row_index = row, column_index = nearest }
  end

  function view:selection()
    if vim.api.nvim_get_current_buf() ~= buf then return end
    local selection = selection_at(0)
    if not selection then return end
    self.row, self.col = selection.row_index, selection.column_index
    return selected()
  end

  function view:column()
    self:selection()
    return self.columns[self.col]
  end

  function view:select(row, col)
    self.row = math.max(1, math.min(row, #self.rows))
    self.col = math.max(1, math.min(col, #self.columns))
    local win = window()
    if win then place(win) end
    publish(selected())
  end

  function view:render(columns, rows, settings)
    settings = settings or {}
    local windows, selections = vim.fn.win_findbuf(buf), {}
    for _, win in ipairs(windows) do selections[win] = selection_at(win) end
    self.columns, self.rows = columns, rows
    if settings.reset then self.row, self.col = 1, 1
    elseif settings.reset_row then self.row = 1 end
    local widths = {}
    for col, column in ipairs(columns) do
      widths[col] = math.max(options.min_width or 0, vim.fn.strdisplaywidth(display.line(column.name)))
      for _, row in ipairs(rows) do
        local value = display.cell(row[col].text, row[col].is_null)
        widths[col] = math.max(widths[col], (options.marker_padding or 0) + vim.fn.strdisplaywidth(value))
      end
      if options.max_width then widths[col] = math.min(widths[col], options.max_width) end
    end
    local function formatted(values)
      local fields, spans, offset = {}, {}, 0
      for col, value in ipairs(values) do
        fields[col] = fit(value, widths[col])
        spans[col] = { start = offset, finish = offset + #fields[col] - 1 }
        offset = offset + #fields[col] + 3
      end
      return table.concat(fields, " | "), spans
    end
    local headers = {}
    for col, column in ipairs(columns) do headers[col] = display.line(column.name) end
    self.header = formatted(headers)
    local lines = vim.list_extend({}, settings.prefix or {})
    if #columns > 0 or settings.separator then lines[#lines + 1] = self.header end
    if settings.separator then lines[#lines + 1] = string.rep("-", math.max(1, #self.header)) end
    self.data_start, self.positions = #lines + 1, {}
    for index, row in ipairs(rows) do
      local values = {}
      for col, column in ipairs(columns) do
        local dirty = settings.dirty and settings.dirty[index] and settings.dirty[index][column.name]
        values[col] = (dirty and "*" or "") .. display.cell(row[col].text, row[col].is_null)
      end
      local line, spans = formatted(values)
      lines[#lines + 1], self.positions[index] = line, spans
    end
    if #rows == 0 and settings.empty_text then lines[#lines + 1] = settings.empty_text end
    display.set_lines(buf, 0, -1, lines)
    self.row = math.max(1, math.min(self.row, #rows))
    self.col = math.max(1, math.min(self.col, #columns))
    for _, win in ipairs(windows) do
      local selection = selections[win]
      if settings.reset then vim.api.nvim_win_set_cursor(win, { 1, 0 }) end
      if selection and not settings.reset then
        place(win, settings.reset_row and 1 or math.max(1, math.min(selection.row_index, #rows)),
          math.max(1, math.min(selection.column_index, #columns)))
      else place(win) end
    end
    self:selection()
    publish(selected())
  end

  for key, delta in pairs({ h = { 0, -1 }, l = { 0, 1 }, j = { 1, 0 }, k = { -1, 0 } }) do
    vim.keymap.set("n", key, function()
      if #view.rows == 0 or #view.columns == 0 then return end
      local selection = view:selection()
      if selection then view:select(view.row + delta[1] * vim.v.count1, view.col + delta[2] * vim.v.count1)
      else view:select(1, 1) end
    end, { buffer = buf, desc = "Move between SQL cells" })
  end
  vim.keymap.set("n", "yc", function()
    local selection = view:selection()
    if selection then cell_view.copy(selection.cell, vim.v.register) end
  end, { buffer = buf, desc = "Copy raw SQL cell" })
  vim.keymap.set("n", "K", function()
    local selection = view:selection()
    if selection then view.detail_window = cell_view.show(selection.column_name, selection.cell, view.detail_window) end
  end, { buffer = buf, desc = "Show full SQL cell" })
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function()
    publish(view:selection())
    update_header(vim.api.nvim_get_current_win())
  end })
  local scroll = vim.api.nvim_create_autocmd("WinScrolled", { callback = function()
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do update_header(win) end
  end })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
    vim.api.nvim_del_autocmd(scroll)
    if view.detail_window and vim.api.nvim_win_is_valid(view.detail_window) then
      vim.api.nvim_win_close(view.detail_window, true)
    end
  end })
  return view
end

return M
