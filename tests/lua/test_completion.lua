vim.opt.runtimepath:append(vim.fn.getcwd())

local completion = require("better_sql.completion")
local schema = require("better_sql.schema")
local better_sql = require("better_sql")
local statement = require("better_sql.statement")

local lexical_sample = "SELECT 'x' -- hidden\nFROM users"
local positions = statement.normal_positions(lexical_sample)
assert(positions[1] and positions[8], "normal SQL bytes were lost")
assert(not positions[9] and not positions[10], "quoted text was marked as normal SQL")
assert(not positions[15], "comment text was marked as normal SQL")
assert(positions[22], "SQL after a line comment was not restored")

local catalog = { schemas = {
  { name = "public", relations = {
    { schema = "public", name = "users", kind = "r", columns = {
      { name = "id" }, { name = "username" }, { name = "email" },
    } },
    { schema = "public", name = "orders", kind = "r", columns = { { name = "order_id" } } },
    { schema = "public", name = "Mixed Case", kind = "r", columns = { { name = "Full Name" } } },
  } },
  { name = "other", relations = {
    { schema = "other", name = "users", kind = "r", columns = { { name = "other_id" } } },
    { schema = "other", name = "widgets", kind = "r", columns = { { name = "widget_id" } } },
  } },
} }

local function expect(sql, wanted, cursor_col)
  local actual = completion.suggest(sql, cursor_col or #sql, catalog)
  table.sort(actual)
  table.sort(wanted)
  assert(vim.deep_equal(actual, wanted), vim.inspect({ sql = sql, wanted = wanted, actual = actual }))
end

expect("SELECT * FROM us", { "users" })
expect("SELECT * FROM users", { "users" }, #"SELECT * FROM us")
expect("SELECT * FROM users JOIN or", { "orders" })
expect("SELECT users.", { "email", "id", "username" })
expect("SELECT users.us", { "username" })
expect("SELECT users.username", { "username" }, #"SELECT users.us")
expect("SELECT u.\nFROM users u", { "email", "id", "username" }, #"SELECT u.")
expect("SELECT u.\nFROM public.users AS u", { "email", "id", "username" }, #"SELECT u.")
expect("SELECT o.\nFROM users u JOIN orders o ON u.id = o.order_id", { "order_id" }, #"SELECT o.")
expect('SELECT "Mixed Case".', { '"Full Name"' })
expect('SELECT m. FROM "Mixed Case" m', { '"Full Name"' }, #"SELECT m.")
expect('SELECT m. FROM "public"."Mixed Case" m', { '"Full Name"' }, #"SELECT m.")
expect("SELECT * FROM other.us", { "users" })
expect("SELECT * FROM other.users", { "users" }, #"SELECT * FROM other.us")
expect("SELECT other.users.", { "other_id" })
expect("SELECT * FROM public.", { '"Mixed Case"', "orders", "users" })
expect("SELECT * FROM users; SELECT * FROM or", { "orders" })
expect("SELECT * FROM users u; SELECT u.", {})
expect("SELECT users. -- no completion", {})
expect("SELECT 'users.'", {})
expect("SELECT $$users.$$", {})
expect("SELECT /* users. */ 1", {})
expect("SELECT u. -- earlier alias\nFROM users u", { "email", "id", "username" }, #"SELECT u.")
expect("SELECT u. FROM users u WHERE EXISTS (SELECT 1 FROM orders u)",
  { "email", "id", "username" }, #"SELECT u.")
local inner_sql = "SELECT 1 FROM users u WHERE EXISTS (SELECT u. FROM orders u)"
expect(inner_sql, { "order_id" }, inner_sql:find("SELECT u.", 1, true) - 1 + #"SELECT u.")
local correlated_sql = "SELECT 1 FROM users u WHERE EXISTS (SELECT u. FROM orders o)"
expect(correlated_sql, { "email", "id", "username" },
  correlated_sql:find("SELECT u.", 1, true) - 1 + #"SELECT u.")
expect("SELECT u. FROM users u WHERE EXISTS (SELECT 'FROM orders u' /* FROM orders u */)",
  { "email", "id", "username" }, #"SELECT u.")
expect("SELECT u. FROM users u /* (SELECT 1 FROM orders u) */",
  { "email", "id", "username" }, #"SELECT u.")
expect("SELECT u. FROM users u WHERE 'text' = '(SELECT 1 FROM orders u)'",
  { "email", "id", "username" }, #"SELECT u.")

schema.set_catalog(catalog)
better_sql.setup()
vim.opt.virtualedit = "onemore"
local sql_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(sql_buf)
vim.bo[sql_buf].filetype = "sql"
assert(vim.bo[sql_buf].omnifunc == "v:lua.require'better_sql.completion'.omnifunc")
vim.api.nvim_buf_set_lines(sql_buf, 0, -1, false, { "SELECT users." })
vim.api.nvim_win_set_cursor(0, { 1, #"SELECT users." })
assert(completion.omnifunc(1, "") == #"SELECT users.")
assert(vim.deep_equal(completion.omnifunc(0, ""), { "id", "username", "email" }))
vim.bo[sql_buf].filetype = "text"
assert(vim.bo[sql_buf].omnifunc == "", "completion remained attached after leaving SQL")
assert(#vim.api.nvim_get_autocmds({ event = "TextChangedI", buffer = sql_buf }) == 0)
vim.bo[sql_buf].filetype = "sql"
assert(#vim.api.nvim_get_autocmds({ event = "TextChangedI", buffer = sql_buf }) == 1)
local ordinary_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(ordinary_buf)
vim.bo[ordinary_buf].filetype = "text"
assert(vim.bo[ordinary_buf].omnifunc == "")

local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn and dsn ~= "", "BETTER_SQL_TEST_DSN required")
better_sql.setup({ connections = { local_db = dsn }, python = ".venv/bin/python" })
local connected, connect_error
better_sql.connect("local_db", function(err)
  connected, connect_error = true, err
end)
assert(vim.wait(3000, function() return connected end), "connect timed out")
assert(connect_error == nil, vim.inspect(connect_error))
assert(vim.wait(3000, function() return schema.get_catalog() ~= nil end), "catalog timed out")

local suffix = tostring(vim.fn.getpid())
local table_name = "better_sql_completion_" .. suffix
local created, create_error
better_sql.client:request("query.run", {
  sql = "CREATE TABLE public." .. table_name .. " (id integer, username text)",
  max_rows = 1, max_bytes = 4096,
}, function(err) created, create_error = true, err end)
assert(vim.wait(3000, function() return created end), "table creation timed out")
assert(create_error == nil, vim.inspect(create_error))
local refreshed
better_sql.refresh_schema(function(err)
  assert(err == nil, vim.inspect(err))
  refreshed = true
end)
assert(vim.wait(3000, function() return refreshed end), "catalog refresh timed out")

vim.api.nvim_set_current_buf(sql_buf)
vim.api.nvim_buf_set_lines(sql_buf, 0, -1, false, { "SELECT " .. table_name .. "." })
vim.api.nvim_win_set_cursor(0, { 1, #("SELECT " .. table_name .. ".") })
assert(vim.deep_equal(completion.omnifunc(0, ""), { "id", "username" }))
vim.api.nvim_buf_set_lines(sql_buf, 0, -1, false, { "SELECT u.", "FROM public." .. table_name .. " u" })
vim.api.nvim_win_set_cursor(0, { 1, #"SELECT u." })
assert(vim.deep_equal(completion.omnifunc(0, ""), { "id", "username" }))

local socket = vim.fn.tempname() .. ".sock"
local child = vim.fn.jobstart({ "nvim", "--headless", "-u", "NONE", "--listen", socket })
assert(child > 0, "could not start completion smoke Neovim")
assert(vim.wait(1000, function() return vim.fn.getftype(socket) == "socket" end),
  "completion smoke Neovim did not start")
local rpc = vim.fn.sockconnect("pipe", socket, { rpc = true })
assert(rpc > 0, "could not connect to completion smoke Neovim")
vim.fn.rpcrequest(rpc, "nvim_exec_lua", [[
  local dsn, table_name = ...
  vim.opt.runtimepath:append(vim.fn.getcwd())
  local better_sql = require("better_sql")
  local schema = require("better_sql.schema")
  better_sql.setup({ connections = { local_db = dsn }, python = ".venv/bin/python" })
  local connected, connect_error
  better_sql.connect("local_db", function(err)
    connected, connect_error = true, err
  end)
  assert(vim.wait(3000, function() return connected end), "popup smoke connection timed out")
  assert(connect_error == nil, vim.inspect(connect_error))
  assert(vim.wait(3000, function() return schema.get_catalog() ~= nil end),
    "popup smoke catalog timed out")
  vim.bo.filetype = "sql"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT u", "FROM public." .. table_name .. " u" })
  vim.api.nvim_win_set_cursor(0, { 1, #"SELECT u" - 1 })
]], { dsn, table_name })
vim.fn.rpcrequest(rpc, "nvim_input", "A.")
local opened = vim.wait(1000, function()
  return vim.fn.rpcrequest(rpc, "nvim_eval", "pumvisible()") == 1
end)
local popup = vim.fn.rpcrequest(rpc, "nvim_eval", "complete_info(['items']).items")
vim.fn.rpcnotify(rpc, "nvim_input", "\27")
vim.fn.chanclose(rpc)
vim.fn.jobstop(child)
assert(opened, "typing a dot did not open the completion menu")
assert(#popup == 2 and popup[1].word == "id" and popup[2].word == "username", vim.inspect(popup))

local dropped, drop_error
better_sql.client:request("query.run", {
  sql = "DROP TABLE public." .. table_name,
  max_rows = 1, max_bytes = 4096,
}, function(err) dropped, drop_error = true, err end)
assert(vim.wait(3000, function() return dropped end), "table cleanup timed out")
assert(drop_error == nil, vim.inspect(drop_error))
better_sql.client:stop()
