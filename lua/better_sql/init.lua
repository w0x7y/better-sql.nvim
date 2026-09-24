local M = {}
local Client = require("better_sql.client")

function M.setup(options)
  options = options or {}
  M.config = {
    connections = options.connections or {},
    python = options.python or "python3",
    max_rows = options.max_rows or 1000,
    max_bytes = options.max_bytes or 4194304,
  }
end

M.setup()

function M.connect(name, callback)
  callback = callback or function() end
  local conninfo = M.config.connections[name]
  if type(conninfo) ~= "string" or conninfo == "" then
    callback({ code = "unknown_profile", message = "connection profile was not found" }, nil)
    return
  end

  local client = Client.new({ python = M.config.python })
  client:start(function()
    if M.client == client then
      M.client = nil
      M.active_profile = nil
    end
  end)
  client:request("connect", { conninfo = conninfo }, function(err, result)
    if err then
      client:stop()
      callback(err, nil)
      return
    end
    local previous = M.client
    M.client = client
    M.active_profile = name
    if previous then
      previous:stop()
    end
    callback(nil, result)
  end)
end

return M
