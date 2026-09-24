vim.opt.runtimepath:append(vim.fn.getcwd())

local grid = require("better_sql.table")
local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local preview = grid.render({
  columns = {{ name = "id" }, { name = "username" }, { name = "note" }},
  rows = {{ handle = "r1", cells = {
    { text = "1", is_null = false },
    { text = "idan", is_null = false },
    { text = "", is_null = true },
  }}, { handle = "r2", cells = {
    { text = "2", is_null = false },
    { text = "", is_null = false },
    { text = "a | very long value that must be clipped in the grid but fully visible in the detail", is_null = false },
  }}},
  offset = 0, has_more = false, editable = true,
})
assert(vim.bo[preview].modifiable == false)
assert(content(preview):find("idan", 1, true))
assert(content(preview):find("NULL", 1, true))
assert(content(preview):find('""', 1, true))
assert(not content(preview):find("a | very long value that must be clipped", 1, true), "grid did not clip long cell")
assert(vim.wo.winbar:find("username", 1, true), "column header is not fixed in winbar")

local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local preview_lines = vim.api.nvim_buf_get_lines(preview, 0, -1, false)
local second_row
for index, line in ipairs(preview_lines) do
  if index >= 6 and line:find('2', 1, true) then second_row = index end
end
assert(second_row)
vim.api.nvim_win_set_cursor(0, { second_row, 0 })
key("l")
assert(grid.current_cell().column_name == "username")
key("l")
assert(grid.current_cell().column_name == "note")
assert(content(preview):find("a | very long value that must be clipped in the grid but fully visible in the detail", 1, true),
  "detail did not show full cell text")
local data_line = vim.api.nvim_buf_get_lines(preview, second_row - 1, second_row, false)[1]
local value_start = assert(data_line:find("a | very", 1, true))
vim.api.nvim_win_set_cursor(0, { second_row, value_start + 1 })
key("K")
local detail_window
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(win).relative == "win" then detail_window = win end
end
assert(detail_window, "full cell detail did not open")
assert(content(vim.api.nvim_win_get_buf(detail_window))
  :find("note: a | very long value that must be clipped in the grid but fully visible in the detail", 1, true),
  "printed separator inside a value changed the selected column")
key("q")
key("k")
assert(grid.current_cell().column_name == "note", "changing rows lost selected column")
assert(grid.current_cell().row_handle == "r1")

local requests = {}
local fake_client = { request = function(_, method, params, callback)
  requests[#requests + 1] = { method = method, params = params, callback = callback }
end }
local error_buf = grid.open(fake_client, {
  schema = "public", name = "broken", kind = "v", columns = {{ name = "id" }},
}, "fake_profile")
assert(content(error_buf):find("Loading rows", 1, true))
assert(requests[1].method == "table.page")
assert(requests[1].params.schema == "public" and requests[1].params.table == "broken")
assert(requests[1].params.offset == 0)
assert(vim.deep_equal(requests[1].params.retain_handles, {}), "initial page did not retain an empty handle list")
requests[1].callback({ code = "database_error", message = "permission denied" }, nil)
assert(content(error_buf):find("Error: permission denied", 1, true))

local better_sql = require("better_sql")
local schema = require("better_sql.schema")
local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn and dsn ~= "", "BETTER_SQL_TEST_DSN required")
better_sql.setup({ connections = { local_db = dsn }, python = ".venv/bin/python" })
vim.cmd.runtime("plugin/better_sql.lua")

local connected, connect_error
better_sql.connect("local_db", function(err)
  connect_error = err
  connected = true
end)
assert(vim.wait(3000, function() return connected end), "connect timed out")
assert(connect_error == nil, vim.inspect(connect_error))

local suffix = tostring(vim.fn.getpid())
local schema_name = "better_sql_grid_" .. suffix
local function sql(statement)
  local done, request_error
  better_sql.client:request("query.run", { sql = statement, max_rows = 1, max_bytes = 4096 }, function(err)
    request_error = err
    done = true
  end)
  assert(vim.wait(3000, function() return done end), "SQL timed out: " .. statement)
  assert(request_error == nil, vim.inspect(request_error))
end
sql("CREATE SCHEMA " .. schema_name)
sql("CREATE TABLE " .. schema_name .. ".numbered (id integer PRIMARY KEY, label text)")
sql("INSERT INTO " .. schema_name .. ".numbered SELECT n, 'row ' || n FROM generate_series(1, 101) AS n")
sql("CREATE VIEW " .. schema_name .. ".numbered_view AS SELECT id, label FROM " .. schema_name .. ".numbered")

local refreshed
better_sql.refresh_schema(function(err)
  assert(err == nil, vim.inspect(err))
  refreshed = true
end)
assert(vim.wait(3000, function() return refreshed end), "catalog refresh timed out")
vim.cmd.BetterSqlSchema()
local tree = vim.api.nvim_get_current_buf()
local function open_relation(name)
  local lines = vim.api.nvim_buf_get_lines(tree, 0, -1, false)
  local line_number
  for index, line in ipairs(lines) do
    if line:find(name .. " (", 1, true) then line_number = index end
  end
  assert(line_number, "relation missing from schema tree: " .. name)
  vim.api.nvim_set_current_win(vim.fn.bufwinid(tree))
  vim.api.nvim_win_set_cursor(0, { line_number, 0 })
  key("<CR>")
  assert(vim.wait(3000, function()
    return grid.current_buffer and vim.api.nvim_buf_is_valid(grid.current_buffer)
      and content(grid.current_buffer):find("Rows ", 1, true)
      and not content(grid.current_buffer):find("Loading", 1, true)
  end), "table page did not load: " .. name)
  return grid.current_buffer
end

local table_buf = open_relation("numbered")
assert(content(table_buf):find("local_db", 1, true))
assert(content(table_buf):find(schema_name .. ".numbered", 1, true))
assert(content(table_buf):find("Rows 1-100", 1, true), content(table_buf))
assert(vim.wo.winbar:find("id", 1, true) < vim.wo.winbar:find("label", 1, true),
  "column order changed in the fixed header")
assert(content(table_buf):find("row 100", 1, true))
vim.api.nvim_win_set_cursor(0, { 105, 0 })
assert(vim.wo.winbar:find("label", 1, true), "column header disappeared after vertical scrolling")
key("l")
assert(grid.current_cell().column_name == "label")
key("j")
assert(grid.current_cell().column_name == "label", "changing rows lost the selected column")
key("]p")
assert(vim.wait(3000, function() return content(table_buf):find("Rows 101-101", 1, true) end),
  "next page did not load")
assert(content(table_buf):find("row 101", 1, true))
assert(grid.current_cell().column_name == "label", "next page lost the selected column")
key("[p")
assert(vim.wait(3000, function() return content(table_buf):find("Rows 1-100", 1, true) end),
  "previous page did not load")
assert(content(table_buf):find("row 1", 1, true))
assert(grid.current_cell().column_name == "label", "previous page lost the selected column")

local view_buf = open_relation("numbered_view")
assert(content(view_buf):find("read-only", 1, true), content(view_buf))
assert(content(view_buf):find("View", 1, true), content(view_buf))
assert(vim.wo.winbar:find("id", 1, true) and vim.wo.winbar:find("label", 1, true))

sql("DROP SCHEMA " .. schema_name .. " CASCADE")
better_sql.client:stop()
