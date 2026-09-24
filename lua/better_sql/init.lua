local M = {}

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

return M
