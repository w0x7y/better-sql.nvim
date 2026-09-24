local M = {}
local Client = require("better_sql.client")
local statement = require("better_sql.statement")
local results = require("better_sql.results")

function M.setup(options)
  options = options or {}
  M.config = {
    connections = options.connections or {},
    python = options.python or "python3",
    max_rows = options.max_rows or 1000,
    max_bytes = options.max_bytes or 4194304,
  }
end

M.setup()

function M.connect(name, callback)
  callback = callback or function() end
  local conninfo = M.config.connections[name]
  if type(conninfo) ~= "string" or conninfo == "" then
    callback({ code = "unknown_profile", message = "connection profile was not found" }, nil)
    return
  end

  M._connect_generation = (M._connect_generation or 0) + 1
  local generation = M._connect_generation
  local client = Client.new({ python = M.config.python })
  client:start(function()
    if M.client == client then
      M.client = nil
      M.active_profile = nil
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
    local previous = M.client
    M.client = client
    M.active_profile = name
    if previous then
      previous:stop()
    end
    callback(nil, result)
  end)
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
  local profile = M.active_profile
  M.client:request("query.run", {
    sql = sql,
    max_rows = M.config.max_rows,
    max_bytes = M.config.max_bytes,
  }, function(err, result)
    if err then
      M.last_query_error = { source_buffer = source_buf, start_row = start_row, start_col = start_col, error = err }
      results.show_error(err, profile)
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
