local M = {}
local connection = require("better_sql.connection")
local statement = require("better_sql.statement")
local results = require("better_sql.results")
local completion = require("better_sql.completion")
local table_view = require("better_sql.table")

local sql_winbars = {}
local function update_sql_profiles()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local saved = sql_winbars[win]
    if vim.bo[buf].filetype == "sql" and vim.api.nvim_win_get_config(win).relative == "" then
      local current = vim.wo[win].winbar
      if not saved or current ~= saved.rendered then saved = { original = current } end
      saved.rendered = "SQL | " .. (M.active_profile or "No active connection"):gsub("%%", "%%%%")
      sql_winbars[win] = saved
      vim.wo[win].winbar = saved.rendered
    elseif saved then
      if vim.wo[win].winbar == saved.rendered then vim.wo[win].winbar = saved.original end
      sql_winbars[win] = nil
    end
  end
  for win in pairs(sql_winbars) do
    if not vim.api.nvim_win_is_valid(win) then sql_winbars[win] = nil end
  end
end

function M.setup(options)
  options = options or {}
  M.config = {
    connections = options.connections or {},
    python = options.python or "python3",
    max_rows = options.max_rows or 1000,
    max_bytes = options.max_bytes or 4194304,
  }
  completion.setup()
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("BetterSqlProfile", { clear = true }),
    callback = update_sql_profiles,
  })
  update_sql_profiles()
end

M.setup()

local function sync_connection(state)
  M.client, M.active_profile = state.client, state.profile
  update_sql_profiles()
end

connection.subscribe(sync_connection)
sync_connection(connection.snapshot())

function M.connect(name, callback)
  connection.connect(name, M.config, callback)
end

function M.reconnect(callback)
  connection.reconnect(M.config, callback)
end

function M.cancel()
  local active = M._active_query
  if not active or not active.client:is_running() then
    vim.notify("No query is running", vim.log.levels.INFO)
    return
  end
  active.client:cancel(active.id, function(err, result)
    if err then
      vim.notify(err.message, vim.log.levels.ERROR)
    elseif result.cancel_requested then
      vim.notify("Query cancellation requested", vim.log.levels.INFO)
    else
      vim.notify("Query has already finished", vim.log.levels.INFO)
    end
  end)
end

function M.refresh_schema(callback)
  connection.refresh_schema(callback)
end

function M.open_relation(schema_name, relation_name, relation)
  if not M.client then
    vim.notify("Connect to a PostgreSQL profile first", vim.log.levels.ERROR)
    return nil
  end
  if not relation then
    local catalog = connection.get_catalog()
    for _, entry in ipairs(catalog and catalog.schemas or {}) do
      if entry.name == schema_name then
        for _, candidate in ipairs(entry.relations or {}) do
          if candidate.name == relation_name then relation = candidate break end
        end
      end
    end
  end
  if not relation then
    vim.notify("Relation is no longer in the schema cache", vim.log.levels.ERROR)
    return nil
  end
  return table_view.open(M.client, relation, M.active_profile)
end

local function source_position(sql, start_row, start_col, position)
  if type(position) ~= "number" or position < 1 or position > vim.fn.strchars(sql) + 1 then
    return nil, nil
  end
  local byte_offset = vim.str_byteindex(sql, position - 1)
  local prefix = sql:sub(1, byte_offset)
  local row = start_row
  for _ in prefix:gmatch("\n") do
    row = row + 1
  end
  local last_newline = prefix:match(".*()\n")
  local col = last_newline and (#prefix - last_newline) or (start_col + #prefix)
  return row, col
end

local function run(sql, source_buf, start_row, start_col)
  if not M.client then
    vim.notify("Connect to a PostgreSQL profile first", vim.log.levels.ERROR)
    return
  end
  if not sql or not sql:match("%S") then
    vim.notify("No SQL to run", vim.log.levels.WARN)
    return
  end
  if M._active_query then
    vim.notify("A query is running; use :BetterSqlCancel or wait", vim.log.levels.WARN)
    return
  end
  local active = { client = M.client }
  M._active_query = active
  local profile = M.active_profile
  local source_win = vim.api.nvim_get_current_win()
  active.id = active.client:request("query.run", {
    sql = sql,
    max_rows = M.config.max_rows,
    max_bytes = M.config.max_bytes,
  }, function(err, result)
    if M._active_query == active then M._active_query = nil end
    if err then
      local row, col = source_position(sql, start_row, start_col, err.position)
      M.last_query_error = {
        source_buffer = source_buf, start_row = start_row, start_col = start_col,
        row = row, col = col, error = err,
      }
      results.show_error(err, profile)
      if row and vim.api.nvim_win_is_valid(source_win)
        and vim.api.nvim_win_get_buf(source_win) == source_buf then
        local line = vim.api.nvim_buf_get_lines(source_buf, row, row + 1, false)[1]
        if line then
          vim.api.nvim_win_set_cursor(source_win, { row + 1, math.min(col, #line) })
          vim.api.nvim_set_current_win(source_win)
        end
      end
      return
    end
    results.show(result, profile)
  end)
end

function M.run(range)
  local source_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  if range then
    local first, last = range[1], range[2]
    run(table.concat(vim.list_slice(lines, first, last), "\n"), source_buf, first - 1, 0)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local selected = statement.at_cursor(lines, cursor[1] - 1, cursor[2])
  if selected then
    run(selected.sql, source_buf, selected.start_row, selected.start_col)
  else
    vim.notify("No SQL statement under cursor", vim.log.levels.WARN)
  end
end

function M.run_buffer()
  local buf = vim.api.nvim_get_current_buf()
  run(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), buf, 0, 0)
end

function M.run_visual()
  local mode = vim.fn.mode()
  local anchor = vim.fn.getpos("v")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first_row, first_col = anchor[2], anchor[3] - 1
  local last_row, last_col = cursor[1], cursor[2]
  if first_row > last_row or (first_row == last_row and first_col > last_col) then
    first_row, last_row = last_row, first_row
    first_col, last_col = last_col, first_col
  end
  if mode == "V" then
    run(table.concat(vim.list_slice(lines, first_row, last_row), "\n"), buf, first_row - 1, 0)
    return
  end
  local selected = vim.list_slice(lines, first_row, last_row)
  local last_char = vim.fn.strcharpart(lines[last_row]:sub(last_col + 1), 0, 1)
  selected[#selected] = selected[#selected]:sub(1, last_col + #last_char)
  selected[1] = selected[1]:sub(first_col + 1)
  run(table.concat(selected, "\n"), buf, first_row - 1, first_col)
end

return M
