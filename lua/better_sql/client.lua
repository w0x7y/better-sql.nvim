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
    if decoded and type(response) == "table" then
      local callback = self.callbacks[response.id]
      if callback then
        self.callbacks[response.id] = nil
        vim.schedule(function()
          if response.ok then
            callback(nil, response.result)
          else
            callback(response.error, nil)
          end
        end)
      end
    end
  end
end

function Client:start(on_exit)
  assert(not self.process, "better_sql helper is already running")
  local helper = self.helper or vim.api.nvim_get_runtime_file("python/better_sql_helper.py", false)[1]
  assert(helper, "better_sql helper was not found on runtimepath")
  self.stdout_buffer = ""
  self.process = vim.system({ self.python, "-u", helper }, {
    stdin = true,
    stdout = function(_, chunk)
      self:_on_stdout(chunk)
    end,
    stderr = function() end,
  }, function(result)
    self.process = nil
    self.stopping = false
    local pending = self.callbacks
    self.callbacks = {}
    vim.schedule(function()
      local ids = vim.tbl_keys(pending)
      table.sort(ids)
      for _, id in ipairs(ids) do
        pending[id]({ code = "helper_exited", message = "helper process exited" }, nil)
      end
      if on_exit then
        on_exit(result)
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

function Client:stop()
  if self.process and not self.stopping then
    self.stopping = true
    self.process:write(nil)
  end
end

return Client
