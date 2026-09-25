vim.opt.rtp:append(vim.fn.getcwd())

local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn and dsn ~= "", "BETTER_SQL_TEST_DSN is required for the end-to-end release gate")
local better_sql = require("better_sql")
local results = require("better_sql.results")
local schema = require("better_sql.schema")
local grid = require("better_sql.table")
local completion = require("better_sql.completion")
better_sql.setup({
  connections = { test = dsn },
  python = vim.env.BETTER_SQL_PYTHON or "python3",
})
vim.cmd.runtime("plugin/better_sql.lua")

local function await(label, operation)
  local done, failure, value
  operation(function(err, result) done, failure, value = true, err, result end)
  assert(vim.wait(5000, function() return done end), label .. " timed out")
  assert(not failure, label .. ": " .. vim.inspect(failure))
  return value
end

local function sql(statement)
  return await("SQL", function(callback)
    better_sql.client:request("query.run", {
      sql = statement, max_rows = 1000, max_bytes = 4194304,
    }, callback)
  end)
end

local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local schema_name = "better_sql_e2e_" .. vim.fn.getpid()
local relation = schema_name .. ".notes"
local created = false
local original_input = vim.ui.input
local ok, failure = xpcall(function()
  await("connect", function(callback) better_sql.connect("test", callback) end)
  sql("CREATE SCHEMA " .. schema_name)
  created = true
  sql("CREATE TABLE " .. relation .. " (id integer PRIMARY KEY, note text, extra text)")
  sql("INSERT INTO " .. relation .. " SELECT n, 'row ' || n, NULL FROM generate_series(1, 101) AS n")

  -- Query commands must render real helper responses, including separate results.
  vim.cmd.enew()
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.bo[source_buf].filetype = "sql"
  assert(vim.wo[source_win].winbar:find("test", 1, true), "active profile missing from SQL view")
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
    "SELECT note, extra, '' AS empty FROM " .. relation .. " WHERE id = 1;",
    "SELECT count(*) AS total FROM " .. relation .. ";",
  })
  vim.cmd.BetterSqlRunBuffer()
  assert(vim.wait(5000, function() return results.current_buffer and not better_sql._active_query end),
    "query results did not arrive")
  local result_buf = results.current_buffer
  assert(content(result_buf):find("test  Result 1/2", 1, true), content(result_buf))
  assert(content(result_buf):find("row 1", 1, true), content(result_buf))
  assert(content(result_buf):find("NULL", 1, true) and content(result_buf):find('""', 1, true),
    "NULL and empty string were not displayed distinctly")
  key("]r")
  assert(content(result_buf):find("Result 2/2", 1, true) and content(result_buf):find("101", 1, true))
  key("[r")
  assert(content(result_buf):find("row 1", 1, true))

  -- DDL stays out of the cache until an explicit refresh.
  for _, entry in ipairs(schema.get_catalog().schemas) do
    assert(entry.name ~= schema_name, "DDL unexpectedly refreshed the schema cache")
  end
  await("schema refresh", function(callback) better_sql.refresh_schema(callback) end)
  vim.cmd.BetterSqlSchema()
  local tree = vim.api.nvim_get_current_buf()
  assert(content(tree):find(schema_name, 1, true) and content(tree):find("note  text", 1, true),
    "refreshed schema or column missing from the tree")
  local table_line
  for index, line in ipairs(vim.api.nvim_buf_get_lines(tree, 0, -1, false)) do
    if line:find("notes (r)", 1, true) then table_line = index end
  end
  vim.api.nvim_win_set_cursor(0, { assert(table_line), 0 })
  key("<CR>")
  local table_buf = assert(grid.current_buffer)
  local function page(label)
    assert(vim.wait(5000, function() return content(table_buf):find(label, 1, true) end),
      "table page did not load: " .. content(table_buf))
  end
  page("Rows 1-100")
  key("l")
  assert(grid.current_cell().column_name == "note")
  vim.ui.input = function(_, callback) callback("edited through Neovim") end
  key("e")
  vim.ui.input = original_input
  assert(grid.pending_count() == 1 and content(table_buf):find("*edited through Neovim", 1, true))
  key("]p")
  page("Rows 101-101")
  assert(grid.pending_count() == 1, "paging lost the staged edit")
  key("[p")
  page("Rows 1-100")
  assert(content(table_buf):find("*edited through Neovim", 1, true), "staged text disappeared after paging")
  key("s")
  assert(vim.wait(5000, function() return grid.pending_count() == 0 end),
    "save did not clear pending edits: " .. content(table_buf))
  local saved = sql("SELECT note FROM " .. relation .. " WHERE id = 1").sets[1].rows
  assert(saved[1][1].text == "edited through Neovim", "save did not update PostgreSQL")

  -- The real cache must supply schemas, relations, and alias columns to SQL buffers.
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_buf(source_win, source_buf)
  assert(vim.bo[source_buf].omnifunc ~= "", "SQL buffer has no omnifunc")
  local prefix = "SELECT * FROM better_sql_e2e_"
  assert(vim.tbl_contains(completion.suggest(prefix, #prefix, schema.get_catalog()), schema_name),
    "schema completion missing in FROM position")
  prefix = "SELECT * FROM " .. schema_name .. ".no"
  assert(vim.tbl_contains(completion.suggest(prefix, #prefix, schema.get_catalog()), "notes"),
    "schema-qualified table completion missing")
  local statement = "SELECT n.no FROM " .. relation .. " AS n"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { statement })
  vim.api.nvim_win_set_cursor(source_win, { 1, #"SELECT n.no" })
  assert(completion.omnifunc(1, "") == #"SELECT n.")
  assert(vim.tbl_contains(completion.omnifunc(0, "no"), "note"), "alias column completion missing")
end, debug.traceback)

-- Cleanup also runs after an assertion fails, so reruns do not leak test tables.
vim.ui.input = original_input
local cleaned, cleanup_error = pcall(function()
  if created then sql("DROP SCHEMA " .. schema_name .. " CASCADE") end
end)
if better_sql.client then
  local client = better_sql.client
  client:stop()
  assert(vim.wait(5000, function() return client.process == nil end), "helper did not stop")
end
assert(ok, failure)
assert(cleaned, cleanup_error)
print("end-to-end PostgreSQL release gate passed")
