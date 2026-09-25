vim.opt.runtimepath:append(vim.fn.getcwd())
local results = require("better_sql.results")
local grid = require("better_sql.table")
local schema = require("better_sql.schema")
local function content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local failures = {}
local function check(name, test)
  local ok, err = pcall(test)
  if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
check("multiline result labels", function()
  local buf = results.show({ sets = { {
    columns = { { name = "column\nname" } }, rows = {}, status = "SELECT\n0",
  } } }, "profile\nname")
  assert(content(buf):find("column\\nname", 1, true))
  assert(content(buf):find("profile\\nname", 1, true))
  assert(content(buf):find("SELECT\\n0", 1, true))
  assert(not vim.bo[buf].modifiable)
end)
check("multiline query error", function()
  local buf = results.show_error({ message = "invalid input: bad\nvalue", sqlstate = "22P02" })
  assert(content(buf):find("bad\\nvalue", 1, true))
  assert(content(buf):find("22P02", 1, true))
  assert(not vim.bo[buf].modifiable)
end)
local function open_grid(column_name, profile, relation_name)
  local requests = {}
  local columns = { { name = column_name, editable = true } }
  local client = { request = function(_, method, params, callback)
    requests[#requests + 1] = { method = method, callback = callback }
  end }
  local buf = grid.open(client, { schema = "public", name = relation_name or "test", columns = columns }, profile)
  requests[#requests].callback(nil, {
    columns = columns, rows = { { handle = "r1", key = { { text = "1", is_null = false } },
      cells = { { text = "original", is_null = false } } } },
    offset = 0, has_more = false, editable = true,
  })
  return buf, requests
end
check("multiline grid labels", function()
  local buf = open_grid("column\nname", "profile\nname", "table\nname")
  assert(content(buf):find("column\\nname", 1, true))
  assert(content(buf):find("profile\\nname", 1, true))
  assert(content(buf):find("table\\nname", 1, true))
  vim.api.nvim_feedkeys("K", "xt", false)
  assert(content(vim.api.nvim_get_current_buf()):find("column\\nname", 1, true))
  vim.api.nvim_buf_delete(buf, { force = true })
end)
check("failed save completes once and keeps pending cells", function()
  local buf, requests = open_grid("value", "test")
  grid.stage("r1", "value", "bad\nvalue", false)
  local calls, failure = 0
  grid.save(function(err) calls, failure = calls + 1, err end)
  local err = { code = "database_error", message = "invalid input: bad\nvalue", sqlstate = "22P02" }
  local ok, render_error = pcall(requests[#requests].callback, err)
  assert(not vim.bo[buf].modifiable, "save error left buffer modifiable")
  assert(ok, tostring(render_error))
  assert(calls == 1 and failure == err, "save callback was not completed exactly once")
  assert(grid.pending_count() == 1)
  assert(content(buf):find("bad\\nvalue", 1, true))
  vim.api.nvim_buf_delete(buf, { force = true })
end)
check("unexpected render failure restores readonly and completes save", function()
  local buf, requests = open_grid("value", "test")
  grid.stage("r1", "value", "pending", false)
  local calls, failure = 0
  grid.save(function(err) calls, failure = calls + 1, err end)
  local original = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function() error("injected buffer write failure") end
  local err = { code = "database_error", message = "conversion failed" }
  local ok, render_error = pcall(requests[#requests].callback, err)
  vim.api.nvim_buf_set_lines = original
  assert(not vim.bo[buf].modifiable, "render failure left buffer modifiable")
  assert(ok, tostring(render_error))
  assert(calls == 1 and failure == err, "render failure interrupted save callback")
  assert(grid.pending_count() == 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end)
check("multiline schema labels and errors", function()
  schema.set_connection("profile\nname")
  schema.set_catalog({ schemas = { { name = "schema\nname", relations = {
    { name = "table\nname", kind = "r", columns = { { name = "column\nname", type_label = "custom\ntype" } } },
  } } } })
  local buf = schema.show()
  assert(content(buf):find("schema\\nname", 1, true))
  assert(content(buf):find("column\\nname", 1, true))
  schema.set_error({ message = "bad\nvalue" })
  assert(content(buf):find("bad\\nvalue", 1, true))
  assert(not vim.bo[buf].modifiable)
end)
assert(#failures == 0, table.concat(failures, "\n"))
print("display tests passed")
