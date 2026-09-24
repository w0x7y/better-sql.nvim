local M = {}

local PAGE_SIZE = 100
local CELL_WIDTH = 24
local DATA_START = 6
local views = {}

local function cell_text(cell)
  if cell.is_null then return "NULL" end
  if cell.text == "" then return '""' end
  return tostring(cell.text):gsub("\\", "\\\\"):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
end

local function take_width(value, width)
  local result, used = {}, 0
  for index = 0, vim.fn.strchars(value) - 1 do
    local character = vim.fn.strcharpart(value, index, 1)
    local size = vim.fn.strdisplaywidth(character)
    if used + size > width then break end
    result[#result + 1] = character
    used = used + size
  end
  return table.concat(result), used
end

local function slice_width(value, left, width)
  local result, position = {}, 0
  for index = 0, vim.fn.strchars(value) - 1 do
    local character = vim.fn.strcharpart(value, index, 1)
    local size = vim.fn.strdisplaywidth(character)
    if position + size > left and position < left + width then
      result[#result + 1] = character
    end
    position = position + size
    if position >= left + width then break end
  end
  return table.concat(result)
end

local function fit(value, width)
  local display_width = vim.fn.strdisplaywidth(value)
  if display_width > width then
    local prefix = take_width(value, width - 1)
    value = prefix .. "…"
  end
  return value .. string.rep(" ", width - vim.fn.strdisplaywidth(value))
end

local function view_for_current_buffer()
  return views[vim.api.nvim_get_current_buf()]
end

local function selected_cell(state)
  local row = state.page and state.page.rows[state.selected_row]
  local column = state.page and state.page.columns[state.selected_col]
  if not row or not column then return nil end
  return {
    row_handle = row.handle,
    column_name = column.name,
    row_index = state.selected_row,
    cell = row.cells[state.selected_col],
  }
end

local function set_line(state, line_number, text)
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  local existing = vim.api.nvim_buf_get_lines(state.buf, line_number - 1, line_number, false)[1]
  if existing == text then return end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, line_number - 1, line_number, false, { text })
  vim.bo[state.buf].modifiable = false
end

local function update_detail(state)
  local selection = selected_cell(state)
  local detail = "Cell: no row selected"
  if selection then
    detail = "Cell: " .. selection.column_name .. " = " .. cell_text(selection.cell)
  end
  set_line(state, 3, detail)
end

local function update_header(state, win)
  if not state.header or not vim.api.nvim_win_is_valid(win) then return end
  local left = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
  local visible = slice_width(state.header, left, vim.api.nvim_win_get_width(win))
  vim.wo[win].winbar = visible:gsub("%%", "%%%%")
end

local function update_winbars(state)
  for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
    vim.wo[win].wrap = false
    vim.wo[win].sidescrolloff = 0
    update_header(state, win)
  end
end

local function move_to_cell(state, row, col)
  if not state.page or #state.page.rows == 0 then return end
  state.selected_row = math.max(1, math.min(row, #state.page.rows))
  state.selected_col = math.max(1, math.min(col, #state.page.columns))
  local span = state.positions[DATA_START + state.selected_row - 1][state.selected_col]
  local win = vim.fn.bufwinid(state.buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { DATA_START + state.selected_row - 1, span.start })
    update_header(state, win)
  end
  update_detail(state)
end

local function sync_cursor(state)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= state.buf then return end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local spans = state.positions[cursor[1]]
  if not spans then return end
  state.selected_row = cursor[1] - DATA_START + 1
  local nearest, distance = 1, math.huge
  for col, span in ipairs(spans) do
    local gap = math.max(span.start - cursor[2], cursor[2] - span.finish, 0)
    if gap < distance then nearest, distance = col, gap end
  end
  state.selected_col = nearest
  update_detail(state)
  update_header(state, win)
end

local function show_detail(state)
  local selection = selected_cell(state)
  if not selection then return end
  local parent = vim.api.nvim_get_current_win()
  if state.detail_window and vim.api.nvim_win_is_valid(state.detail_window) then
    vim.api.nvim_win_close(state.detail_window, true)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    { selection.column_name .. ": " .. cell_text(selection.cell) })
  vim.bo[buf].modifiable = false
  local width = math.max(1, math.min(80, vim.api.nvim_win_get_width(parent) - 2))
  local height = math.max(1, math.min(8, vim.api.nvim_win_get_height(parent) - 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win", win = parent, row = 1, col = 1,
    width = width, height = height, border = "single", style = "minimal",
  })
  state.detail_window = win
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end,
    { buffer = buf, desc = "Close cell detail" })
end

local function write_page(state)
  local page = state.page
  local lines = {}
  local relation = state.relation
  local name = relation and (relation.schema .. "." .. relation.name) or "Preview"
  lines[1] = "Profile: " .. (state.profile or "PostgreSQL") .. "  Relation: " .. name
  if state.loading then
    lines[2] = "Loading rows..."
  elseif state.error then
    lines[2] = "Error: " .. state.error
  else
    local first = #page.rows > 0 and page.offset + 1 or 0
    local last = page.offset + #page.rows
    lines[2] = string.format("Rows %d-%d%s", first, last, page.has_more and "  More available" or "")
    if not page.editable then
      lines[2] = lines[2] .. "  Read-only: " .. (page.read_only_reason or "Relation is read-only")
    end
  end
  lines[3] = "Cell: no row selected"

  local widths = {}
  for col, column in ipairs(page.columns or {}) do
    widths[col] = math.min(CELL_WIDTH, math.max(4, vim.fn.strdisplaywidth(column.name)))
    for _, row in ipairs(page.rows or {}) do
      widths[col] = math.min(CELL_WIDTH, math.max(widths[col], vim.fn.strdisplaywidth(cell_text(row.cells[col]))))
    end
  end
  local function make_line(values, row_handle)
    local fields, spans, offset = {}, {}, 0
    for col, value in ipairs(values) do
      local field = fit(value, widths[col])
      fields[col] = field
      spans[col] = {
        start = offset, finish = offset + #field - 1,
        row_handle = row_handle, column_name = page.columns[col].name,
      }
      offset = offset + #field + 3
    end
    return table.concat(fields, " | "), spans
  end
  local headers = {}
  for _, column in ipairs(page.columns or {}) do headers[#headers + 1] = column.name end
  state.header = make_line(headers)
  lines[4] = state.header
  lines[5] = string.rep("-", math.max(1, #state.header))
  state.positions = {}
  for index, row in ipairs(page.rows or {}) do
    local values = {}
    for col, cell in ipairs(row.cells) do values[col] = cell_text(cell) end
    local line, spans = make_line(values, row.handle)
    lines[DATA_START + index - 1] = line
    state.positions[DATA_START + index - 1] = spans
  end
  if #page.rows == 0 then lines[DATA_START] = "(no rows)" end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  update_winbars(state)
  if #page.rows > 0 and #page.columns > 0 then
    move_to_cell(state, state.selected_row, state.selected_col)
  end
end

local function request_page(state, offset)
  if state.loading or not state.client then return end
  state.loading = true
  state.error = nil
  write_page(state)
  local retain_handles = vim.tbl_keys(state.pending or {})
  table.sort(retain_handles)
  state.client:request("table.page", {
    schema = state.relation.schema,
    table = state.relation.name,
    offset = offset,
    retain_handles = retain_handles,
  }, function(err, page)
    if not vim.api.nvim_buf_is_valid(state.buf) or views[state.buf] ~= state then return end
    state.loading = false
    if err then
      state.error = err.message or err.code or "Page request failed"
    else
      state.page = page
      state.error = nil
    end
    write_page(state)
  end)
end

local function create_view(client, relation, profile)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "better_sql_table"
  vim.api.nvim_buf_set_name(buf, "better-sql://table/" .. buf)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  local state = {
    buf = buf, client = client, relation = relation, profile = profile,
    page = { columns = relation and relation.columns or {}, rows = {}, offset = 0,
      has_more = false, editable = true },
    selected_row = 1, selected_col = 1, positions = {}, pending = {},
  }
  views[buf] = state
  M.current_buffer = buf
  vim.keymap.set("n", "h", function() sync_cursor(state); move_to_cell(state, state.selected_row, state.selected_col - 1) end,
    { buffer = buf, desc = "Previous table cell" })
  vim.keymap.set("n", "l", function() sync_cursor(state); move_to_cell(state, state.selected_row, state.selected_col + 1) end,
    { buffer = buf, desc = "Next table cell" })
  vim.keymap.set("n", "j", function() sync_cursor(state); move_to_cell(state, state.selected_row + 1, state.selected_col) end,
    { buffer = buf, desc = "Next table row" })
  vim.keymap.set("n", "k", function() sync_cursor(state); move_to_cell(state, state.selected_row - 1, state.selected_col) end,
    { buffer = buf, desc = "Previous table row" })
  vim.keymap.set("n", "]p", function() M.next_page() end, { buffer = buf, desc = "Next table page" })
  vim.keymap.set("n", "[p", function() M.previous_page() end, { buffer = buf, desc = "Previous table page" })
  vim.keymap.set("n", "K", function() sync_cursor(state); show_detail(state) end,
    { buffer = buf, desc = "Show full table cell" })
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function() sync_cursor(state) end })
  state.scroll_autocmd = vim.api.nvim_create_autocmd("WinScrolled", { callback = function()
    if vim.api.nvim_buf_is_valid(buf) then update_winbars(state) end
  end })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
    vim.api.nvim_del_autocmd(state.scroll_autocmd)
    views[buf] = nil
    if M.current_buffer == buf then M.current_buffer = nil end
  end })
  return state
end

function M.render(page)
  local state = create_view(nil, nil, nil)
  state.page = page
  write_page(state)
  return state.buf
end

function M.open(client, relation, profile_name)
  local state = create_view(client, relation, profile_name)
  write_page(state)
  request_page(state, 0)
  return state.buf
end

function M.next_page()
  local state = view_for_current_buffer()
  if state and state.page.has_more then request_page(state, state.page.offset + PAGE_SIZE) end
end

function M.previous_page()
  local state = view_for_current_buffer()
  if state and state.page.offset > 0 then request_page(state, math.max(0, state.page.offset - PAGE_SIZE)) end
end

function M.current_cell()
  local state = view_for_current_buffer()
  return state and selected_cell(state) or nil
end

return M
