-- Multiple-definition handling: a cscope name resolving to several definitions
-- must expand only against the chosen definition's file. Verifies graph.rebuild
-- + the view's filtered-fetch semantics (kept local here since the real one is
-- a closure inside view.lua).
-- Run: nvim --headless -u NONE -l tests/multidef.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local util = require('callgraph.util')
local graph_mod = require('callgraph.graph')

local srcA = vim.uri_from_fname(root .. '/tests/a.c')
local srcB = vim.uri_from_fname(root .. '/tests/b.c')

local function item(name, uri, line)
  return {
    name = name, kind = 12, uri = uri,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end

-- Fetch for a function `X` defined in both a.c and b.c: its call sites are a
-- mix of fileA (foo, baz) and fileB (bar) — exactly the multi-definition case.
local mixed = {
  { item('foo', srcA, 10), srcA },
  { item('bar', srcB, 20), srcB },
  { item('baz', srcA, 30), srcA },
}
local function make_fetch(calls)
  return function(node, direction)
    local d = util.Deferred.new()
    local out = {}
    for _, c in ipairs(calls) do
      out[#out + 1] = { item = c[1], call_site = { uri = c[2], line = c[1].range.start.line } }
    end
    d:resolve(out)
    return d
  end
end

-- The view's filtered_fetch: keep only calls in the chosen definition's file.
local function filtered_fetch(fetch, def)
  return function(node, direction)
    local dd = fetch(node, direction)
    local out = util.Deferred.new()
    dd:next(function(calls)
      local kept = {}
      for _, c in ipairs(calls) do
        if c.call_site and c.call_site.uri == def.uri then kept[#kept + 1] = c end
      end
      out:resolve(kept)
    end)
    return out
  end
end

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

local root_item = item('X', vim.uri_from_fname(root .. '/tests/x.c'), 1)
graph_mod.build(root_item, 'callout', { max_depth = 3 }, make_fetch(mixed)):next(function(g)
  local r = g.root
  check('build keeps mixed call sites', #r.children == 3, tostring(#r.children))

  -- User picks the a.c definition (as toggle_expand's picker callback does).
  r.chosen_def = { uri = srcA, line = 1 }
  graph_mod.rebuild(g, r, filtered_fetch(make_fetch(mixed), r.chosen_def)):next(function(g2)
    local kids = g2.root.children
    local names, all_a = {}, true
    for _, cid in ipairs(kids) do
      local c = g2.nodes[cid]
      names[#names + 1] = c.name
      if c.call_site and c.call_site.uri ~= srcA then all_a = false end
    end
    table.sort(names)
    check('rebuilt keeps only chosen-definition calls', #kids == 2 and all_a,
      table.concat(names, ', ') .. ' / ' .. tostring(#kids))
    check('bar (fileB) dropped', #kids == 2 and names[1] == 'baz' and names[2] == 'foo',
      table.concat(names, ', '))

    -- Idempotence: rebuilding again with the same choice yields the same set.
    graph_mod.rebuild(g2, g2.root, filtered_fetch(make_fetch(mixed), g2.root.chosen_def)):next(function(g3)
      check('second rebuild identical', #g3.root.children == 2)
      os.exit(failed == 0 and 0 or 1)
    end)
  end, function(e)
    print('FAIL rebuild: ' .. tostring(e)); os.exit(1)
  end)
end, function(e)
  print('FAIL build: ' .. tostring(e)); os.exit(1)
end)

vim.wait(5000, function() return false end)
print('TIMEOUT')
os.exit(1)
