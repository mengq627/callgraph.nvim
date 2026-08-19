--- cscope source: query a cscope database for callers / callees.
---
--- Query (line mode, no interactive UI):
---   cscope -dL -2 <func>   # functions called by <func>  (callout)
---   cscope -dL -3 <func>   # functions calling <func>    (callin)
--- Output per line: `file symbol line <call text>`.
---
--- Needs the `cscope` binary and a cscope.out database in the project.
---
--- NOTE: the actual query is implemented in a follow-up commit; for now this
--- provider only detects availability (binary + database) and resolves empty.

local util = require('callgraph.util')

local M = {}

--- Walk up from `dir` looking for `cscope.out`; returns the db path or nil.
function M.find_db(dir)
  dir = dir or vim.fn.getcwd()
  while true do
    local f = vim.fn.fnamemodify(dir .. '/cscope.out', ':p')
    if vim.fn.filereadable(f) == 1 then return f end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then return nil end
    dir = parent
  end
end

--- Is cscope usable right now (binary present + a database exists)?
function M.available(opts)
  if vim.fn.executable('cscope') ~= 1 then return false end
  return M.find_db() ~= nil
end

--- Fetch function for graph building: node, direction -> Deferred(calls).
function M.make_fetch(encoding, client, opts)
  return function(node, direction)
    local d = util.Deferred.new()
    d:resolve({})
    return d
  end
end

return M
