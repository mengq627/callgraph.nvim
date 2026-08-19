--- ctags source: reserved. Not implemented yet — available() returns false so
--- the manager never picks it. A future implementation can query a tags file
--- (`ctags` on C/C++ provides function definitions but call relationships are
--- weaker than cscope).

local util = require('callgraph.util')

local M = {}

function M.available(opts)
  return false -- not implemented yet
end

function M.make_fetch(encoding, client, opts)
  return function(node, direction)
    local d = util.Deferred.new()
    d:resolve({})
    return d
  end
end

return M
