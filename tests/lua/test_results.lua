vim.opt.runtimepath:append(vim.fn.getcwd())

local results = require("better_sql.results")
local better_sql = require("better_sql")

local function lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local buf = results.show({ sets = {
  { columns = { { name = "wide" }, { name = "empty" }, { name = "null" } },
    rows = { { { text = "界", is_null = false }, { text = "", is_null = false }, { text = "", is_null = true } } },
    status = "SELECT 1", truncated = true },
  { columns = {}, rows = {}, status = "CREATE TABLE", truncated = false },
} }, "local_db")
assert(vim.bo[buf].modifiable == false and vim.bo[buf].buftype == "nofile")
assert(vim.wo.wrap == false)
local first = lines(buf)
assert(first:find("local_db", 1, true) and first:find("Result 1/2", 1, true))
assert(first:find("SELECT 1", 1, true) and first:find("truncated", 1, true))
assert(first:find("NULL", 1, true) and first:find('""', 1, true))
assert(first:find("界", 1, true))
results.select_set(2)
assert(lines(buf):find("Result 2/2", 1, true) and lines(buf):find("CREATE TABLE", 1, true))
assert(vim.bo[buf].modifiable == false)
results.select_set(1)
assert(lines(buf):find("Result 1/2", 1, true))

local dsn = assert(vim.env.BETTER_SQL_TEST_DSN)
better_sql.setup({ connections = { local_db = dsn }, python = ".venv/bin/python", max_rows = 3, max_bytes = 4096 })
local connected, connect_error
better_sql.connect("local_db", function(err)
  connected, connect_error = true, err
end)
assert(vim.wait(3000, function() return connected end), "connect timed out")
assert(connect_error == nil, vim.inspect(connect_error))
vim.cmd.runtime("plugin/better_sql.lua")
assert(vim.fn.exists(":BetterSqlRun") == 2 and vim.fn.exists(":BetterSqlRunBuffer") == 2)

local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 1 as id; select 2 as id;" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
vim.cmd.BetterSqlRun()
assert(vim.wait(3000, function() return results.current_buffer and vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("1", 1, true) end), "statement query timed out")
assert(lines(results.current_buffer):find("Result 1/1", 1, true))
assert(not lines(results.current_buffer):find("Result 1/2", 1, true))
assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "select 1 as id; select 2 as id;")

vim.api.nvim_set_current_buf(source)
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function() return results.current_buffer and vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("Result 1/2", 1, true) end), "buffer query timed out")
results.select_set(2)
assert(lines(results.current_buffer):find("\n2%s*$"), lines(results.current_buffer))

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 9 as id;", "select 10 as id;" })
vim.cmd("2BetterSqlRun")
assert(vim.wait(3000, function() return vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("10", 1, true) end), "range query timed out")
assert(not lines(results.current_buffer):find("Result 1/2", 1, true))

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 42 as id;" })
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function() return vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("42", 1, true) end), "last query timed out")

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 42;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local prior_result = results.current_buffer
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v7l\\sr", true, false, true), "xt", false)
assert(vim.wait(3000, function()
  return results.current_buffer ~= prior_result and vim.api.nvim_buf_is_valid(results.current_buffer)
end), "visual query timed out")
assert(lines(results.current_buffer):find("\n4%s*$"), lines(results.current_buffer))
assert(not lines(results.current_buffer):find("42", 1, true))

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select generate_series(1, 10) as n;" })
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function()
  return vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("truncated", 1, true)
end), "truncated query timed out")

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "create temporary table better_sql_task5_smoke (id integer);" })
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function()
  return vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("CREATE TABLE", 1, true)
end), "DDL timed out")

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 1 / 0;" })
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function()
  return better_sql.last_query_error and better_sql.last_query_error.source_buffer == source
    and vim.api.nvim_buf_is_valid(results.current_buffer) and lines(results.current_buffer):find("Error:", 1, true)
end), "query error timed out")
assert(lines(results.current_buffer):find("22012", 1, true))

vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { [[SELECT E'bad\nvalue'::int]] })
better_sql.last_query_error = nil
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function()
  return better_sql.last_query_error and lines(results.current_buffer):find("bad\\nvalue", 1, true)
end), "multiline PostgreSQL error was not rendered")
assert(lines(results.current_buffer):find("22P02", 1, true))
assert(not vim.bo[results.current_buffer].modifiable)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 'é' as x,", " from" })
local before_error = lines(source)
better_sql.last_query_error = nil
vim.cmd.BetterSqlRunBuffer()
assert(vim.wait(3000, function() return better_sql.last_query_error ~= nil end), "positioned error timed out")
assert(better_sql.last_query_error.error.position == 19, vim.inspect(better_sql.last_query_error))
assert(better_sql.last_query_error.row == 1 and better_sql.last_query_error.col == 1, vim.inspect(better_sql.last_query_error))
assert(vim.api.nvim_get_current_buf() == source)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 1 }))
assert(lines(source) == before_error, "error navigation changed source SQL")

vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 1; select 'é' as x, from" })
vim.api.nvim_win_set_cursor(0, { 1, 15 })
better_sql.last_query_error = nil
vim.cmd.BetterSqlRun()
assert(vim.wait(3000, function() return better_sql.last_query_error ~= nil end), "statement error timed out")
assert(better_sql.last_query_error.row == 0 and better_sql.last_query_error.col == 28,
  vim.inspect(better_sql.last_query_error))
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 28 }))

vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 1;", "  select 'é' as x, from" })
better_sql.last_query_error = nil
vim.cmd("2BetterSqlRun")
assert(vim.wait(3000, function() return better_sql.last_query_error ~= nil end), "range error timed out")
assert(better_sql.last_query_error.row == 1 and better_sql.last_query_error.col == 20,
  vim.inspect(better_sql.last_query_error))
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 20 }))

vim.api.nvim_buf_set_lines(source, 0, -1, false, { "xxx select 'é' as x, from extra" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
better_sql.last_query_error = nil
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v20l\\sr", true, false, true), "xt", false)
assert(vim.wait(3000, function() return better_sql.last_query_error ~= nil end), "visual error timed out")
assert(better_sql.last_query_error.row == 0 and better_sql.last_query_error.col == 22,
  vim.inspect(better_sql.last_query_error))
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 22 }))

better_sql.client:stop()
