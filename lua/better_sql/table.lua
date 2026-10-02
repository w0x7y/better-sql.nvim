local M = {}
local display = require("better_sql.display")
local table_session = require("better_sql.table_session")
local table_controls = require("better_sql.table_controls")

local PAGE_SIZE = 100
local CELL_WIDTH = 24
local DATA_START = 6
local views = {}

local function cell_text(cell)
  return display.cell(cell.text, cell.is_null)
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
  display.set_lines(state.buf, line_number - 1, line_number, { text })
end

local function update_detail(state)
  local selection = selected_cell(state)
  local detail = "Cell: no row selected"
  if selection then
    detail = "Cell: " .. display.line(selection.column_name) .. " = " .. cell_text(selection.cell)
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
  if not state.page or #state.page.rows == 0 or #state.page.columns == 0 then return end
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
  display.set_lines(buf, 0, -1,
    { display.line(selection.column_name) .. ": " .. cell_text(selection.cell) })
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
  lines[1] = "Profile: " .. display.line(state.profile or "PostgreSQL") .. "  Relation: " .. display.line(name)
    .. "  " .. table_controls.describe(state.filters, state.sort)
  if state.loading then
    lines[2] = "Loading rows..."
  elseif state.error then
    lines[2] = "Error: " .. display.line(state.error)
  else
    local first = #page.rows > 0 and page.offset + 1 or 0
    local last = page.offset + #page.rows
    lines[2] = string.format("Rows %d-%d%s", first, last, page.has_more and "  More available" or "")
    if not page.editable then
      lines[2] = lines[2] .. "  Read-only: " .. display.line(page.read_only_reason or "Relation is read-only")
    end
  end
  lines[2] = lines[2] .. "  Pending: " .. state.pending_count
  if state.needs_reload then lines[2] = lines[2] .. "  Reconnect and press r to reload and review edits" end
  if state.saving then lines[2] = lines[2] .. "  Saving..." end
  lines[3] = "Cell: no row selected"

  local widths = {}
  for col, column in ipairs(page.columns or {}) do
    widths[col] = math.min(CELL_WIDTH, math.max(4, vim.fn.strdisplaywidth(display.line(column.name))))
    for _, row in ipairs(page.rows or {}) do
      widths[col] = math.min(CELL_WIDTH, math.max(widths[col], 1 + vim.fn.strdisplaywidth(cell_text(row.cells[col]))))
    end
  end
  local function make_line(values)
    local fields, spans, offset = {}, {}, 0
    for col, value in ipairs(values) do
      local field = fit(value, widths[col])
      fields[col] = field
      spans[col] = {
        start = offset, finish = offset + #field - 1,
      }
      offset = offset + #field + 3
    end
    return table.concat(fields, " | "), spans
  end
  local headers = {}
  for _, column in ipairs(page.columns or {}) do headers[#headers + 1] = display.line(column.name) end
  state.header = make_line(headers)
  lines[4] = state.header
  lines[5] = string.rep("-", math.max(1, #state.header))
  state.positions = {}
  for index, row in ipairs(page.rows or {}) do
    local values = {}
    for col in ipairs(row.cells) do
      local dirty = row.dirty[page.columns[col].name]
      values[col] = (dirty and "*" or "") .. cell_text(row.cells[col])
    end
    local line, spans = make_line(values)
    lines[DATA_START + index - 1] = line
    state.positions[DATA_START + index - 1] = spans
  end
  if #page.rows == 0 then lines[DATA_START] = "(no rows)" end
  display.set_lines(state.buf, 0, -1, lines)
  update_winbars(state)
  if #page.rows > 0 and #page.columns > 0 then
    move_to_cell(state, state.selected_row, state.selected_col)
  end
end

local function warn_read_only(reason)
  if reason then
    local message = type(reason) == "table" and reason.message or reason
    vim.notify("Read-only: " .. message, vim.log.levels.WARN)
  end
end

local function edit_cell(state, null)
  sync_cursor(state)
  local selection = selected_cell(state)
  if not selection then return end
  local reason = state.session:editable(selection.row_handle, selection.column_name)
  if reason then warn_read_only(reason); return end
  if null then
    warn_read_only(state.session:stage(selection.row_handle, selection.column_name, "", true))
    return
  end
  local is_current = state.session:guard()
  vim.ui.input({ prompt = display.line(selection.column_name) .. ": ", default = selection.cell.text }, function(text)
    if text ~= nil and is_current() then
      warn_read_only(state.session:stage(selection.row_handle, selection.column_name, text, false))
    end
  end)
end

local function create_view(client, relation, profile, preview)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "better_sql_table"
  vim.api.nvim_buf_set_name(buf, "better-sql://table/" .. buf)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  local state = { buf = buf, selected_row = 1, selected_col = 1, positions = {} }
  local function present(snapshot, reset_selection)
    for key, value in pairs(snapshot) do state[key] = value end
    -- Optional fields also need clearing when a new snapshot omits them.
    state.sort, state.error, state.loading, state.saving, state.needs_reload =
      snapshot.sort, snapshot.error, snapshot.loading, snapshot.saving, snapshot.needs_reload
    if reset_selection then state.selected_row = 1 end
    write_page(state)
  end
  state.session = table_session.new(client, relation, profile, present, preview)
  local snapshot = state.session:snapshot()
  for key, value in pairs(snapshot) do state[key] = value end
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
  vim.keymap.set("n", "e", function() edit_cell(state, false) end, { buffer = buf, desc = "Edit table cell" })
  vim.keymap.set("n", "N", function() edit_cell(state, true) end, { buffer = buf, desc = "Set cell to SQL NULL" })
  vim.keymap.set("n", "u", function()
    sync_cursor(state)
    local selection = selected_cell(state)
    if selection then M.discard(selection.row_handle, selection.column_name) end
  end, { buffer = buf, desc = "Discard cell edit" })
  vim.keymap.set("n", "s", function() state.session:save() end, { buffer = buf, desc = "Save pending table edits" })
  vim.keymap.set("n", "r", function() M.reload() end, { buffer = buf, desc = "Reload and review staged edits" })
  vim.keymap.set("n", "f", function() M.filter() end, { buffer = buf, desc = "Filter selected column" })
  vim.keymap.set("n", "F", function() M.clear_filters() end, { buffer = buf, desc = "Clear table filters" })
  vim.keymap.set("n", "o", function() M.sort() end, { buffer = buf, desc = "Sort selected column" })
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
    state.session:close()
    if M.current_buffer == buf then M.current_buffer = nil end
  end })
  return state
end

function M.render(page)
  local state = create_view(nil, nil, nil, page)
  write_page(state)
  return state.buf
end

function M.open(client, relation, profile_name)
  local state = create_view(client, relation, profile_name)
  write_page(state)
  state.session:load(0)
  return state.buf
end

function M.next_page()
  local state = view_for_current_buffer()
  if state and state.page.has_more then state.session:load(state.page.offset + PAGE_SIZE) end
end

function M.previous_page()
  local state = view_for_current_buffer()
  if state and state.page.offset > 0 then state.session:load(math.max(0, state.page.offset - PAGE_SIZE)) end
end

local function browse_context()
  local state = view_for_current_buffer()
  if not state then return end
  local allowed, reason = state.session:can_browse()
  if not allowed then
    if reason then vim.notify(reason, vim.log.levels.WARN) end
    return
  end
  sync_cursor(state)
  return state, state.session:guard()
end

function M.filter()
  local state, is_current = browse_context()
  if not state then return end
  local column = state.page.columns[state.selected_col]
  if not column then return end
  table_controls.filter(column.name, state.filters, is_current, function(filters)
    state.session:load(0, { filters = filters, sort = state.sort })
  end)
end

function M.sort()
  local state, is_current = browse_context()
  if not state then return end
  local column = state.page.columns[state.selected_col]
  if not column then return end
  table_controls.sort(column.name, is_current, function(sort)
    state.session:load(0, { filters = state.filters, sort = sort })
  end)
end

function M.clear_filters()
  local state = browse_context()
  if state then state.session:load(0, { filters = {}, sort = state.sort }) end
end

function M.current_cell()
  local state = view_for_current_buffer()
  return state and selected_cell(state) or nil
end

function M.stage(handle, column, text, is_null)
  local state = view_for_current_buffer()
  if state then warn_read_only(state.session:stage(handle, column, text, is_null)) end
end

function M.discard(handle, column)
  local state = view_for_current_buffer()
  if state then state.session:discard(handle, column) end
end

function M.pending_count()
  local state = view_for_current_buffer()
  return state and state.pending_count or 0
end

function M.save(callback)
  local state = view_for_current_buffer()
  if state then state.session:save(callback)
  elseif callback then callback({ code = "no_table", message = "Select a table grid first" }) end
end

function M.reload()
  local state = view_for_current_buffer()
  if state then state.session:reload() end
end

function M.disconnect(client) table_session.disconnect(client) end
function M.set_connection(client, profile) table_session.set_connection(client, profile) end

function M.before_switch(callback)
  table_session.before_switch(function(resolve)
    vim.ui.select({ "Save", "Discard", "Stay" }, { prompt = "Pending table edits before switching profiles:" }, resolve)
  end, callback)
end

return M
