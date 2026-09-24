local M = {}

local catalog_cache
local connection
local loading = false
local load_error
local views = {}

local function node_id(parts)
  return vim.json.encode(parts)
end

local function render_tree(state)
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local lines = {}
  local line_nodes = {}
  local function add(line, node)
    lines[#lines + 1] = line
    line_nodes[#lines] = node
  end

  add(connection and ("Connection: " .. connection) or "No active connection")
  if loading then
    add("Loading schema...")
  elseif load_error then
    add("Schema error: " .. load_error)
  elseif not catalog_cache then
    add("No schema loaded")
  else
    for _, catalog_schema in ipairs(catalog_cache.schemas or {}) do
      local schema_id = node_id({ "schema", catalog_schema.name })
      local schema_open = state.expanded[schema_id] ~= false
      add((schema_open and "▾ " or "▸ ") .. catalog_schema.name,
        { kind = "schema", id = schema_id })
      if schema_open then
        for _, relation in ipairs(catalog_schema.relations or {}) do
          local relation_id = node_id({ "relation", catalog_schema.name, relation.name })
          local relation_open = state.expanded[relation_id] ~= false
          add("  " .. (relation_open and "▾ " or "▸ ") .. relation.name .. " (" .. relation.kind .. ")",
            { kind = "relation", id = relation_id, schema = catalog_schema.name, name = relation.name })
          if relation_open then
            for _, column in ipairs(relation.columns or {}) do
              add("      " .. column.name .. "  " .. column.type_label,
                { kind = "column", id = node_id({ "column", catalog_schema.name, relation.name, column.name }) })
            end
          end
        end
      end
    end
  end
  state.line_nodes = line_nodes
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function render_views()
  for buf, state in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) then
      render_tree(state)
    else
      views[buf] = nil
    end
  end
end

function M.set_catalog(catalog)
  catalog_cache = catalog and vim.deepcopy(catalog) or nil
  loading = false
  load_error = nil
  render_views()
end

function M.get_catalog()
  return catalog_cache and vim.deepcopy(catalog_cache) or nil
end

function M.set_connection(profile)
  connection = profile
  catalog_cache = nil
  loading = false
  load_error = nil
  render_views()
end

function M.set_loading()
  loading = true
  load_error = nil
  render_views()
end

function M.set_error(err)
  loading = false
  load_error = type(err) == "table" and (err.message or err.code) or tostring(err)
  render_views()
end

function M.show(on_open_relation)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("topleft 35vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "better_sql_schema"
  local state = {
    buf = buf,
    expanded = {},
    line_nodes = {},
    on_open_relation = on_open_relation or function() end,
  }
  views[buf] = state
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() views[buf] = nil end,
  })
  vim.keymap.set("n", "<CR>", function()
    local node = state.line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if not node then return end
    if node.kind == "relation" then
      state.expanded[node.id] = state.expanded[node.id] == false
      render_tree(state)
      state.on_open_relation(node.schema, node.name)
    elseif node.kind == "schema" then
      state.expanded[node.id] = state.expanded[node.id] == false
      render_tree(state)
    end
  end, { buffer = buf, silent = true, desc = "Open schema node" })
  render_tree(state)
  return buf
end

return M
