local M = {}
local display = require("better_sql.display")
local table_pages = require("better_sql.table_pages")

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

local function pending_count(state)
  local count = 0
  for _, changes in pairs(state.pending) do count = count + vim.tbl_count(changes) end
  return count
end

local function displayed_cell(state, row, col)
  local changes = state.pending[row.handle]
  return changes and changes[state.page.columns[col].name] or row.cells[col]
end

local function selected_cell(state)
  local row = state.page and state.page.rows[state.selected_row]
  local column = state.page and state.page.columns[state.selected_col]
  if not row or not column then return nil end
  return {
    row_handle = row.handle,
    column_name = column.name,
    row_index = state.selected_row,
    cell = displayed_cell(state, row, state.selected_col),
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
  lines[2] = lines[2] .. "  Pending: " .. pending_count(state)
  if state.needs_reload then lines[2] = lines[2] .. "  Reconnect and press r to reload and review edits" end
  if state.saving then lines[2] = lines[2] .. "  Saving..." end
  lines[3] = "Cell: no row selected"

  local widths = {}
  for col, column in ipairs(page.columns or {}) do
    widths[col] = math.min(CELL_WIDTH, math.max(4, vim.fn.strdisplaywidth(display.line(column.name))))
    for _, row in ipairs(page.rows or {}) do
      widths[col] = math.min(CELL_WIDTH, math.max(widths[col], 1 + vim.fn.strdisplaywidth(cell_text(displayed_cell(state, row, col)))))
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
  for _, column in ipairs(page.columns or {}) do headers[#headers + 1] = display.line(column.name) end
  state.header = make_line(headers)
  lines[4] = state.header
  lines[5] = string.rep("-", math.max(1, #state.header))
  state.positions = {}
  for index, row in ipairs(page.rows or {}) do
    local values = {}
    for col in ipairs(row.cells) do
      local dirty = state.pending[row.handle] and state.pending[row.handle][page.columns[col].name]
      values[col] = (dirty and "*" or "") .. cell_text(displayed_cell(state, row, col))
    end
    local line, spans = make_line(values, row.handle)
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

local function retained_handles(state)
  local handles = {}
  for _, view in pairs(views) do
    if view.client == state.client and not view.needs_reload then
      for handle in pairs(view.pending) do
        if not view.stale[handle] then handles[handle] = true end
      end
      -- A helper serves all grids. Keep other visible rows usable as well.
      if view ~= state or state.recovering then
        for _, row in ipairs(view.page.rows) do
          if type(row.handle) == "string" and not view.stale[row.handle] then handles[row.handle] = true end
        end
      end
    end
  end
  local result = vim.tbl_keys(handles)
  table.sort(result)
  return result
end

local function accept_rows(state, page)
  for index, row in ipairs(page.rows) do
    for handle in pairs(state.pending) do
      if vim.deep_equal(state.keys[handle], row.key) then
        if state.stale[handle] then
          state.pending[row.handle] = state.pending[handle]
          state.keys[row.handle] = row.key
          state.pending[handle], state.keys[handle], state.stale[handle] = nil, nil, nil
          state.loaded_rows[handle] = nil
        else
          -- Keep the original version until an explicit reload or successful save.
          row = state.loaded_rows[handle]
          page.rows[index] = row
        end
        break
      end
    end
    if type(row.handle) == "string" then state.loaded_rows[row.handle] = row end
  end
end

local function show_unmatched_rows(state)
  local visible = {}
  for _, row in ipairs(state.page.rows) do
    if type(row.handle) == "string" then visible[row.handle] = true end
  end
  local handles = vim.tbl_keys(state.stale)
  table.sort(handles)
  for _, handle in ipairs(handles) do
    if not visible[handle] and state.loaded_rows[handle] then
      state.page.rows[#state.page.rows + 1] = state.loaded_rows[handle]
    end
  end
end

local function request_page(state, offset)
  if state.loading or state.saving or not state.client or state.needs_reload then return end
  state.loading = true
  state.generation = state.generation + 1
  state.error = nil
  write_page(state)
  local client = state.client
  local generation = state.generation
  local function fetch(next_offset)
    table_pages.request(client, function()
      if views[state.buf] ~= state or state.client ~= client or state.generation ~= generation then return nil end
      return {
        schema = state.relation.schema, table = state.relation.name,
        offset = next_offset, retain_handles = retained_handles(state),
      }
    end, function(err, page)
      if views[state.buf] ~= state or state.client ~= client or state.generation ~= generation then return end
      if err then
        state.error = err.message or err.code or "Page request failed"
      else
        accept_rows(state, page)
        if not state.recovering or next_offset == offset then state.page = page end
        if state.recovering and next(state.stale) and page.has_more then
          fetch(next_offset + PAGE_SIZE)
          return
        end
        state.error = nil
        if next(state.stale) then
          state.error = "Unmatched rows after reload; review and discard their pending cells with u"
          show_unmatched_rows(state)
        end
      end
      if err then show_unmatched_rows(state) end
      state.loading, state.recovering = false, false
      local visible = {}
      for _, row in ipairs(state.page.rows) do
        if type(row.handle) == "string" then visible[row.handle] = true end
      end
      for handle in pairs(state.loaded_rows) do
        if not state.pending[handle] and not visible[handle] then state.loaded_rows[handle] = nil end
      end
      write_page(state)
    end)
  end
  fetch(offset)
end

local function blocked_reason(state, handle, column_name)
  if state.loading then return "Wait for rows to load before editing" end
  if state.needs_reload or state.stale[handle] then return "Reload and review this row before editing" end
  if not state.page.editable then return state.page.read_only_reason or "Relation is read-only" end
  for _, column in ipairs(state.page.columns) do
    if column.name == column_name then
      if not column.editable then return column.read_only_reason or "Column is read-only" end
      return nil
    end
  end
  return "Unknown column"
end

local function stage(state, handle, column, text, is_null)
  local reason = blocked_reason(state, handle, column)
  if reason then vim.notify("Read-only: " .. reason, vim.log.levels.WARN); return end
  local row = state.loaded_rows[handle]
  if not row then return end
  state.pending[handle] = state.pending[handle] or {}
  state.keys[handle] = vim.deepcopy(row.key)
  state.pending[handle][column] = { text = text, is_null = is_null }
  write_page(state)
end

local function edit_cell(state, null)
  sync_cursor(state)
  local selection = selected_cell(state)
  if not selection then return end
  local reason = blocked_reason(state, selection.row_handle, selection.column_name)
  if reason then vim.notify("Read-only: " .. reason, vim.log.levels.WARN); return end
  if null then stage(state, selection.row_handle, selection.column_name, "", true); return end
  local generation = state.generation
  vim.ui.input({ prompt = display.line(selection.column_name) .. ": ", default = selection.cell.text }, function(text)
    if text ~= nil and views[state.buf] == state and state.generation == generation then
      stage(state, selection.row_handle, selection.column_name, text, false)
    end
  end)
end

local function save(state, callback)
  callback = callback or function() end
  local function finish(err, result)
    local ok, render_error = pcall(write_page, state)
    if not ok and not err then err = { code = "render_error", message = tostring(render_error) } end
    callback(err, result)
  end
  local function failure(code, message)
    local err = { code = code, message = message }
    state.error = message
    finish(err)
  end
  if state.loading or state.saving then failure("busy", "Wait for the current table operation"); return end
  if not state.client or state.needs_reload or next(state.stale) then
    failure("reload_required", "Reload and review pending rows before saving; discard unmatched cells with u")
    return
  end
  if not next(state.pending) then callback(nil, { rows = {} }); return end
  local snapshot = {}
  local edits = {}
  local handles = vim.tbl_keys(state.pending)
  table.sort(handles)
  for _, handle in ipairs(handles) do
    snapshot[handle] = {}
    local changes = {}
    local columns = vim.tbl_keys(state.pending[handle])
    table.sort(columns)
    for _, column in ipairs(columns) do
      local value = state.pending[handle][column]
      snapshot[handle][column] = value
      changes[#changes + 1] = { column = column, text = value.text, is_null = value.is_null }
    end
    edits[#edits + 1] = { handle = handle, changes = changes }
  end
  state.saving, state.error = true, nil
  local ok, render_error = pcall(write_page, state)
  if not ok then
    state.saving = false
    callback({ code = "render_error", message = tostring(render_error) })
    return
  end
  local client, generation = state.client, state.generation
  client:request("table.save", { schema = state.relation.schema, table = state.relation.name, edits = edits }, function(err, result)
    if views[state.buf] ~= state or state.client ~= client or state.generation ~= generation then
      callback({ code = "connection_changed", message = "Connection changed during save; reload and review edits" })
      return
    end
    state.saving = false
    if err then
      local details = err.message or err.code or "Save failed"
      if type(err.handle) == "string" then
        local values = {}
        for _, value in ipairs(state.keys[err.handle] or {}) do values[#values + 1] = cell_text(value) end
        details = details .. "  Row: [" .. table.concat(values, ", ") .. "]"
      end
      if type(err.column) == "string" then
        details = details .. "  Column: " .. err.column
      elseif type(err.columns) == "table" and #err.columns > 0 then
        details = details .. "  Columns: " .. table.concat(err.columns, ", ")
      end
      if type(err.sqlstate) == "string" then details = details .. "  SQLSTATE: " .. err.sqlstate end
      state.error = details
    else
      for _, row in ipairs(result.rows) do
        state.loaded_rows[row.handle] = row
        for index, current in ipairs(state.page.rows) do
          if current.handle == row.handle then state.page.rows[index] = row end
        end
        for column, value in pairs(snapshot[row.handle] or {}) do
          if state.pending[row.handle] and state.pending[row.handle][column] == value then
            state.pending[row.handle][column] = nil
          end
        end
        if state.pending[row.handle] and not next(state.pending[row.handle]) then
          state.pending[row.handle], state.keys[row.handle] = nil, nil
        end
      end
      state.error = nil
    end
    finish(err, result)
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
    loaded_rows = {}, keys = {}, stale = {}, generation = 0,
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
  vim.keymap.set("n", "e", function() edit_cell(state, false) end, { buffer = buf, desc = "Edit table cell" })
  vim.keymap.set("n", "N", function() edit_cell(state, true) end, { buffer = buf, desc = "Set cell to SQL NULL" })
  vim.keymap.set("n", "u", function()
    sync_cursor(state)
    local selection = selected_cell(state)
    if selection then M.discard(selection.row_handle, selection.column_name) end
  end, { buffer = buf, desc = "Discard cell edit" })
  vim.keymap.set("n", "s", function() save(state) end, { buffer = buf, desc = "Save pending table edits" })
  vim.keymap.set("n", "r", function() M.reload() end, { buffer = buf, desc = "Reload and review staged edits" })
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
  accept_rows(state, page)
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

function M.stage(handle, column, text, is_null)
  local state = view_for_current_buffer()
  if state then stage(state, handle, column, text, is_null) end
end

function M.discard(handle, column)
  local state = view_for_current_buffer()
  if not state or not state.pending[handle] then return end
  state.pending[handle][column] = nil
  if not next(state.pending[handle]) then
    state.pending[handle], state.keys[handle] = nil, nil
    if state.stale[handle] then
      state.stale[handle] = nil
      for index, row in ipairs(state.page.rows) do
        if row.handle == handle then table.remove(state.page.rows, index); break end
      end
    end
  end
  write_page(state)
end

function M.pending_count()
  local state = view_for_current_buffer()
  return state and pending_count(state) or 0
end

function M.save(callback)
  local state = view_for_current_buffer()
  if state then save(state, callback)
  elseif callback then callback({ code = "no_table", message = "Select a table grid first" }) end
end

function M.reload()
  local state = view_for_current_buffer()
  if not state or not state.client or state.loading or state.saving then return end
  state.stale = {}
  for handle in pairs(state.pending) do state.stale[handle] = true end
  for handle in pairs(state.loaded_rows) do
    if not state.pending[handle] then state.loaded_rows[handle] = nil end
  end
  state.needs_reload, state.recovering = false, true
  state.page.rows = {}
  request_page(state, 0)
end

local function invalidate(state)
  state.generation = state.generation + 1
  state.loading, state.saving, state.recovering = false, false, false
  state.needs_reload = true
  for handle in pairs(state.pending) do state.stale[handle] = true end
  show_unmatched_rows(state)
  write_page(state)
end

function M.disconnect(client)
  for _, state in pairs(views) do
    if state.client == client then state.client = nil; invalidate(state) end
  end
  table_pages.disconnect(client)
end

function M.set_connection(client, profile)
  for _, state in pairs(views) do
    if state.relation then
      state.client = state.profile == profile and client or nil
      invalidate(state)
    end
  end
end

function M.before_switch(callback)
  local dirty = {}
  for _, state in pairs(views) do
    if state.saving then
      callback({ code = "busy", message = "Wait for the table save before switching profiles" })
      return
    end
    if next(state.pending) then dirty[#dirty + 1] = state end
  end
  if #dirty == 0 then callback(nil); return end
  vim.ui.select({ "Save", "Discard", "Stay" }, { prompt = "Pending table edits before switching profiles:" }, function(choice)
    dirty = {}
    for _, state in pairs(views) do
      if state.saving then
        callback({ code = "busy", message = "Wait for the table save before switching profiles" })
        return
      end
      if next(state.pending) then dirty[#dirty + 1] = state end
    end
    if choice == "Discard" then
      for _, state in ipairs(dirty) do
        state.pending, state.keys, state.stale = {}, {}, {}
        write_page(state)
      end
      callback(nil)
    elseif choice == "Save" then
      local function save_next(index)
        if index > #dirty then
          for _, state in pairs(views) do
            if next(state.pending) then
              callback({ code = "pending_changed", message = "New edits remain pending; review before switching profiles" })
              return
            end
          end
          callback(nil)
          return
        end
        save(dirty[index], function(err)
          if err then callback(err) else save_next(index + 1) end
        end)
      end
      save_next(1)
    else
      callback({ code = "switch_cancelled", message = "Profile switch cancelled; pending edits retained" })
    end
  end)
end

return M
