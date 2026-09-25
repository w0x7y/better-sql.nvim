vim.opt.runtimepath:append(vim.fn.getcwd())

local statement = require("better_sql.statement")

local function expect_sql(lines, row, col, expected)
  local hit = statement.at_cursor(lines, row, col)
  assert(hit and hit.sql == expected, vim.inspect({ expected = expected, actual = hit }))
  return hit
end

local ordinary = { "select 1; select 2;" }
expect_sql(ordinary, 0, 3, "select 1;")
expect_sql(ordinary, 0, 10, "select 2;")
expect_sql(ordinary, 0, 8, "select 1;") -- Cursor on the final semicolon.

local quoted = {
  { "select ';' as value;", "select 2;" },
  { "select 'it'';s fine';", "select 2;" },
  { 'select "odd;name" from "ta"";ble";', "select 2;" },
  { "select $$one;two$$;", "select 2;" },
  { "select $tag$one; $other$ two$tag$;", "select 2;" },
  { "select 1 -- ;", ";", "select 2;" },
  { "select /* outer ; /* inner ; */ outer ; */ 1;", "select 2;" },
}
for _, lines in ipairs(quoted) do
  expect_sql(lines, 0, 3, lines[1] .. (lines[2] == ";" and "\n;" or ""))
  expect_sql(lines, #lines - 1, 3, "select 2;")
end

local multi = { "  select 'é;'", "  || 'x';  select 2;  " }
local hit = expect_sql(multi, 0, 5, "select 'é;'\n  || 'x';")
assert(hit.start_row == 0 and hit.start_col == 2, vim.inspect(hit))
-- End offsets are exclusive and count bytes, including the two bytes in é.
assert(hit.end_row == 1 and hit.end_col == 9, vim.inspect(hit))
expect_sql(multi, 1, 18, "select 2;")
assert(statement.at_cursor({ " ", "\t" }, 0, 0) == nil)

assert(statement.state_at({ "select 'x;y'" }, 0, 10) == "single_quote")
assert(statement.state_at({ 'select "x;y"' }, 0, 10) == "double_quote")
assert(statement.state_at({ "select $tag$x;y$tag$" }, 0, 16) == "dollar_quote")
assert(statement.state_at({ "select -- x;y" }, 0, 13) == "line_comment")
assert(statement.state_at({ "select /* x;y */" }, 0, 13) == "block_comment")
assert(statement.state_at({ "select -- x;y", "select 2" }, 1, 0) == "normal")

-- PostgreSQL E strings let a backslash escape the following quote.
for _, prefix in ipairs({ "E", "e" }) do
  local line = "select " .. prefix .. "'it\\';still'; select 2;"
  expect_sql({ line }, 0, 3, "select " .. prefix .. "'it\\';still';")
  expect_sql({ line }, 0, 25, "select 2;")
  assert(statement.state_at({ line }, 0, 13) == "single_quote")
end

-- A backslash has no special meaning in an ordinary single-quoted string.
expect_sql({ "select 'it\\'; select 2;" }, 0, 3, "select 'it\\';")
