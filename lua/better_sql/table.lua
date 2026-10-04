local M = {}
local display = require("better_sql.display")
local table_session = require("better_sql.table_session")
local table_controls = require("better_sql.table_controls")
local grid = require("better_sql.grid")

local views = {}

local function cell_text(cell)
  return display.cell(cell.text, cell.is_null)
end

local function view_for_current_buffer()
  return views[vim.api.nvim_get_current_buf()]
end

local function selected_cell(state)
  local selection = state.grid:selection()
  if not selection then return end
  selection.row_handle = state.page.rows[selection.row_index].handle
  return selection
end

local function set_line(state, line_number, text)
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  local existing = vim.api.nvim_buf_get_lines(state.buf, line_number - 1, line_number, false)[1]
  if existing == text then return end
  display.set_lines(state.buf, line_number - 1, line_number, { text })
end

local function update_detail(state, selection)
  local detail = "Cell: no row selected"
  if selection then
    detail = "Cell: " .. display.line(selection.column_name) .. " = " .. cell_text(selection.cell)
  end
  set_line(state, 3, detail)
end

local function write_page(state, reset_row)
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

  local rows, dirty = {}, {}
  for index, row in ipairs(page.rows) do rows[index], dirty[index] = row.cells, row.dirty end
  state.grid:render(page.columns, rows, {
    prefix = lines, dirty = dirty, separator = true, empty_text = "(no rows)", reset_row = reset_row,
  })
end

local function warn_read_only(reason)
  if reason then
    local message = type(reason) == "table" and reason.message or reason
    vim.notify("Read-only: " .. message, vim.log.levels.WARN)
  end
end

local function edit_cell(state, null)
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
  local state = { buf = buf }
  state.grid = grid.new(buf, { max_width = 24, min_width = 4, marker_padding = 1, sticky_header = true,
    on_select = function(selection) update_detail(state, selection) end })
  local function present(snapshot, reset_selection)
    for key, value in pairs(snapshot) do state[key] = value end
    -- Optional fields also need clearing when a new snapshot omits them.
    state.sort, state.error, state.loading, state.saving, state.needs_reload =
      snapshot.sort, snapshot.error, snapshot.loading, snapshot.saving, snapshot.needs_reload
    write_page(state, reset_selection)
  end
  state.session = table_session.new(client, relation, profile, present, preview)
  local snapshot = state.session:snapshot()
  for key, value in pairs(snapshot) do state[key] = value end
  views[buf] = state
  M.current_buffer = buf
  vim.keymap.set("n", "e", function() edit_cell(state, false) end, { buffer = buf, desc = "Edit table cell" })
  vim.keymap.set("n", "N", function() edit_cell(state, true) end, { buffer = buf, desc = "Set cell to SQL NULL" })
  vim.keymap.set("n", "u", function()
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
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
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
  if state then state.session:next_page() end
end

function M.previous_page()
  local state = view_for_current_buffer()
  if state then state.session:previous_page() end
end

local function browse_context()
  local state = view_for_current_buffer()
  if not state then return end
  local allowed, reason = state.session:can_browse()
  if not allowed then
    if reason then vim.notify(reason, vim.log.levels.WARN) end
    return
  end
  return state, state.session:guard()
end

function M.filter()
  local state, is_current = browse_context()
  if not state then return end
  local column = state.grid:column()
  if not column then return end
  table_controls.filter(column.name, state.filters, is_current, function(filters)
    state.session:load(0, { filters = filters, sort = state.sort })
  end)
end

function M.sort()
  local state, is_current = browse_context()
  if not state then return end
  local column = state.grid:column()
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

function M.export_data()
  local state = view_for_current_buffer()
  if not state or #state.page.columns == 0 then return end
  local rows = {}
  for _, row in ipairs(state.page.rows) do rows[#rows + 1] = row.cells end
  return state.page.columns, rows
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

return M
