local M = {}
local Client = require("better_sql.client")
local table_view = require("better_sql.table")

local client, profile, last_profile, catalog
local loading, load_error = false, nil
local connect_generation, catalog_generation = 0, 0
local pending_connect, pending_refresh
local listeners = {}

local function error_value(code, message)
  return { code = code, message = message }
end

local function helper_error()
  return error_value("helper_exited", "Helper disconnected during connection setup; run :BetterSqlReconnect")
end

function M.get_catalog()
  return catalog and vim.deepcopy(catalog) or nil
end

function M.snapshot()
  return { client = client, profile = profile, catalog = M.get_catalog(), loading = loading, error = load_error }
end

function M.subscribe(callback)
  listeners[#listeners + 1] = callback
end

local function publish()
  for _, listener in ipairs(listeners) do
    local ok = pcall(listener, M.snapshot())
    if not ok then vim.notify("Could not update the SQL connection view", vim.log.levels.ERROR) end
  end
end

local function complete(operation, err, result)
  if operation.completed then return end
  operation.completed = true
  if pending_connect == operation then pending_connect = nil end
  if pending_refresh == operation then pending_refresh = nil end
  if operation.client and not operation.activated then operation.client:stop() end
  local ok = pcall(operation.callback, err, result)
  if not ok then vim.notify("A SQL connection callback failed", vim.log.levels.ERROR) end
end

local function invalidate_refresh()
  catalog_generation = catalog_generation + 1
  local obsolete = pending_refresh
  pending_refresh = nil
  return obsolete
end

local function superseded_catalog()
  return error_value("catalog_superseded", "schema refresh was superseded")
end

function M.connect(name, config, callback)
  callback = callback or function() end
  local conninfo = config.connections[name]
  if type(conninfo) ~= "string" or conninfo == "" then
    callback(error_value("unknown_profile", "connection profile was not found"), nil)
    return
  end
  connect_generation = connect_generation + 1
  local operation = { callback = callback, generation = connect_generation }
  local previous_attempt = pending_connect
  pending_connect = operation
  if previous_attempt then
    complete(previous_attempt, error_value("connect_superseded", "connection attempt was superseded"), nil)
  end

  local function connection_error(err)
    if operation.generation ~= connect_generation then
      return error_value("connect_superseded", "connection attempt was superseded")
    end
    if err then return err end
    if operation.client and not operation.client:is_running() then return helper_error() end
  end

  local function begin(switch_error)
    if operation.completed or operation.started then return end
    local err = connection_error(switch_error)
    if err then complete(operation, err, nil); return end
    operation.started = true
    local candidate = Client.new({ python = config.python })
    operation.client = candidate
    local started = pcall(candidate.start, candidate, function(_, exit_error, intentional)
      local was_active = client == candidate
      local obsolete
      if was_active then
        client, profile, catalog = nil, nil, nil
        loading, load_error = false, nil
        obsolete = invalidate_refresh()
        publish()
      end
      table_view.disconnect(candidate)
      if not operation.completed then complete(operation, connection_error(exit_error) or helper_error(), nil) end
      if obsolete then complete(obsolete, exit_error or helper_error(), nil) end
      if was_active and not intentional then
        vim.notify((exit_error and exit_error.message) or "Helper disconnected; run :BetterSqlReconnect", vim.log.levels.ERROR)
      end
    end)
    if not started then
      complete(operation, error_value("helper_start_failed", "Could not start the SQL helper; check the configured Python and helper installation"), nil)
      return
    end
    if operation.completed then return end
    candidate:request("connect", { conninfo = conninfo }, function(connect_error, result)
      if operation.completed then return end
      connect_error = connection_error(connect_error)
      if connect_error then complete(operation, connect_error, nil); return end
      candidate:request("catalog.load", {}, function(catalog_error, initial_catalog)
        if operation.completed then return end
        catalog_error = connection_error(catalog_error)
        if catalog_error then complete(operation, catalog_error, nil); return end
        local function activate(guard_error)
          if operation.completed then return end
          guard_error = connection_error(guard_error)
          if guard_error then complete(operation, guard_error, nil); return end
          local previous = client
          operation.activated = true
          client, profile, last_profile = candidate, name, name
          catalog = initial_catalog and vim.deepcopy(initial_catalog) or nil
          loading, load_error = false, nil
          local obsolete = invalidate_refresh()
          publish()
          if client == candidate then table_view.set_connection(candidate, name) end
          if previous then previous:stop() end
          if obsolete then complete(obsolete, superseded_catalog(), nil) end
          complete(operation, nil, result)
        end
        -- Recheck edits made while the candidate connected and loaded schema.
        if last_profile and last_profile ~= name then table_view.before_switch(activate) else activate(nil) end
      end)
    end)
  end
  if last_profile and last_profile ~= name then table_view.before_switch(begin) else begin(nil) end
end

function M.reconnect(config, callback)
  callback = callback or function(err)
    if err then vim.notify(err.message, vim.log.levels.ERROR) end
  end
  if not last_profile then
    callback(error_value("not_connected", "Choose a profile with :BetterSqlConnect first"), nil)
    return
  end
  M.connect(last_profile, config, callback)
end

function M.refresh_schema(callback)
  callback = callback or function() end
  if not client then
    callback(error_value("not_connected", "Connect to a PostgreSQL profile first"), nil)
    return
  end
  catalog_generation = catalog_generation + 1
  local operation = { callback = callback, generation = catalog_generation, source = client }
  local previous = pending_refresh
  pending_refresh = operation
  loading, load_error = true, nil
  if previous then complete(previous, superseded_catalog(), nil) end
  if operation.completed then return end
  publish()
  operation.source:request("catalog.load", {}, function(err, value)
    if operation.completed then return end
    if client ~= operation.source or operation.generation ~= catalog_generation then
      complete(operation, superseded_catalog(), nil)
      return
    end
    loading, load_error = false, err
    if not err then catalog = value and vim.deepcopy(value) or nil end
    publish()
    complete(operation, err, value)
  end)
end

return M
