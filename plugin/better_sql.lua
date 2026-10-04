if vim.g.loaded_better_sql then
  return
end
vim.g.loaded_better_sql = true

vim.api.nvim_create_user_command("BetterSqlConnect", function(opts)
  local better_sql = require("better_sql")
  local function connect(name)
    if not name then
      return
    end
    better_sql.connect(name, function(err)
      if err then
        vim.notify(err.message, vim.log.levels.ERROR)
      end
    end)
  end
  if opts.args ~= "" then connect(opts.args); return end
  local names = vim.tbl_keys(better_sql.config.connections)
  table.sort(names)
  vim.ui.select(names, { prompt = "PostgreSQL connection" }, connect)
end, { nargs = "?", complete = function(prefix)
  local names = {}
  for name in pairs(require("better_sql").config.connections) do
    if name:sub(1, #prefix) == prefix then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end, desc = "Connect to a named PostgreSQL profile or choose one" })

vim.api.nvim_create_user_command("BetterSqlRun", function(opts)
  local range = opts.range > 0 and { opts.line1, opts.line2 } or nil
  require("better_sql").run(range)
end, { range = true })

vim.api.nvim_create_user_command("BetterSqlRunBuffer", function()
  require("better_sql").run_buffer()
end, {})

vim.api.nvim_create_user_command("BetterSqlExport", function(opts)
  local path = vim.fn.expand(opts.args)
  local err = require("better_sql").export(path, opts.bang)
  if err then vim.notify(err, vim.log.levels.ERROR)
  else vim.notify("CSV exported to " .. path, vim.log.levels.INFO) end
end, { nargs = 1, bang = true, complete = "file", desc = "Export the current result set or visible table page as CSV" })

vim.api.nvim_create_user_command("BetterSqlSchema", function()
  require("better_sql.schema").show(function(schema_name, relation_name, relation)
    require("better_sql").open_relation(schema_name, relation_name, relation)
  end)
end, {})

vim.api.nvim_create_user_command("BetterSqlRefreshSchema", function()
  require("better_sql").refresh_schema(function(err)
    if err then
      vim.notify(err.message, vim.log.levels.ERROR)
    end
  end)
end, {})

vim.keymap.set("x", "<leader>sr", function()
  require("better_sql").run_visual()
end, { desc = "Run selected SQL" })

vim.api.nvim_create_user_command("BetterSqlCancel", function()
  require("better_sql").cancel()
end, {})

vim.api.nvim_create_user_command("BetterSqlReconnect", function()
  require("better_sql").reconnect()
end, {})
