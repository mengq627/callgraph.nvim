-- The source manager caches each symbol's callers/callees per session: in tree
-- mode the same symbol is reached through several call paths (e.g. `leaf`
-- called by both `a` and `b`), so without caching the underlying query would
-- run once per path — and again on every rebuild/expand. This test asserts the
-- underlying LSP/cscope query runs exactly once per symbol+direction, and that
-- clear_cache() forces a fresh fetch.
-- Run: nvim --headless -u NONE -l tests/cache.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local source_mod = require('callgraph.source')

config.set({ show_call_site = false, sources = { 'lsp' } })

local U = 'file:///tmp/t.c'
local function item(name, line)
  return { name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } } }
end

local req = 0
local client = { request = function(method, params, cb)
  req = req + 1
  local out = {}
  local name = params.item.name
  if name == 'main' then
    out = { { to = item('a', 1) }, { to = item('b', 2) } }
  elseif name == 'a' then
    out = { { to = item('leaf', 10) } }
  elseif name == 'b' then
    out = { { to = item('leaf', 10) } }
  end
  cb(nil, out)
end }

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

source_mod.clear_cache() -- isolated from other tests in the same process
local main = item('main', 30)
local make_fetch = source_mod.make_fetch('utf-16', client, config.get())
local g = graph_mod.build(main, 'callout', { max_depth = 3 }, make_fetch).value

local leafs = 0
for _, n in pairs(g.nodes) do if n.name == 'leaf' then leafs = leafs + 1 end end
check('tree: leaf reached twice (a and b paths)', leafs == 2, 'got ' .. leafs)
check('leaf queried once (4 requests: main,a,b,leaf)', req == 4, 'req=' .. req)

-- A second build (and a freshly-created fetch) must reuse the session cache.
local g2 = graph_mod.build(main, 'callout', { max_depth = 3 }, make_fetch).value
check('second build reuses cache (still 4)', req == 4, 'req=' .. req)
local make_fetch2 = source_mod.make_fetch('utf-16', client, config.get())
local g3 = graph_mod.build(main, 'callout', { max_depth = 3 }, make_fetch2).value
check('fresh make_fetch still cached (4)', req == 4, 'req=' .. req)

source_mod.clear_cache()
local g4 = graph_mod.build(main, 'callout', { max_depth = 3 }, make_fetch2).value
check('clear_cache forces re-query (8)', req == 8, 'req=' .. req)

print('---')
if failed == 0 then print('CACHE OK') else print('CACHE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
