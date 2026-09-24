vim.opt.runtimepath:append(vim.fn.getcwd())

local schema = require("better_sql.schema")
schema.set_catalog({ schemas = {{ name = "public", relations = {
  { schema = "public", name = "users", kind = "table", primary_key = { "id" },
    columns = {{ name = "id", type_label = "integer" }} },
  { schema = "public", name = "active_users", kind = "view", primary_key = {},
    columns = {{ name = "name", type_label = "text" }} },
}}} })
local opened
local buf = schema.show(function(schema_name, relation_name)
  opened = { schema_name, relation_name }
end)
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:find("users", 1, true), text)
assert(text:find("id", 1, true), text)
assert(text:find("active_users", 1, true), text)
assert(text:find("name", 1, true), text)
assert(vim.bo[buf].buftype == "nofile")

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local users_line, schema_line
for index, line in ipairs(lines) do
  if line:find("users (table)", 1, true) then users_line = index end
  if line:find("public", 1, true) then schema_line = index end
end
assert(users_line and schema_line)
vim.api.nvim_win_set_cursor(0, { users_line, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(opened and opened[1] == "public" and opened[2] == "users", vim.inspect(opened))
vim.api.nvim_win_set_cursor(0, { schema_line, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("users", 1, true))

local copy = schema.get_catalog()
copy.schemas[1].relations[1].name = "corrupted"
assert(schema.get_catalog().schemas[1].relations[1].name == "users", "cache was mutable through getter")
local supplied = { schemas = {{ name = "outside", relations = {} }} }
schema.set_catalog(supplied)
supplied.schemas[1].name = "corrupted"
assert(schema.get_catalog().schemas[1].name == "outside", "cache was mutable through setter")
schema.set_connection("preview")
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Connection: preview", 1, true))
schema.set_loading()
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Loading schema", 1, true))
schema.set_error({ message = "access denied" })
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("Schema error: access denied", 1, true))
schema.set_connection(nil)
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("No active connection", 1, true))
assert(schema.get_catalog() == nil)

local better_sql = require("better_sql")
local dsn = vim.env.BETTER_SQL_TEST_DSN
assert(dsn and dsn ~= "", "BETTER_SQL_TEST_DSN required")
better_sql.setup({ connections = { local_db = dsn }, python = ".venv/bin/python" })
vim.cmd.runtime("plugin/better_sql.lua")
assert(vim.fn.exists(":BetterSqlSchema") == 2)
assert(vim.fn.exists(":BetterSqlRefreshSchema") == 2)
local connected, connect_error
better_sql.connect("local_db", function(err)
  connect_error = err
  connected = true
end)
assert(vim.wait(3000, function() return connected end), "connect timed out")
assert(connect_error == nil, vim.inspect(connect_error))
assert(vim.wait(3000, function() return schema.get_catalog() ~= nil end), "catalog did not load on connect")
assert(schema.get_catalog().schemas ~= nil)

local catalog_before = schema.get_catalog()
local object_name = "better_sql_schema_task7_" .. vim.fn.getpid()
local created
better_sql.client:request("query.run", {
  sql = "CREATE TABLE IF NOT EXISTS public." .. object_name .. " (id integer PRIMARY KEY)",
  max_rows = 1, max_bytes = 4096,
}, function(err) assert(err == nil, vim.inspect(err)); created = true end)
assert(vim.wait(3000, function() return created end), "table creation timed out")
local function contains_relation(catalog, name)
  for _, item in ipairs(catalog.schemas) do
    for _, relation in ipairs(item.relations) do
      if relation.name == name then return true end
    end
  end
  return false
end
assert(not contains_relation(catalog_before, object_name))
assert(not contains_relation(schema.get_catalog(), object_name), "DDL refreshed cache implicitly")
vim.cmd.BetterSqlRefreshSchema()
assert(vim.wait(3000, function() return contains_relation(schema.get_catalog() or { schemas = {} }, object_name) end),
  "explicit refresh did not replace catalog")
local tree = schema.show(function() end)
local refreshed_text = table.concat(vim.api.nvim_buf_get_lines(tree, 0, -1, false), "\n")
assert(refreshed_text:find("Connection: local_db", 1, true))
assert(refreshed_text:find(object_name, 1, true))
local dropped
better_sql.client:request("query.run", {
  sql = "DROP TABLE public." .. object_name,
  max_rows = 1, max_bytes = 4096,
}, function(err) assert(err == nil, vim.inspect(err)); dropped = true end)
assert(vim.wait(3000, function() return dropped end), "cleanup timed out")
better_sql.client:stop()
