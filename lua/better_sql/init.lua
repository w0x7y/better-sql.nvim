local M = {}
local Client = require("better_sql.client")
local statement = require("better_sql.statement")
local results = require("better_sql.results")
local schema = require("better_sql.schema")
local completion = require("better_sql.completion")
local table_view = require("better_sql.table")

function M.setup(options)
  options = options or {}
  M.config = {
    connections = options.connections or {},
    python = options.python or "python3",
    max_rows = options.max_rows or 1000,
    max_bytes = options.max_bytes or 4194304,
  }
  completion.setup()
end

M.setup()

local function connect(name, callback)
  callback = callback or function() end
  local conninfo = M.config.connections[name]
  if type(conninfo) ~= "string" or conninfo == "" then
    callback({ code = "unknown_profile", message = "connection profile was not found" }, nil)
    return
  end

  M._connect_generation = (M._connect_generation or 0) + 1
  local generation = M._connect_generation
  local client = Client.new({ python = M.config.python })
  client:start(function(_, err, intentional)
    table_view.disconnect(client)
    if M.client == client then
      M.client = nil
      M.active_profile = nil
      M._catalog_generation = (M._catalog_generation or 0) + 1
      schema.set_connection(nil)
      if not intentional then
        vim.notify((err and err.message) or "Helper disconnected; run :BetterSqlReconnect", vim.log.levels.ERROR)
      end
    end
  end)
  client:request("connect", { conninfo = conninfo }, function(err, result)
    if generation ~= M._connect_generation then
      client:stop()
      callback({ code = "connect_superseded", message = "connection attempt was superseded" }, nil)
      return
    end
    if err then
      client:stop()
      callback(err, nil)
      return
    end
    local initial_catalog
    local function activate(switch_error)
      if generation ~= M._connect_generation then
        switch_error = { code = "connect_superseded", message = "connection attempt was superseded" }
      end
      if switch_error then
        client:stop()
        callback(switch_error, nil)
        return
      end
      local previous = M.client
      M.client = client
      M.active_profile = name
      M._last_profile = name
      table_view.set_connection(client, name)
      schema.set_connection(name)
      if previous then
        previous:stop()
      end
      schema.set_catalog(initial_catalog)
      callback(nil, result)
    end
    -- A successful callback means the helper is ready for the next request.
    client:request("catalog.load", {}, function(catalog_error, catalog)
      initial_catalog = catalog
      if catalog_error then
        activate(catalog_error)
      elseif M._last_profile and M._last_profile ~= name then
        -- Edits can arrive while the new helper connects and loads its catalog.
        table_view.before_switch(activate)
      else
        activate(nil)
      end
    end)
  end)
end

function M.connect(name, callback)
  callback = callback or function() end
  if type(M.config.connections[name]) ~= "string" or M.config.connections[name] == "" then
    callback({ code = "unknown_profile", message = "connection profile was not found" }, nil)
    return
  end
  if M._last_profile and M._last_profile ~= name then
    table_view.before_switch(function(err)
      if err then callback(err, nil) else connect(name, callback) end
    end)
  else
    connect(name, callback)
  end
end

function M.reconnect(callback)
  callback = callback or function(err)
    if err then vim.notify(err.message, vim.log.levels.ERROR) end
  end
  if not M._last_profile then
    callback({ code = "not_connected", message = "Choose a profile with :BetterSqlConnect first" })
    return
  end
  M.connect(M._last_profile, callback)
end

function M.cancel()
  local active = M._active_query
  if not active or not active.client.process or active.client.stopping then
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
  callback = callback or function() end
  local client = M.client
  if not client then
    local err = { code = "not_connected", message = "Connect to a PostgreSQL profile first" }
    callback(err, nil)
    return
  end
  M._catalog_generation = (M._catalog_generation or 0) + 1
  local generation = M._catalog_generation
  schema.set_loading()
  client:request("catalog.load", {}, function(err, catalog)
    if M.client ~= client or M._catalog_generation ~= generation then
      return
    end
    if err then
      schema.set_error(err)
    else
      schema.set_catalog(catalog)
    end
    callback(err, catalog)
  end)
end

function M.open_relation(schema_name, relation_name, relation)
  if not M.client then
    vim.notify("Connect to a PostgreSQL profile first", vim.log.levels.ERROR)
    return nil
  end
  if not relation then
    local catalog = schema.get_catalog()
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
