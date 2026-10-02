local M = {}
local display = require("better_sql.display")

local operators = { "=", "!=", ">", ">=", "<", "<=", "contains", "IS NULL", "IS NOT NULL", "Clear column filter" }

function M.describe(filters, sort)
  local descriptions = {}
  for _, filter in ipairs(filters) do
    local operator = ({ is_null = "IS NULL", not_null = "IS NOT NULL" })[filter.operator] or filter.operator
    local description = display.line(filter.column) .. " " .. operator
    if filter.value ~= nil then description = description .. " " .. display.cell(filter.value, false) end
    descriptions[#descriptions + 1] = description
  end
  local ordering = sort and (display.line(sort.column) .. " " .. sort.direction:upper()) or "default"
  return "Filter: " .. (#descriptions > 0 and table.concat(descriptions, " AND ") or "none") .. "  Sort: " .. ordering
end

function M.filter(column, filters, is_current, apply)
  local current
  for _, filter in ipairs(filters) do
    if filter.column == column then current = filter end
  end
  vim.ui.select(operators, { prompt = "Filter " .. display.line(column) }, function(choice)
    if not choice or not is_current() then return end
    local function replace(value)
      if not is_current() then return end
      local updated = {}
      for _, filter in ipairs(filters) do
        if filter.column ~= column then updated[#updated + 1] = vim.deepcopy(filter) end
      end
      if choice ~= "Clear column filter" then
        local operator = ({ ["IS NULL"] = "is_null", ["IS NOT NULL"] = "not_null" })[choice] or choice
        updated[#updated + 1] = { column = column, operator = operator, value = value }
      end
      apply(updated)
    end
    if choice == "Clear column filter" or choice == "IS NULL" or choice == "IS NOT NULL" then
      replace(nil)
    else
      vim.ui.input({ prompt = display.line(column) .. " " .. choice .. ": ", default = current and current.value or "" },
        function(value) if value ~= nil then replace(value) end end)
    end
  end)
end

function M.sort(column, is_current, apply)
  vim.ui.select({ "Ascending", "Descending", "Default order" }, { prompt = "Sort by " .. display.line(column) }, function(choice)
    if not choice or not is_current() then return end
    if choice == "Default order" then apply(nil)
    else apply({ column = column, direction = choice == "Ascending" and "asc" or "desc" }) end
  end)
end

return M
