--- Decoupled debug logging.
---
--- Master switch `debug` plus per-area switches `debug_<area>`. A log line is
--- emitted only when BOTH the master and the area switch are on, so enabling
--- one area never affects the others. When the master is off, `M.log` returns
--- immediately and no debug work happens.
---
--- Areas: location (layout/box/cursor geometry), move (selection navigation),
--- graph (graph building), fetch (LSP data acquisition), render.

local config = require('callgraph.config')

local M = {}

-- Accumulated log lines for the current session (used by tests / inspection).
M.buffer = {}

local log_path = nil

--- Path to the debug log file (stdpath('log')/callgraph.log).
function M.log_path()
  if not log_path then
    local dir = vim.fn.stdpath('log')
    vim.fn.mkdir(dir, 'p')
    log_path = dir .. '/callgraph.log'
  end
  return log_path
end

--- Open the debug log file in a new buffer (for `:CallgraphLog`).
function M.open_log()
  vim.cmd('edit ' .. M.log_path())
end

function M.enabled(area)
  local opts = config.get()
  return opts.debug == true and opts['debug_' .. area] == true
end

--- Emit a log line for `area` if enabled. Values are stringified; tables are
--- inspected. The line goes to a file (stable) and to vim.print (visible in
--- headless / :messages).
function M.log(area, ...)
  if not M.enabled(area) then return end
  local parts = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    parts[i] = (type(v) == 'string') and v or vim.inspect(v)
  end
  local line = '[callgraph:' .. area .. '] ' .. table.concat(parts, ' ')
  M.buffer[#M.buffer + 1] = line
  pcall(vim.fn.writefile, { line }, M.log_path(), 'a')
  vim.print(line)
end

function M.clear()
  M.buffer = {}
end

return M
