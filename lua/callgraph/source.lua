--- Call-graph source manager.
---
--- A "source" is one way to answer "who calls X / what does X call":
---   lsp / auto / cscope / ctags (see config `sources`). The manager:
---   1. checks which sources are actually available on this machine and caches
---      the result (so per-query lookups never re-probe the environment),
---   2. resolves the root function (currently via LSP),
---   3. builds a combined fetch that tries sources in the configured priority
---      order and returns the first non-empty result (a source resolves empty
---      to fall through, e.g. lsp when the server lacks outgoingCalls).

local util = require('callgraph.util')
local lsp_mod = require('callgraph.lsp')

local M = {}

local avail = {} -- source name -> boolean
local fetch_cache = {} -- symbol_id..'\0'..direction -> calls (session-level)

local providers = {
  lsp = require('callgraph.source.lsp'),
  auto = require('callgraph.source.auto'),
  cscope = require('callgraph.source.cscope'),
  ctags = require('callgraph.source.ctags'),
}

function M.provider(name)
  return providers[name]
end

--- Is `name` usable right now? Checks once and caches.
function M.is_available(name, opts)
  if avail[name] == nil then
    local p = providers[name]
    avail[name] = p and p.available and p.available(opts) or false
  end
  return avail[name]
end

--- Probe every configured source and cache the availability (cheap checks:
--- executables + index files; no per-query cost after this).
function M.check_available(opts)
  for _, name in ipairs(opts.sources or {}) do
    M.is_available(name, opts)
  end
end

--- The enabled sources, in configured priority order.
function M.active_sources(opts)
  local out = {}
  for _, name in ipairs(opts.sources or {}) do
    if M.is_available(name, opts) then out[#out + 1] = name end
  end
  return out
end

--- Combined fetch: try each enabled source in priority order and take the
--- first non-empty result. Deferred resolves to `{ { item, call_site }, ... }`.
function M.make_fetch(encoding, client, opts)
  local fetchers = {}
  for _, name in ipairs(M.active_sources(opts)) do
    local p = providers[name]
    if p.make_fetch then fetchers[#fetchers + 1] = p.make_fetch(encoding, client, opts) end
  end
  return function(node, direction)
    -- Session-level cache: in tree mode the same symbol is reached through
    -- several call paths, so without caching it would be re-queried once per
    -- path — and again on every rebuild/expand. Key by symbol id + direction so
    -- each symbol's callers/callees are fetched only once per session, for every
    -- source (cscope, LSP, auto).
    local key = (node.symbol_id or node.name or '?') .. '\0' .. direction
    local cached = fetch_cache[key]
    if cached ~= nil then
      local d = util.Deferred.new()
      d:resolve(cached)
      return d
    end
    local d = util.Deferred.new()
    util.async_start(function()
      local result = {}
      for _, f in ipairs(fetchers) do
        local ok, calls = pcall(function() return util.await(f(node, direction)) end)
        if ok and calls and #calls > 0 then
          result = calls
          break
        end
      end
      fetch_cache[key] = result
      d:resolve(result)
    end)
    return d
  end
end

--- Clear the session-level query cache (e.g. after external index changes).
function M.clear_cache()
  fetch_cache = {}
end

--- Resolve the "current function" root. Currently delegates to the LSP adapter
--- (prepareCallHierarchy, falling back to the enclosing documentSymbol).
function M.resolve_root(bufnr, opts)
  return lsp_mod.resolve_root(bufnr)
end

return M
