-- Headless smoke test for callgraph.nvim core (graph / layout / render).
-- Run from the repo root:
--   nvim --headless -u NONE -l tests/smoke.lua
-- Uses a fake synchronous call-hierarchy fetch, so no LSP server is needed.

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')

config.set({ show_call_site = false })

local failed = 0
local function check(name, cond, detail)
  if cond then
    print('PASS ' .. name)
  else
    failed = failed + 1
    print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or ''))
  end
end

local U = 'file:///tmp/test.c'
local function item(name, line)
  return {
    name = name,
    kind = 12,
    uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end

local main = item('main', 27)
local l1a = item('func_l1_a', 3)
local l1b = item('func_l1_b', 9)
local l2a = item('func_l2_a', 13)
local l2b = item('func_l2_b', 17)
local l2c = item('func_l2_c', 21)

-- Mirrors test.c: main -> l1a/l1b -> l2a/l2b -> l2c (diamond on l2c).
local callees = {
  main = { { l1a, 29 }, { l1b, 30 } },
  func_l1_a = { { l2a, 5 } },
  func_l1_b = { { l2b, 12 } },
  func_l2_a = { { l2c, 15 } },
  func_l2_b = { { l2c, 20 } },
  func_l2_c = {},
}
local callers = {
  func_l2_c = { { l2a, 15 }, { l2b, 20 } },
  func_l2_a = { { l1a, 5 } },
  func_l2_b = { { l1b, 12 } },
  func_l1_a = { { main, 29 } },
  func_l1_b = { { main, 30 } },
  main = {},
}

local function make_fetch(map)
  return function(node, direction)
    local d = util.Deferred.new()
    local list = map[node.name] or {}
    local out = {}
    for _, e in ipairs(list) do
      out[#out + 1] = { item = e[1], call_site = { uri = U, line = e[2] } }
    end
    d:resolve(out)
    return d
  end
end

local nid = graph_mod.node_id
local opts = config.get()

-- ---- Test 1: build callout, dedup, min-depth placement
local g = graph_mod.build(main, 'callout', { max_depth = 4 }, make_fetch(callees)).value
check('build resolves', g ~= nil)
if g then
  check('6 nodes (dedup)', vim.tbl_count(g.nodes) == 6)
  local n = g.nodes[nid(l2c)]
  check('l2_c exists once', n ~= nil)
  check('l2_c min depth 3', n and n.depth == 3)
  check('l2_c has 2 parents (diamond)', n and #n.parents == 2)
  check('no cycle nodes in diamond', (function()
    for _, x in pairs(g.nodes) do if x.is_cycle then return false end end
    return true
  end)())
end

-- ---- Test 2: cycle handling (x -> y -> x)
local X = item('x', 0)
local Y = item('y', 10)
local cyc_callees = { x = { { Y, 1 } }, y = { { X, 11 } } }
local g2 = graph_mod.build(X, 'callout', { max_depth = 4 }, make_fetch(cyc_callees)).value
local cyc = nil
if g2 then
  for _, n in pairs(g2.nodes) do
    if n.is_cycle and n.name == 'x' then cyc = n end
  end
end
check('cycle terminal created', cyc ~= nil)
check('cycle terminal is a leaf', cyc and not cyc.has_children)

-- ---- Test 3: layout (callout)
local lay = layout_mod.layout(g, opts, { direction = 'callout', selected_id = nid(main) })
check('layout has 6 boxes', vim.tbl_count(lay.boxes) == 6)
check('l2_c right of l1_a', lay.boxes[nid(l2c)].col > lay.boxes[nid(l1a)].col)
check('l1_a/l1_b same column', lay.boxes[nid(l1a)].col == lay.boxes[nid(l1b)].col)
local function overlaps(a, b)
  return a.row < b.row + b.height and b.row < a.row + a.height
    and a.col < b.col + b.width and b.col < a.col + a.width
end
local ids = {}
for id in pairs(lay.boxes) do ids[#ids + 1] = id end
local overlap = false
for i = 1, #ids do
  for j = i + 1, #ids do
    if overlaps(lay.boxes[ids[i]], lay.boxes[ids[j]]) then overlap = true end
  end
end
check('no box overlap', not overlap)
check('edges routed (>=5)', #lay.edges >= 5)

-- ---- Test 4: render (callout + cycle)
local buf = vim.api.nvim_create_buf(false, true)
render_mod.render(buf, lay, g, { selected_id = nid(main), highlights = config.get().highlights })
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
check('name main rendered', text:find('main') ~= nil)
check('box border rendered', text:find('─') ~= nil)
check('arrow rendered', text:find('>') ~= nil)

local lay2 = layout_mod.layout(g2, opts, { direction = 'callout', selected_id = nid(X) })
render_mod.render(buf, lay2, g2, { selected_id = nid(X), highlights = config.get().highlights })
local text2 = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
check('cycle glyph rendered', text2:find('⟳') ~= nil)

-- ---- Test 5: callin is a mirror (root rightmost)
local gci = graph_mod.build(l2c, 'callin', { max_depth = 4 }, make_fetch(callers)).value
local layci = layout_mod.layout(gci, opts, { direction = 'callin', selected_id = nid(l2c) })
check('callin root rightmost', layci.boxes[nid(l2c)].col > layci.boxes[nid(main)].col)
check('callin l2_a at depth 1', gci.nodes[nid(l2a)].depth == 1)
check('callin main at depth 3', gci.nodes[nid(main)].depth == 3)

-- ---- Test 6: depth limit + expand/collapse toggle
local g3 = graph_mod.build(main, 'callout', { max_depth = 1 }, make_fetch(callees)).value
check('depth1: l1_a has children', g3.nodes[nid(l1a)].has_children == true)
check('depth1: l2_a hidden', g3.nodes[nid(l2a)].visible == false)
check('depth1: max_visible_depth == 1', g3.max_visible_depth == 1)
local g4 = graph_mod.expand(g3, g3.nodes[nid(l1a)], make_fetch(callees)).value
check('expand reveals l2_a', g4 and g4.nodes[nid(l2a)].visible == true)
local g5 = graph_mod.expand(g4, g4.nodes[nid(l1a)], make_fetch(callees)).value
check('collapse hides l2_a', g5 and g5.nodes[nid(l2a)].visible == false)

print('---')
if failed == 0 then
  print('SMOKE OK')
else
  print('SMOKE FAILED: ' .. failed .. ' failure(s)')
end
os.exit(failed == 0 and 0 or 1)
