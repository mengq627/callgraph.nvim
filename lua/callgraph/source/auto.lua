--- Heuristic single-file source ("auto"): scan function bodies for call
--- tokens (callout) or references + documentSymbol (callin). Single-file only —
--- it cannot resolve cross-file calls, so it is best used as a last fallback
--- behind `lsp` / `cscope`.

local fallback_mod = require('callgraph.fallback')
local lsp_mod = require('callgraph.lsp')

local M = {}

-- Always available (needs no external binary or index).
function M.available(opts)
  return true
end

function M.make_fetch(encoding, client, opts)
  -- inject the documentSymbol resolvers (avoids a circular require)
  return fallback_mod.make_fetch(client, encoding, lsp_mod.enclosing_function_at, lsp_mod.find_functions_by_name)
end

return M
