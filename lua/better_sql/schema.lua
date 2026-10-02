local M = {}
local display = require("better_sql.display")
local connection = require("better_sql.connection")

local views = {}

local function node_id(parts)
  return vim.json.encode(parts)
end

local function render_tree(state, snapshot)
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.snapshot = snapshot or state.snapshot
  local current = state.snapshot
  local lines = {}
  local line_nodes = {}
  local function add(line, node)
    lines[#lines + 1] = display.line(line)
    line_nodes[#lines] = node
  end

  add(current.profile and ("Connection: " .. current.profile) or "No active connection")
  if current.loading then
    add("Loading schema...")
  elseif current.error then
    local err = current.error
    add("Schema error: " .. (type(err) == "table" and (err.message or err.code) or tostring(err)))
  elseif not current.catalog then
    add("No schema loaded")
  else
    for _, catalog_schema in ipairs(current.catalog.schemas or {}) do
      local schema_id = node_id({ "schema", catalog_schema.name })
      local schema_open = state.expanded[schema_id] ~= false
      add((schema_open and "▾ " or "▸ ") .. catalog_schema.name,
        { kind = "schema", id = schema_id })
      if schema_open then
        for _, relation in ipairs(catalog_schema.relations or {}) do
          local relation_id = node_id({ "relation", catalog_schema.name, relation.name })
          local relation_open = state.expanded[relation_id] ~= false
          add("  " .. (relation_open and "▾ " or "▸ ") .. relation.name .. " (" .. relation.kind .. ")",
            { kind = "relation", id = relation_id, schema = catalog_schema.name,
              name = relation.name, relation = relation })
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
  display.set_lines(state.buf, 0, -1, lines)
end

function M.render(snapshot)
  for buf, state in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) then
      render_tree(state, snapshot)
    else
      views[buf] = nil
    end
  end
end

-- Compatibility for callers that previously read the cache through the tree.
function M.get_catalog()
  return connection.get_catalog()
end

connection.subscribe(M.render)

function M.show(on_open_relation, snapshot)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("botright vsplit")
  vim.api.nvim_win_set_width(0, math.floor(vim.o.columns / 2))
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "better_sql_schema"
  local state = {
    buf = buf,
    expanded = {},
    line_nodes = {},
    on_open_relation = on_open_relation or function() end,
    snapshot = snapshot or connection.snapshot(),
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
      state.on_open_relation(node.schema, node.name, node.relation)
    elseif node.kind == "schema" then
      state.expanded[node.id] = state.expanded[node.id] == false
      render_tree(state)
    end
  end, { buffer = buf, silent = true, desc = "Open schema node" })
  render_tree(state)
  return buf
end

return M
