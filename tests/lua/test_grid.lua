vim.opt.runtimepath:append(vim.fn.getcwd())
local tables = require("better_sql.table")
local results = require("better_sql.results")
local function key(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end
local columns = { { name = "界", editable = false }, { name = "value", editable = true } }
local rows = {}
for i = 1, 4 do
  rows[i] = { handle = "r" .. i, key = { { text = tostring(i), is_null = false } }, cells = {
    { text = "界" .. i, is_null = false }, { text = "row\n" .. i, is_null = false },
  } }
end
local buf = tables.render({ columns = columns, rows = rows, offset = 0, page_size = 4, has_more = false, editable = true })
key("l")
key("3j")
assert(tables.current_cell().cell.text == "row\n4", "table movement must honor counts")
key("99h")
key("yc")
assert(vim.fn.getreg('"') == "界4", "counted column movement must clamp Unicode cells")
key("99k")
assert(tables.current_cell().cell.text == "界1")

-- Two windows displaying one grid must move the window receiving the keys.
local first_win = vim.api.nvim_get_current_win()
vim.cmd.vsplit()
local second_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(first_win, { 6, 0 })
vim.api.nvim_win_set_cursor(second_win, { 8, 0 })
key("l")
key("yc")
assert(vim.fn.getreg('"') == "row\n3", "cell movement used another window's cursor")
assert(vim.api.nvim_win_get_cursor(first_win)[1] == 6, "cell movement changed the other window")
assert(vim.wo[second_win].winbar:find("value", 1, true), "sticky table headers must survive navigation")
key("K")
local detail = vim.api.nvim_get_current_buf()
assert(table.concat(vim.api.nvim_buf_get_lines(detail, 0, -1, false), "\n"):find("row\n3", 1, true))
key("q")
vim.api.nvim_win_set_cursor(second_win, { 1, 0 })
vim.fn.setreg('"', "unchanged")
key("yc")
key("K")
assert(vim.fn.getreg('"') == "unchanged" and vim.api.nvim_get_current_buf() == buf,
  "metadata must not reuse a stale selected cell")
vim.api.nvim_win_set_cursor(second_win, { 6, 0 })
key("K")
detail = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_delete(buf, { force = true })
assert(not vim.api.nvim_buf_is_valid(detail), "grid detail must close when its parent is wiped")

local result_buf = results.show({ sets = { { columns = columns, rows = { rows[1].cells, rows[2].cells }, status = "SELECT 2" } } })
key("l")
key("j")
key("yc")
assert(vim.fn.getreg('"') == "row\n2", "result adapter must use the same cell mechanics")
vim.api.nvim_buf_delete(result_buf, { force = true })

-- Repainting must preserve independent logical cells in each window, even
-- when a staged value changes the byte positions of following columns.
local repaint_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, repaint_buf)
local repaint = require("better_sql.grid").new(repaint_buf)
local raw_rows = { rows[1].cells, rows[2].cells, rows[3].cells }
repaint:render(columns, raw_rows)
first_win = vim.api.nvim_get_current_win()
vim.cmd.vsplit()
second_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(first_win, { 2, 0 })
repaint:select(3, 2)
local updated_rows = vim.deepcopy(raw_rows)
updated_rows[1][1].text = "界界界界界"
repaint:render(columns, updated_rows)
assert(vim.api.nvim_win_get_cursor(first_win)[1] == 2, "repaint moved the other window's row")
assert(repaint:selection().cell.text == "row\n3", "repaint lost the current window's logical cell")
vim.api.nvim_set_current_win(first_win)
assert(repaint:selection().column_name == "界", "repaint moved the other window's column")
vim.api.nvim_buf_delete(repaint_buf, { force = true })
print("shared grid behavior passed")
