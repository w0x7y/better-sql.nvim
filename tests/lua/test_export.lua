vim.opt.runtimepath:append(vim.fn.getcwd())
local results = require("better_sql.results")
local grid = require("better_sql.table")
local better_sql = require("better_sql")
vim.cmd.runtime("plugin/better_sql.lua")
local path = vim.fn.tempname() .. " space.csv"
local function read()
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end
local function export(bang)
  vim.cmd("BetterSqlExport" .. (bang and "!" or "") .. " " .. vim.fn.fnameescape(path))
end
local notices = {}
vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
local buf = results.show({ sets = {
  { columns = { { name = 'a,"b' }, { name = "界" }, { name = "empty" } }, rows = {
    { { text = "one\r\ntwo", is_null = false }, { text = "", is_null = true }, { text = "", is_null = false } },
  }, status = "SELECT 1", truncated = true },
  { columns = { { name = "second" } }, rows = { { { text = "2", is_null = false } } }, status = "SELECT 1" },
  { columns = {}, rows = {}, status = "UPDATE 1" },
  { columns = { { name = "empty_result" } }, rows = {}, status = "SELECT 0" },
} })
export()
assert(read() == '"a,""b","界","empty"\r\n"one\r\ntwo",,""\r\n', "CSV must preserve raw text and distinguish NULL from empty strings")
results.select_set(2)
export()
assert(read():find('"a,""b"', 1, true), "export must refuse to overwrite existing files")
assert(notices[#notices].level == vim.log.levels.ERROR)
export(true)
assert(read() == '"second"\r\n"2"\r\n', "export must use the selected set")
results.select_set(3)
export(true)
assert(read() == '"second"\r\n"2"\r\n', "command-only results must not destroy an export")
results.select_set(4)
export(true)
assert(read() == '"empty_result"\r\n', "zero rows must still export headers")

local columns = { { name = "id", editable = false }, { name = "note", editable = true } }
local requests = {}
local client = { request = function(_, method, params, callback)
  requests[#requests + 1] = { method = method, callback = callback }
end }
local table_buf = grid.open(client, { schema = "public", name = "items", columns = columns, primary_key = { "id" } }, "test")
requests[1].callback(nil, { columns = columns, rows = {
  { handle = "r1", key = { { text = "1", is_null = false } }, cells = {
    { text = "1", is_null = false }, { text = "old", is_null = false },
  } },
}, offset = 100, has_more = true, editable = true })
grid.stage("r1", "note", "staged\nvalue", false)
export(true)
assert(read() == '"id","note"\r\n"1","staged\nvalue"\r\n', "table exports must contain the visible page and staged values")
assert(grid.pending_count() == 1 and #requests == 1, "export must neither save nor query more pages")
vim.api.nvim_feedkeys('l"byc', "xt", false)
assert(vim.fn.getreg("b") == "staged\nvalue", "table copy must use staged raw values")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.setreg("b", "unchanged")
vim.api.nvim_feedkeys('"byc', "xt", false)
assert(vim.fn.getreg("b") == "unchanged", "table headers must not copy stale cells")
assert(better_sql.export(path .. "/missing.csv", false) ~= nil, "write failures must be returned")
vim.cmd.enew()
export(true)
assert(read():find("staged\nvalue", 1, true), "export outside a grid must not reuse the last results")
assert(notices[#notices].level == vim.log.levels.ERROR)
vim.fn.delete(path)
if vim.api.nvim_buf_is_valid(table_buf) then vim.api.nvim_buf_delete(table_buf, { force = true }) end
if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
print("CSV export and table copy passed")
