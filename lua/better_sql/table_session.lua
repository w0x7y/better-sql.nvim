-- Owns grid originals, staged cells and recovery independently of Neovim buffers.
local M = {}
local PAGE_SIZE = 100
local sessions, queues = {}, {}

local function failure(code, message) return { code = code, message = message } end
local function refresh_failure(err)
  return failure("refresh_failed", "Table edits saved, but grid refresh failed: " .. err.message)
end
local function sorted_keys(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys)
  return keys
end

local function snapshot(state)
  local result = vim.deepcopy({
    relation = state.relation, profile = state.profile, page = state.page,
    filters = state.filters, sort = state.sort, loading = state.loading,
    saving = state.saving, needs_reload = state.needs_reload, error = state.error,
  })
  result.pending_count = 0
  for _, changes in pairs(state.pending) do
    result.pending_count = result.pending_count + vim.tbl_count(changes)
  end
  for _, row in ipairs(result.page.rows) do
    row.dirty = {}
    for index, column in ipairs(result.page.columns) do
      local change = state.pending[row.handle] and state.pending[row.handle][column.name]
      if change then
        row.cells[index] = vim.deepcopy(change)
        row.dirty[column.name] = true
      end
    end
  end
  return result
end

local function publish(state, reset_selection)
  if not state.changed or state.closed then return end
  local ok, message = pcall(state.changed, snapshot(state), reset_selection)
  if not ok then
    state.error = tostring(message)
    return failure("render_error", state.error)
  end
end

local function is_current(state, operation)
  return not state.closed and state.operation == operation and state.client == operation.client
end

local function finish(state, operation, err, result, reset_selection)
  if not is_current(state, operation) then return end
  state.operation = nil
  state.loading, state.saving, state.recovering = false, false, false
  local render_error = publish(state, reset_selection)
  if not err and render_error and operation.saved_result then
    err = refresh_failure(render_error)
    state.error = err.message
  end
  operation.callback(err or render_error, result)
end

local function begin(state, kind, callback)
  callback = callback or function() end
  if state.closed then callback(failure("table_closed", "Table grid closed")); return end
  if state.operation then callback(failure("busy", "Wait for the current table operation")); return end
  local operation = { client = state.client, kind = kind, callback = callback }
  state.operation = operation
  state.generation = state.generation + 1
  state.loading, state.saving, state.error = kind == "load", kind == "save", nil
  return operation
end

-- All grids on a helper share one original store. Serialize requests and compute
-- retention at dispatch time, after the preceding reply has updated its session.
local function run_next(queue)
  if queue.active or queue.closed then return end
  local request = table.remove(queue.waiting, 1)
  if not request then queues[queue.client] = nil; return end
  if not is_current(request.state, request.operation) then run_next(queue); return end
  queue.active = request
  local function reply(err, result)
    if request.replied then return end
    request.replied = true
    local ok, message = pcall(function()
      if is_current(request.state, request.operation) then request.reply(err, result) end
    end)
    queue.active = nil
    if err and err.code == "helper_exited" then
      queue.closed = true
      if queues[queue.client] == queue then queues[queue.client] = nil end
      local waiting = queue.waiting
      queue.waiting = {}
      for _, item in ipairs(waiting) do
        if is_current(item.state, item.operation) then
          local drained, detail = pcall(item.reply, err)
          if not drained and ok then ok, message = false, detail end
        end
      end
    else
      run_next(queue)
    end
    if not ok then error(message) end
  end
  local ok, message = pcall(function()
    queue.client:request(request.method, request.prepare(), reply)
  end)
  if not ok then
    -- An inline transport may throw from the completion callback, after reply
    -- already released the queue. Preserve that error without delivering twice.
    if request.replied then error(message) end
    reply(failure("request_failed", tostring(message)))
  end
end

local function request(state, operation, method, prepare, reply)
  local queue = queues[operation.client]
  if not queue then
    queue = { client = operation.client, waiting = {} }
    queues[operation.client] = queue
  end
  queue.waiting[#queue.waiting + 1] = {
    state = state, operation = operation, method = method, prepare = prepare, reply = reply,
  }
  run_next(queue)
end

local function retained_handles(state)
  local retained = {}
  for view in pairs(sessions) do
    if view.client == state.client and not view.needs_reload then
      for handle in pairs(view.pending) do
        if not view.stale[handle] then retained[handle] = true end
      end
      if view ~= state or state.recovering then
        for _, row in ipairs(view.page.rows) do
          if type(row.handle) == "string" and not view.stale[row.handle] then retained[row.handle] = true end
        end
      end
    end
  end
  return sorted_keys(retained)
end

local function accept_rows(state, page)
  page = vim.deepcopy(page)
  for index, row in ipairs(page.rows) do
    for handle in pairs(state.pending) do
      if vim.deep_equal(state.keys[handle], row.key) then
        if state.stale[handle] then
          state.pending[row.handle], state.keys[row.handle] = state.pending[handle], row.key
          state.pending[handle], state.keys[handle], state.stale[handle], state.originals[handle] = nil, nil, nil, nil
        else
          -- Paging cannot change the optimistic version of a staged row.
          row = state.originals[handle]
          page.rows[index] = row
        end
        break
      end
    end
    if type(row.handle) == "string" then state.originals[row.handle] = row end
  end
  return page
end

local function show_unmatched_rows(state)
  local visible = {}
  for _, row in ipairs(state.page.rows) do
    if type(row.handle) == "string" then visible[row.handle] = true end
  end
  for _, handle in ipairs(sorted_keys(state.stale)) do
    if not visible[handle] and state.originals[handle] then
      state.page.rows[#state.page.rows + 1] = state.originals[handle]
    end
  end
end

local function prune_originals(state)
  local visible = {}
  for _, row in ipairs(state.page.rows) do
    if type(row.handle) == "string" then visible[row.handle] = true end
  end
  for handle in pairs(state.originals) do
    if not state.pending[handle] and not visible[handle] then state.originals[handle] = nil end
  end
end

local function fetch_page(state, operation, offset, options, callback)
  local filters, sort = state.filters, state.sort
  if options then filters, sort = vim.deepcopy(options.filters or {}), vim.deepcopy(options.sort) end
  local function fetch(next_offset, unfiltered)
    request(state, operation, "table.page", function()
      return {
        schema = state.relation.schema, table = state.relation.name,
        offset = next_offset, retain_handles = retained_handles(state),
        filters = unfiltered and {} or filters, sort = sort,
      }
    end, function(err, page)
      if err then
        state.error = err.message or err.code or "Page request failed"
      else
        page = accept_rows(state, page)
        if not state.recovering or (next_offset == offset and not unfiltered) then
          state.page, state.filters, state.sort = page, filters, sort
        end
        if state.recovering and next(state.stale) then
          if #filters > 0 and not unfiltered then fetch(0, true); return end
          if page.has_more then fetch(next_offset + PAGE_SIZE, unfiltered); return end
        end
        state.error = nil
        if next(state.stale) then
          state.error = "Unmatched rows after reload; review and discard their pending cells with u"
        end
      end
      show_unmatched_rows(state)
      prune_originals(state)
      callback(err, options ~= nil)
    end)
  end
  fetch(offset)
end

local function blocked_reason(state, handle, column_name)
  if state.closed then return "Table grid closed" end
  if state.loading then return "Wait for rows to load before editing" end
  if state.needs_reload or state.stale[handle] then return "Reload and review this row before editing" end
  if not state.page.editable then return state.page.read_only_reason or "Relation is read-only" end
  if not state.originals[handle] then return "Unknown row" end
  for _, column in ipairs(state.page.columns) do
    if column.name == column_name then
      if not column.editable then return column.read_only_reason or "Column is read-only" end
      return nil
    end
  end
  return "Unknown column"
end

local function save_error(state, err)
  local details = err.message or err.code or "Save failed"
  if type(err.handle) == "string" then
    local values = {}
    for _, value in ipairs(state.keys[err.handle] or {}) do
      values[#values + 1] = value.is_null and "NULL" or value.text
    end
    details = details .. "  Row: [" .. table.concat(values, ", ") .. "]"
  end
  if type(err.column) == "string" then
    details = details .. "  Column: " .. err.column
  elseif type(err.columns) == "table" and #err.columns > 0 then
    details = details .. "  Columns: " .. table.concat(err.columns, ", ")
  end
  if type(err.sqlstate) == "string" then details = details .. "  SQLSTATE: " .. err.sqlstate end
  return details
end

local function save(state, callback)
  callback = callback or function() end
  if state.closed or state.operation then
    callback(failure(state.closed and "table_closed" or "busy", "Wait for the current table operation")); return
  end
  if not state.client or state.needs_reload or next(state.stale) then
    local err = failure("reload_required", "Reload and review pending rows before saving; discard unmatched cells with u")
    state.error = err.message
    publish(state)
    callback(err)
    return
  end
  if not next(state.pending) then callback(nil, { rows = {} }); return end
  local submitted, edits = {}, {}
  for _, handle in ipairs(sorted_keys(state.pending)) do
    submitted[handle] = {}
    local changes = {}
    for _, column in ipairs(sorted_keys(state.pending[handle])) do
      local value = state.pending[handle][column]
      submitted[handle][column] = value
      changes[#changes + 1] = { column = column, text = value.text, is_null = value.is_null }
    end
    edits[#edits + 1] = { handle = handle, changes = changes }
  end
  local operation = begin(state, "save", callback)
  local render_error = publish(state)
  if render_error then finish(state, operation, render_error); return end
  request(state, operation, "table.save", function()
    return { schema = state.relation.schema, table = state.relation.name, edits = edits }
  end, function(err, result)
    if err then
      state.error = save_error(state, err)
      finish(state, operation, err)
      return
    end
    for _, returned in ipairs(result.rows) do
      local row = vim.deepcopy(returned)
      state.originals[row.handle] = row
      for index, current in ipairs(state.page.rows) do
        if current.handle == row.handle then state.page.rows[index] = row end
      end
      for column, value in pairs(submitted[row.handle] or {}) do
        if state.pending[row.handle] and state.pending[row.handle][column] == value then
          state.pending[row.handle][column] = nil
        end
      end
      if state.pending[row.handle] and not next(state.pending[row.handle]) then
        state.pending[row.handle], state.keys[row.handle] = nil, nil
      elseif state.pending[row.handle] then
        -- Triggers may change a primary key even though grid key cells are read-only.
        state.keys[row.handle] = vim.deepcopy(row.key)
      end
    end
    state.error = nil
    if #state.filters == 0 and not state.sort then finish(state, operation, nil, result); return end
    -- Refresh belongs to the save operation: callbacks run after criteria apply.
    operation.saved_result = result
    state.saving, state.loading = false, true
    local function refreshed(refresh_error)
      if refresh_error then
        local err = refresh_failure(refresh_error)
        state.error = err.message
        finish(state, operation, err, result)
      else
        finish(state, operation, nil, result)
      end
    end
    local render_err = publish(state)
    if render_err then refreshed(render_err)
    else fetch_page(state, operation, 0, nil, refreshed) end
  end)
end

local function invalidate(state, err)
  local operation = state.operation
  state.operation = nil
  state.generation = state.generation + 1
  state.loading, state.saving, state.recovering = false, false, false
  state.needs_reload = true
  for handle in pairs(state.pending) do state.stale[handle] = true end
  show_unmatched_rows(state)
  publish(state)
  if operation then
    if operation.saved_result then
      err = refresh_failure(err)
      state.error = err.message
      publish(state)
    end
    local ok = pcall(operation.callback, err, operation.saved_result)
    if not ok then
      pcall(vim.notify, "Table operation callback failed", vim.log.levels.ERROR)
    end
  end
end

function M.new(client, relation, profile, changed, preview)
  local state = {
    client = client, relation = vim.deepcopy(relation), profile = profile, changed = changed,
    page = vim.deepcopy(preview or { columns = relation and relation.columns or {}, rows = {},
      offset = 0, has_more = false, editable = true }),
    pending = {}, originals = {}, keys = {}, stale = {}, filters = {}, generation = 0,
  }
  for _, row in ipairs(state.page.rows) do
    if type(row.handle) == "string" then state.originals[row.handle] = row end
  end
  sessions[state] = true
  local grid = {}
  function grid:snapshot() return snapshot(state) end
  function grid:guard()
    local generation, connection = state.generation, state.client
    return function()
      return not state.closed and state.generation == generation and state.client == connection
        and not state.loading and not state.needs_reload
    end
  end
  function grid:can_browse()
    if not state.client or state.closed or state.operation then return false end
    if state.needs_reload then return false, "Press r to reload before changing table filters or sorting" end
    return true
  end
  function grid:editable(handle, column) return blocked_reason(state, handle, column) end
  function grid:stage(handle, column, text, is_null)
    local reason = blocked_reason(state, handle, column)
    if reason then return reason end
    state.pending[handle] = state.pending[handle] or {}
    state.keys[handle] = vim.deepcopy(state.originals[handle].key)
    state.pending[handle][column] = { text = text, is_null = is_null }
    return publish(state)
  end
  function grid:discard(handle, column)
    if state.closed or not state.pending[handle] then return end
    state.pending[handle][column] = nil
    if not next(state.pending[handle]) then
      state.pending[handle], state.keys[handle] = nil, nil
      if state.stale[handle] then
        state.stale[handle] = nil
        for index, row in ipairs(state.page.rows) do
          if row.handle == handle then table.remove(state.page.rows, index); break end
        end
      end
    end
    prune_originals(state)
    return publish(state)
  end
  function grid:load(offset, options, callback)
    if not state.client or state.needs_reload then
      if callback then callback(failure("refresh_unavailable", "Reload the table grid before refreshing rows")) end
      return
    end
    local operation = begin(state, "load", callback)
    if not operation then return end
    local render_error = publish(state)
    if render_error then finish(state, operation, render_error); return end
    fetch_page(state, operation, offset, options, function(err, reset)
      finish(state, operation, err, nil, reset)
    end)
  end
  function grid:reload(callback)
    if not state.client or state.closed or state.operation then
      if callback then callback(failure("refresh_unavailable", "Wait for a connection and the current table operation")) end
      return
    end
    state.stale = {}
    for handle in pairs(state.pending) do state.stale[handle] = true end
    for handle in pairs(state.originals) do
      if not state.pending[handle] then state.originals[handle] = nil end
    end
    state.needs_reload, state.recovering = false, true
    state.page.rows = {}
    self:load(0, nil, callback)
  end
  function grid:save(callback) save(state, callback) end
  function grid:close()
    if state.closed then return end
    state.closed = true
    sessions[state] = nil
    invalidate(state, failure("table_closed", "Table grid closed during its operation"))
  end
  return grid
end

function M.disconnect(client)
  for state in pairs(sessions) do
    if state.client == client then
      state.client = nil
      invalidate(state, failure("connection_changed", "Connection changed; reload and review edits"))
    end
  end
  local queue = queues[client]
  if queue then queue.closed, queue.waiting = true, {}; queues[client] = nil end
end

function M.set_connection(client, profile)
  for state in pairs(sessions) do
    if state.relation then
      local next_client = state.profile == profile and client or nil
      if state.client ~= next_client then
        state.client = next_client
        invalidate(state, failure("connection_changed", "Connection changed; reload and review edits"))
      end
    end
  end
end

local function dirty_sessions()
  local dirty = {}
  for state in pairs(sessions) do
    if state.operation and state.operation.kind == "save" then
      return nil, failure("busy", "Wait for the table save before switching profiles")
    end
    if next(state.pending) then dirty[#dirty + 1] = state end
  end
  return dirty
end

function M.before_switch(select, callback)
  local dirty, err = dirty_sessions()
  if err or #dirty == 0 then callback(err); return end
  local resolved = false
  select(function(choice)
    if resolved then return end
    resolved = true
    dirty, err = dirty_sessions()
    if err then callback(err); return end
    if choice == "Discard" then
      for _, state in ipairs(dirty) do
        for index = #state.page.rows, 1, -1 do
          if state.stale[state.page.rows[index].handle] then table.remove(state.page.rows, index) end
        end
        state.pending, state.keys, state.stale = {}, {}, {}
        prune_originals(state)
        publish(state)
      end
      callback(nil)
    elseif choice == "Save" then
      local function save_next(index)
        if index > #dirty then
          local remaining, busy = dirty_sessions()
          callback(busy or (#remaining > 0 and failure("pending_changed", "New edits remain pending; review before switching profiles") or nil))
          return
        end
        save(dirty[index], function(save_err)
          if save_err then callback(save_err) else save_next(index + 1) end
        end)
      end
      save_next(1)
    else
      callback(failure("switch_cancelled", "Profile switch cancelled; pending edits retained"))
    end
  end)
end

return M
