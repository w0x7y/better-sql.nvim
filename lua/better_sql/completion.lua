local M = {}
local statement = require("better_sql.statement")
local schema = require("better_sql.schema")
local omnifunc_name = "v:lua.require'better_sql.completion'.omnifunc"

local function tokens(sql)
  local result = {}
  local normal = statement.normal_positions(sql)
  local index = 1
  while index <= #sql do
    if not normal[index] then
      index = index + 1
    else
      local char = sql:sub(index, index)
      local word = sql:sub(index):match("^[%a_][%w_$]*")
      if word then
        result[#result + 1] = { value = word:lower(), kind = "name", first = index, last = index + #word - 1 }
        index = index + #word
      elseif char == '"' then
        local finish = index + 1
        while finish <= #sql do
          if sql:sub(finish, finish) == '"' then
            if sql:sub(finish + 1, finish + 1) == '"' then
              finish = finish + 2
            else
              break
            end
          else
            finish = finish + 1
          end
        end
        if finish <= #sql then
          result[#result + 1] = {
            value = sql:sub(index + 1, finish - 1):gsub('""', '"'),
            kind = "name", first = index, last = finish, quoted = true,
          }
          index = finish + 1
        else
          index = index + 1
        end
      elseif char == "." or char == "," or char == "(" or char == ")" then
        result[#result + 1] = { value = char, kind = "punctuation", first = index, last = index }
        index = index + 1
      else
        index = index + 1
      end
    end
  end
  return result
end

local function is_name(token)
  return token and token.kind == "name"
end

local function keyword(token, value)
  return is_name(token) and not token.quoted and token.value == value
end

local function query_scopes(items)
  local current, next_scope = 0, 0
  local parents, stack = {}, {}
  for index, token in ipairs(items) do
    if token.value == "(" then
      token.scope = current
      stack[#stack + 1] = current
      if keyword(items[index + 1], "select") or keyword(items[index + 1], "with") then
        next_scope = next_scope + 1
        parents[next_scope] = current
        current = next_scope
      end
    elseif token.value == ")" then
      token.scope = current
      current = stack[#stack] or 0
      stack[#stack] = nil
    else
      token.scope = current
    end
  end
  return current, parents
end

local function relation_after(items, index)
  local first = items[index + 1]
  if not is_name(first) then return nil end
  local second = items[index + 2]
  local third = items[index + 3]
  if second and second.value == "." and is_name(third) then
    return { schema = first.value, name = third.value }, index + 3
  end
  return { name = first.value }, index + 1
end

local function aliases(items, scope, parents, qualifier)
  local scoped = {}
  for index, token in ipairs(items) do
    if keyword(token, "from") or keyword(token, "join") then
      local relation, last = relation_after(items, index)
      if relation then
        local alias = items[last + 1]
        if keyword(alias, "as") then alias = items[last + 2] end
        if is_name(alias) and not alias.quoted and not vim.tbl_contains({
          "on", "using", "where", "join", "left", "right", "full", "inner", "cross", "natural",
          "group", "order", "limit", "offset", "having", "union", "returning",
        }, alias.value) then
          scoped[token.scope] = scoped[token.scope] or {}
          scoped[token.scope][alias.value] = relation
        elseif is_name(alias) and alias.quoted then
          scoped[token.scope] = scoped[token.scope] or {}
          scoped[token.scope][alias.value] = relation
        end
      end
    end
  end
  while scope do
    if scoped[scope] and scoped[scope][qualifier] then return scoped[scope][qualifier] end
    scope = parents[scope]
  end
  return nil
end

local function find_relation(catalog, schema_name, relation_name)
  local fallback
  for _, entry in ipairs(catalog.schemas or {}) do
    if not schema_name or entry.name == schema_name then
      for _, relation in ipairs(entry.relations or {}) do
        if relation.name == relation_name then
          if schema_name or entry.name == "public" then return relation end
          fallback = fallback or relation
        end
      end
    end
  end
  return fallback
end

local function display_name(name)
  if name:match("^[a-z_][a-z_0-9$]*$") then return name end
  return '"' .. name:gsub('"', '""') .. '"'
end

local function matching_names(names, prefix)
  local result, seen = {}, {}
  for _, name in ipairs(names) do
    if name:sub(1, #prefix) == prefix and not seen[name] then
      result[#result + 1] = display_name(name)
      seen[name] = true
    end
  end
  return result
end

-- cursor_col is the zero-based byte offset in the whole SQL statement.
function M.suggest(sql, cursor_col, catalog)
  if not catalog or type(sql) ~= "string" or cursor_col < 0 or cursor_col > #sql then return {} end
  if statement.state_at({ sql }, 0, cursor_col) ~= "normal" then return {} end
  local selected = statement.at_cursor({ sql }, 0, cursor_col)
  if not selected then return {} end
  local items = tokens(selected.sql)
  local _, parents = query_scopes(items)
  local cursor = cursor_col - selected.start_col
  local before = tokens(selected.sql:sub(1, cursor))
  local scope = query_scopes(before)
  local index = #before
  local prefix = ""
  if is_name(before[index]) and before[index].last == cursor then
    prefix = before[index].value
    index = index - 1
  end
  local qualified = before[index] and before[index].value == "."
  local qualifier, schema_name
  if qualified then
    qualifier = before[index - 1]
    if not is_name(qualifier) then return {} end
    index = index - 2
    if before[index] and before[index].value == "." and is_name(before[index - 1]) then
      schema_name = before[index - 1].value
      index = index - 2
    end
  end
  local relation_position = keyword(before[index], "from") or keyword(before[index], "join")
  if relation_position then
    local names = {}
    local wanted_schema = qualified and qualifier.value or nil
    for _, entry in ipairs(catalog.schemas or {}) do
      if not wanted_schema then names[#names + 1] = entry.name end
      if not wanted_schema or entry.name == wanted_schema then
        for _, relation in ipairs(entry.relations or {}) do
          names[#names + 1] = relation.name
        end
      end
    end
    return matching_names(names, prefix)
  end
  if not qualified then return {} end
  local relation_name = qualifier.value
  local alias = aliases(items, scope, parents, relation_name)
  if alias then
    relation_name, schema_name = alias.name, alias.schema
  end
  local relation = find_relation(catalog, schema_name, relation_name)
  if not relation then return {} end
  local names = {}
  for _, column in ipairs(relation.columns or {}) do
    names[#names + 1] = column.name
  end
  return matching_names(names, prefix)
end

local function buffer_sql(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function cursor_offset(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor[1], false)
  local offset = cursor[2]
  for index = 1, #lines - 1 do offset = offset + #lines[index] + 1 end
  return offset, cursor
end

function M.omnifunc(findstart, _)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "sql" then return findstart == 1 and -1 or {} end
  local offset, cursor = cursor_offset(buf)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line():sub(1, cursor[2])
    local prefix = line:match("([%a_][%w_$]*)$")
    return cursor[2] - #(prefix or "")
  end
  return M.suggest(buffer_sql(buf), offset, schema.get_catalog())
end

local group
local attached = {}
local function attach(buf)
  if attached[buf] then return end
  vim.bo[buf].omnifunc = omnifunc_name
  attached[buf] = vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      if vim.api.nvim_get_current_buf() ~= buf or vim.bo[buf].filetype ~= "sql"
        or vim.fn.pumvisible() == 1 then return end
      if vim.api.nvim_get_current_line():sub(cursor[2], cursor[2]) ~= "." then return end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win)
          or vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_current_buf() ~= buf
          or vim.bo[buf].filetype ~= "sql"
          or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" or vim.fn.pumvisible() == 1 then return end
        local current = vim.api.nvim_win_get_cursor(win)
        if current[1] ~= cursor[1] or current[2] ~= cursor[2]
          or vim.api.nvim_get_current_line():sub(current[2], current[2]) ~= "." then return end
        local matches = M.suggest(buffer_sql(buf), cursor_offset(buf), schema.get_catalog())
        if #matches > 0 then vim.fn.complete(current[2] + 1, matches) end
      end)
    end,
  })
end

local function detach(buf)
  if attached[buf] then
    vim.api.nvim_del_autocmd(attached[buf])
    attached[buf] = nil
  end
  if vim.bo[buf].omnifunc == omnifunc_name then vim.bo[buf].omnifunc = "" end
end

function M.setup()
  group = vim.api.nvim_create_augroup("BetterSqlCompletion", { clear = true })
  attached = {}
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "*",
    callback = function(event)
      if vim.bo[event.buf].filetype == "sql" then attach(event.buf) else detach(event.buf) end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      if vim.bo[buf].filetype == "sql" then attach(buf) else detach(buf) end
    end
  end
end

return M
