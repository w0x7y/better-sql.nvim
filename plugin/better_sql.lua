if vim.g.loaded_better_sql then
  return
end
vim.g.loaded_better_sql = true

vim.api.nvim_create_user_command("BetterSqlConnect", function()
  local better_sql = require("better_sql")
  local names = vim.tbl_keys(better_sql.config.connections)
  table.sort(names)
  vim.ui.select(names, { prompt = "PostgreSQL connection" }, function(name)
    if not name then
      return
    end
    better_sql.connect(name, function(err)
      if err then
        vim.notify(err.message, vim.log.levels.ERROR)
      end
    end)
  end)
end, {})

vim.api.nvim_create_user_command("BetterSqlRun", function(opts)
  local range = opts.range > 0 and { opts.line1, opts.line2 } or nil
  require("better_sql").run(range)
end, { range = true })

vim.api.nvim_create_user_command("BetterSqlRunBuffer", function()
  require("better_sql").run_buffer()
end, {})

vim.keymap.set("x", "<leader>sr", function()
  require("better_sql").run_visual()
end, { desc = "Run selected SQL" })
