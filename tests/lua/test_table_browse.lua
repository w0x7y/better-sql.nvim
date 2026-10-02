vim.opt.runtimepath:append(vim.fn.getcwd())
local app = require("better_sql")
local grid = require("better_sql.table")
local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function sql(statement)
  local done, failure, result
  app.client:request("query.run", { sql = statement }, function(err, value)
    done, failure, result = true, err, value
  end)
  assert(vim.wait(3000, function() return done end), "SQL timed out")
  assert(not failure, vim.inspect(failure))
  return result
end
local function connect()
  local done, failure
  app.connect("test", function(err) done, failure = true, err end)
  assert(vim.wait(3000, function() return done end), "connect timed out")
  assert(not failure, vim.inspect(failure))
end
local function choose(choice, value)
  vim.ui.select = function(items, _, callback)
    assert(vim.tbl_contains(items, choice), "missing choice: " .. choice)
    callback(choice)
  end
  vim.ui.input = function(_, callback) callback(value) end
end

app.setup({ connections = { test = assert(vim.env.BETTER_SQL_TEST_DSN) }, python = ".venv/bin/python" })
connect()
local schema = "better_sql_browse_" .. vim.fn.getpid()
sql("CREATE SCHEMA " .. schema)
local ok, failure = xpcall(function()
  sql("CREATE TABLE " .. schema .. ".items (id integer PRIMARY KEY, label text, score integer)")
  sql("INSERT INTO " .. schema .. ".items SELECT n, 'row ' || n, n % 2 FROM generate_series(1,205) AS n")
  local refreshed
  app.refresh_schema(function(err) assert(not err, vim.inspect(err)); refreshed = true end)
  assert(vim.wait(3000, function() return refreshed end))
  local buf = app.open_relation(schema, "items")
  local function loaded()
    assert(vim.wait(3000, function() return not text(buf):find("Loading", 1, true) end), "grid timed out")
  end
  loaded()
  assert(type(grid.filter) == "function", "table filtering is missing")
  assert(type(grid.sort) == "function", "table sorting is missing")

  -- A filtered query starts at the first page and orders before applying the limit.
  choose(">=", "2"); key("f"); loaded()
  assert(grid.current_cell().cell.text == "2", "filter did not reach PostgreSQL")
  assert(text(buf):find("Filter:", 1, true) and text(buf):find("id >=", 1, true))
  choose("Descending"); key("o"); loaded()
  assert(grid.current_cell().cell.text == "205", "sort did not reach PostgreSQL")
  assert(text(buf):find("Sort: id DESC", 1, true), "sort status missing")
  key("]p"); loaded()
  assert(text(buf):find("Rows 101-200", 1, true))
  assert(grid.current_cell().cell.text == "105", "paging lost filter or sorting")

  -- Changing criteria resets paging; an empty grid still has usable controls.
  choose("=", "999"); key("f"); loaded()
  assert(text(buf):find("(no rows)", 1, true))
  key("F"); loaded()
  assert(grid.current_cell().cell.text == "205", "clear filters lost sorting")
  choose("Default order"); key("o"); loaded()
  assert(grid.current_cell().cell.text == "1")

  -- Multiple filters combine, and SQL NULL differs from an empty value.
  choose(">=", "200"); key("f"); loaded()
  key("l"); choose("contains", "ROW 20"); key("f"); loaded()
  assert(grid.current_cell().cell.text == "row 200")
  choose("=", ""); key("f"); loaded()
  assert(text(buf):find("(no rows)", 1, true), "empty filter value became cancellation")
  choose("Clear column filter"); key("f"); loaded()
  assert(grid.current_cell().cell.text == "row 200")
  choose("IS NULL"); key("f"); loaded()
  assert(text(buf):find("(no rows)", 1, true))
  key("F"); loaded()

  -- Invalid values leave the last successful page and settings available.
  key("h"); choose("=", "bad integer"); key("f"); loaded()
  assert(text(buf):find("Error:", 1, true))
  assert(grid.current_cell().cell.text == "1", "failed filtering replaced the page")
  key("]p"); loaded()
  assert(grid.current_cell().cell.text == "101", "failed filtering committed invalid criteria")
  key("[p"); loaded()

  -- Filtered-out pending edits stay pinned, recover after reconnect, and save.
  key("]p"); loaded()
  key("l")
  grid.stage(grid.current_cell().row_handle, "label", "hidden edit", false)
  key("h"); choose("=", "205"); key("f"); loaded()
  choose("Descending"); key("o"); loaded()
  assert(grid.pending_count() == 1 and grid.current_cell().cell.text == "205")
  app.client:stop()
  assert(vim.wait(3000, function() return app.client == nil end))
  connect()
  grid.reload(); loaded()
  assert(grid.pending_count() == 1 and grid.current_cell().cell.text == "205")
  assert(not text(buf):find("Unmatched", 1, true), "hidden row treated as deleted on reload")
  local saved, save_error
  grid.save(function(err) saved, save_error = true, err end)
  assert(vim.wait(3000, function() return saved end))
  assert(not save_error, vim.inspect(save_error))
  loaded()
  assert(sql("SELECT label FROM " .. schema .. ".items WHERE id=101").sets[1].rows[1][1].text == "hidden edit")

  -- A save reapplies active criteria when a row's sort/filter value changes.
  key("l"); choose("=", "row 205"); key("f"); loaded()
  grid.stage(grid.current_cell().row_handle, "label", "changed", false)
  saved = false
  grid.save(function(err)
    assert(not err, vim.inspect(err))
    assert(text(buf):find("(no rows)", 1, true), "save callback ran before criteria were reapplied")
    saved = true
  end)
  assert(vim.wait(3000, function() return saved end)); loaded()
  assert(text(buf):find("(no rows)", 1, true), "saved row no longer matches but remains visible")
  key("F"); loaded()

  -- Saving a mutable sort column reorders rows with primary-key tie breaks.
  key("l"); choose("Ascending"); key("o"); loaded()
  assert(grid.current_cell().cell.text == "0")
  grid.stage(grid.current_cell().row_handle, "score", "9", false)
  saved = false
  grid.save(function(err) assert(not err, vim.inspect(err)); saved = true end)
  assert(vim.wait(3000, function() return saved end)); loaded()
  key("hh")
  assert(grid.current_cell().cell.text == "4", "save did not reorder the mutable sort column")

  -- A cancelled prompt leaves rows alone; an old prompt cannot change a new page.
  local previous = text(buf)
  choose("=", nil); key("f")
  assert(text(buf) == previous)
  local delayed
  vim.ui.input = function(_, callback) delayed = callback end
  key("f")
  key("]p"); loaded()
  delayed("does not apply")
  assert(not text(buf):find("does not apply", 1, true), "old filter prompt changed the current page")

  -- Separate grids keep their criteria, and callbacks cannot outlive a connection or buffer.
  local second = app.open_relation(schema, "items")
  assert(vim.wait(3000, function() return not text(second):find("Loading", 1, true) end))
  choose("=", "10"); key("f")
  assert(vim.wait(3000, function() return not text(second):find("Loading", 1, true) end))
  assert(grid.current_cell().cell.text == "10")
  vim.ui.input = function(_, callback) delayed = callback end
  key("f")
  app.client:stop()
  assert(vim.wait(3000, function() return app.client == nil end))
  connect()
  delayed("20")
  grid.reload()
  assert(vim.wait(3000, function() return not text(second):find("Loading", 1, true) end))
  assert(grid.current_cell().cell.text == "10", "old filter input survived reconnect")
  key("f")
  vim.api.nvim_buf_delete(second, { force = true })
  delayed("30")
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  grid.reload(); loaded()
  assert(grid.current_cell().cell.text == "4", "second grid changed the first grid's settings")
  assert(text(buf):find("Sort: score ASC", 1, true))
end, debug.traceback)
sql("DROP SCHEMA " .. schema .. " CASCADE")
app.client:stop()
assert(ok, failure)
print("table filtering and sorting tests passed")
