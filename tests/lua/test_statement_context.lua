vim.opt.runtimepath:append(vim.fn.getcwd())

local statement = require("better_sql.statement")

local function context(lines, row, col)
  assert(type(statement.context) == "function", "statement.context must provide lexical cursor analysis")
  return assert(statement.context(lines, row, col), "valid cursor must have a context")
end

local function expect_tokens(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

-- Tokens use inclusive, one-based byte offsets in the selected, trimmed SQL.
local lines = { "select 1;", '  SELECT "é""Name".username FROM users;' }
local hit = context(lines, 1, #'  SELECT "é""Name".us')
assert(hit.state == "normal")
assert(hit.statement.sql == 'SELECT "é""Name".username FROM users;')
assert(hit.statement.start_row == 1 and hit.statement.start_col == 2)
assert(hit.statement.end_row == 1 and hit.statement.end_col == #lines[2])
assert(hit.cursor == #'SELECT "é""Name".us')
expect_tokens(hit.tokens, {
  { value = "select", kind = "name", first = 1, last = 6 },
  { value = 'é"Name', kind = "name", first = 8, last = 17, quoted = true },
  { value = ".", kind = "punctuation", first = 18, last = 18 },
  { value = "username", kind = "name", first = 19, last = 26 },
  { value = "from", kind = "name", first = 28, last = 31 },
  { value = "users", kind = "name", first = 33, last = 37 },
})
expect_tokens(hit.prefix_tokens, {
  { value = "select", kind = "name", first = 1, last = 6 },
  { value = 'é"Name', kind = "name", first = 8, last = 17, quoted = true },
  { value = ".", kind = "punctuation", first = 18, last = 18 },
  { value = "us", kind = "name", first = 19, last = 20 },
})

-- Prefixes exclude tokens after the cursor, but full tokens retain later aliases.
hit = context({ "SELECT u.", "FROM users u" }, 0, #"SELECT u.")
assert(hit.cursor == #"SELECT u." and hit.statement.end_row == 1)
assert(#hit.tokens == 6 and #hit.prefix_tokens == 3)
assert(hit.tokens[4].value == "from" and hit.tokens[4].first == 11)

-- Strings and comments never contribute relation names or scope punctuation.
local hidden = [[SELECT 'FROM hidden', E'escaped\';still', $tag$JOIN hidden;$tag$ /* outer /* (SELECT hidden) */ ; */ -- FROM hidden
FROM users]]
hit = context({ hidden }, 0, #hidden)
assert(hit.statement.sql == hidden and hit.state == "normal")
local values = {}
for _, token in ipairs(hit.tokens) do values[#values + 1] = token.value end
assert(vim.deep_equal(values, { "select", ",", "e", ",", "from", "users" }), vim.inspect(values))

for _, sample in ipairs({
  { "SELECT 'value", "single_quote" },
  { 'SELECT "unfinished', "double_quote" },
  { "SELECT $tag$value", "dollar_quote" },
  { "SELECT -- value", "line_comment" },
  { "SELECT /* outer /* inner */ value", "block_comment" },
  { [[SELECT E'escaped\'quote]], "single_quote" },
}) do
  hit = context({ sample[1] }, 0, #sample[1])
  assert(hit.state == sample[2], vim.inspect(hit))
  assert(hit.statement.sql == sample[1])
end

-- State is measured before the cursor byte, including paired delimiter bytes.
assert(context({ 'SELECT "a""b"' }, 0, 10).state == "double_quote")
assert(context({ "SELECT /* value */ users" }, 0, 8).state == "block_comment")
assert(context({ "SELECT -- value", "FROM users" }, 1, 0).state == "normal")
hit = context({ "SELECT users; SELECT orders;" }, 0, #"SELECT users")
assert(hit.statement.sql == "SELECT users;" and #hit.tokens == 2)
hit = context({ "SELECT users; SELECT orders;" }, 0, #"SELECT users; SELECT or")
assert(hit.statement.sql == "SELECT orders;" and hit.prefix_tokens[2].value == "or")
assert(context({ " \t" }, 0, 1).statement == nil)
assert(statement.context({ "SELECT 1" }, 0, -1) == nil)
assert(statement.context({ "SELECT 1" }, 1, 0) == nil)
