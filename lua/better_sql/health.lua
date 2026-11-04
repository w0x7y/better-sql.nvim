-- :checkhealth better_sql
local M = {}

local probe = "import sys; print('%d.%d.%d' % sys.version_info[:3]); import psycopg; print(psycopg.__version__)"

local function check_python(python)
  local health = vim.health
  local install = { ("Run: %s -m pip install 'psycopg[binary]>=3.3,<4'"):format(python),
    "Or set `python` in setup() to an interpreter that has Psycopg" }
  if vim.fn.executable(python) == 0 then
    health.error(("Python not found: %s"):format(python), "Set `python` in setup() to a Python 3.10+ interpreter")
    return
  end
  local ok, result = pcall(function() return vim.system({ python, "-c", probe }, { text = true }):wait(10000) end)
  if not ok then
    health.error(("Could not run %s"):format(python))
    return
  end
  local lines = vim.split(vim.trim(result.stdout or ""), "\n")
  local python_version, psycopg_version = lines[1], lines[2]
  local parsed = python_version and vim.version.parse(python_version)
  if not parsed then
    health.error(("%s did not report a Python version"):format(python))
    return
  end
  if vim.version.lt(parsed, { 3, 10, 0 }) then
    health.error(("Python %s at %s is too old; 3.10 or newer is required"):format(python_version, python))
  else
    health.ok(("Python %s at %s"):format(python_version, python))
  end
  if result.code ~= 0 or not psycopg_version then
    health.error("Psycopg is not installed for this Python", install)
    return
  end
  local version = vim.version.parse(psycopg_version)
  if version and vim.version.range(">=3.3.0 <4.0.0"):has(version) then
    health.ok("Psycopg " .. psycopg_version)
  else
    health.error(("Psycopg %s is not supported; 3.3 or newer below 4 is required"):format(psycopg_version), install)
  end
end

function M.check()
  local health = vim.health
  local better_sql = require("better_sql")
  local config = better_sql.config
  health.start("better-sql.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  if vim.api.nvim_get_runtime_file("python/better_sql_helper.py", false)[1] then
    health.ok("Helper found on runtimepath")
  else
    health.error("python/better_sql_helper.py is not on runtimepath", "Reinstall the plugin")
  end
  check_python(config.python)

  local names, invalid = {}, {}
  for name, conninfo in pairs(config.connections) do
    names[#names + 1] = name
    if type(conninfo) ~= "string" or conninfo == "" then invalid[#invalid + 1] = name end
  end
  table.sort(names)
  table.sort(invalid)
  -- Never print connection strings: they can hold passwords.
  if #names == 0 then
    health.warn("No connection profiles configured", "Add `connections` to setup(); see the README")
  else
    health.ok("Profiles: " .. table.concat(names, ", "))
  end
  if #invalid > 0 then
    health.error("These profiles need a nonempty libpq connection string or URI: " .. table.concat(invalid, ", "))
  end
  health.info(better_sql.active_profile and ("Connected to " .. better_sql.active_profile) or "Not connected")
end

return M
