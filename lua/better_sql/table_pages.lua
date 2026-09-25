-- A helper's row-handle store is shared by all grids on its connection.
local M = {}
local queues = {}

local function drain(queue, err)
  queue.closed = true
  if queues[queue.client] == queue then queues[queue.client] = nil end
  local waiting = queue.waiting
  queue.waiting = {}
  for _, request in ipairs(waiting) do request.callback(err) end
end

local function run_next(queue)
  if queue.running or queue.closed then return end
  local request = table.remove(queue.waiting, 1)
  if not request then
    queues[queue.client] = nil
    return
  end
  -- Preparation reads the grids only when this request reaches the front.
  local params = request.prepare()
  if not params then run_next(queue); return end
  queue.running = true
  queue.client:request("table.page", params, function(err, page)
    request.callback(err, page)
    queue.running = false
    if err and err.code == "helper_exited" then
      drain(queue, err)
    else
      run_next(queue)
    end
  end)
end

function M.request(client, prepare, callback)
  local queue = queues[client]
  if not queue then
    queue = { client = client, waiting = {}, running = false, closed = false }
    queues[client] = queue
  end
  queue.waiting[#queue.waiting + 1] = { prepare = prepare, callback = callback }
  run_next(queue)
end

function M.disconnect(client)
  local queue = queues[client]
  if queue then
    drain(queue, { code = "helper_exited", message = "helper process exited" })
  end
end

return M
