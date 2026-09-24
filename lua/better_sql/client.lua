local Client = {}
Client.__index = Client

function Client.new(options)
  options = options or {}
  return setmetatable({
    python = options.python or "python3",
    helper = options.helper,
    next_id = 0,
    callbacks = {},
    stdout_buffer = "",
  }, Client)
end

function Client:_fail_pending(err)
  local pending = self.callbacks
  self.callbacks = {}
  vim.schedule(function()
    local ids = vim.tbl_keys(pending)
    table.sort(ids)
    for _, id in ipairs(ids) do
      pending[id](err, nil)
    end
  end)
end

function Client:_invalid_response()
  self.failure = { code = "invalid_response",
    message = "Helper returned invalid JSON protocol output; check the configured Python/helper and run :BetterSqlReconnect" }
  self:_fail_pending(self.failure)
  if self.process then
    self.stopping = true
    self.process:kill(15)
  end
end

function Client:_on_stderr(chunk)
  if not chunk then return end
  -- Inspect bounded stderr privately, but never echo arbitrary interpreter output:
  -- it can include source lines, conninfo, and passwords from tracebacks.
  self.stderr_buffer = ((self.stderr_buffer or "") .. chunk):sub(-8192)
  if self.stderr_buffer:find("ModuleNotFoundError", 1, true) then
    self.stderr_hint = "Python dependency missing; install psycopg in the configured Python environment"
  elseif self.stderr_buffer:find("SyntaxError", 1, true) then
    self.stderr_hint = "Python could not parse the helper; check the configured Python version and helper installation"
  else
    self.stderr_hint = "Helper reported an error on stderr; check the configured Python environment and helper installation"
  end
end

function Client:_on_stdout(chunk)
  if not chunk then
    return
  end

  self.stdout_buffer = self.stdout_buffer .. chunk
  while true do
    local newline = self.stdout_buffer:find("\n", 1, true)
    if not newline then
      return
    end

    local line = self.stdout_buffer:sub(1, newline - 1)
    self.stdout_buffer = self.stdout_buffer:sub(newline + 1)
    local decoded, response = pcall(vim.json.decode, line)
    if not decoded or type(response) ~= "table" or type(response.id) ~= "number"
      or type(response.ok) ~= "boolean"
      or (not response.ok and (type(response.error) ~= "table"
        or type(response.error.message) ~= "string" or type(response.error.code) ~= "string")) then
      self:_invalid_response()
      return
    end
    local callback = self.callbacks[response.id]
    if callback then
      vim.schedule(function()
        -- Keep parsed replies pending until delivery, so exit can fail them.
        if self.callbacks[response.id] ~= callback then return end
        self.callbacks[response.id] = nil
        if response.ok then
          callback(nil, response.result)
        else
          callback(response.error, nil)
        end
      end)
    end
  end
end

function Client:start(on_exit)
  assert(not self.process, "better_sql helper is already running")
  local helper = self.helper or vim.api.nvim_get_runtime_file("python/better_sql_helper.py", false)[1]
  assert(helper, "better_sql helper was not found on runtimepath")
  self.stdout_buffer = ""
  self.stderr_buffer, self.stderr_hint, self.failure = "", nil, nil
  self.process = vim.system({ self.python, "-u", helper }, {
    stdin = true,
    stdout = function(_, chunk)
      self:_on_stdout(chunk)
    end,
    stderr = function(_, chunk) self:_on_stderr(chunk) end,
  }, function(result)
    local intentional = self.stopping and not self.failure
    self.process = nil
    self.stopping = false
    local detail = self.stderr_hint or ("Helper exited with status " .. tostring(result.code)
      .. " and signal " .. tostring(result.signal))
    local err = self.failure or { code = "helper_exited",
      message = detail .. "; run :BetterSqlReconnect" }
    if self.stdout_buffer ~= "" and not self.failure then
      err = { code = "invalid_response", message = "Helper exited with incomplete JSON output; run :BetterSqlReconnect" }
    end
    self.stderr_buffer = ""
    self:_fail_pending(err)
    vim.schedule(function()
      if on_exit then
        on_exit(result, err, intentional)
      end
    end)
  end)
end

function Client:request(method, params, callback)
  assert(self.process and not self.stopping, "better_sql helper is not running")
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.callbacks[id] = callback
  local request_params = params or {}
  if next(request_params) == nil then
    request_params = vim.empty_dict()
  end
  self.process:write(vim.json.encode({ id = id, method = method, params = request_params }) .. "\n")
  return id
end

function Client:cancel(target_id, callback)
  return self:request("query.cancel", { target_id = target_id }, callback or function() end)
end

function Client:stop()
  if self.process and not self.stopping then
    self.stopping = true
    self.process:kill(15)
  end
end

return Client
