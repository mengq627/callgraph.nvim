-- Dump the rendered canvas cell-by-cell: box positions, per-cell highlight
-- group, and the move() candidate search. Diagnostic for highlight bugs.
-- Run: nvim --headless -u NONE -l tests/inspect_render.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')

config.set({ show_call_site = true })

local U = 'file:///C:/dev/test.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
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
local callees = {
  main = { { l1a, 29 }, { l1b, 30 } },
  func_l1_a = { { l2a, 5 } },
  func_l1_b = { { l2b, 12 } },
  func_l2_a = { { l2c, 15 } },
  func_l2_b = { { l2c, 20 } },
  func_l2_c = {},
}
local function make_fetch(map)
  return function(node, direction)
    local d = util.Deferred.new()
    local list = map[node.name] or {}
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = { item = e[1], call_site = { uri = U, line = e[2] } } end
    d:resolve(out)
    return d
  end
end

local g = graph_mod.build(main, 'callout', { max_depth = 4 }, make_fetch(callees)).value
local opts = config.get()
local sel = graph_mod.node_id(main)
local lay = layout_mod.layout(g, opts, { direction = 'callout', selected_id = sel })
local buf = vim.api.nvim_create_buf(false, true)
render_mod.render(buf, lay, g, { selected_id = sel, highlight = true, highlights = opts.highlights })

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print('--- canvas (' .. lay.width .. 'x' .. lay.height .. ') ---')
for _, l in ipairs(lines) do print('|' .. l .. '|') end

print('--- boxes ---')
for id, b in pairs(lay.boxes) do
  print(string.format('%s row=%d col=%d w=%d text=%q', id:match('([^%z]+)$') or id, b.row, b.col, b.width, b.text))
end

-- Build per-cell highlight map
local hlmap = {}
local em = vim.api.nvim_buf_get_extmarks(buf, render_mod.ns, 0, -1, { details = true })
print('--- raw extmark count:', #em, '---')
for i = 1, math.min(#em, 8) do
  local e = em[i]
  print('  extmark', i, 'row', e[2], 'col', e[3], 'details', vim.inspect(e[4]))
end
for _, e in ipairs(em) do
  local r0, c0 = e[2], e[3]
  local det = e[4]
  local r1, c1 = det.end_row or r0, det.end_col or (c0 + 1)
  -- end_row is exclusive; when it equals start_row the mark covers just that row.
  local last_r = (r1 > r0) and (r1 - 1) or r0
  for rr = r0, last_r do
    for cc = c0, c1 - 1 do
      hlmap[rr .. ',' .. cc] = det.hl_group
    end
  end
end

print('--- chars + highlight (aligned; G=focus, g=box, e=edge, .=none) ---')
local function hmark(h)
  if h == 'CallgraphFocus' then return 'G'
  elseif h == 'CallgraphBox' then return 'g'
  elseif h == 'CallgraphEdge' then return 'e'
  elseif h == 'CallgraphCycle' then return 'r'
  end
  return '.'
end
for rr = 0, #lines - 1 do
  local chars, marks = {}, {}
  for cc = 1, #lines[rr + 1] do
    chars[cc] = lines[rr + 1]:sub(cc, cc)
    marks[cc] = hmark(hlmap[rr .. ',' .. (cc - 1)])
  end
  print(string.format('%2d |%s|', rr + 1, table.concat(chars)))
  print('   |' .. table.concat(marks) .. '|')
end

-- Simulate move() from the selected (root) box in each direction
local selbox = lay.boxes[sel]
local fc, fr = selbox.col + selbox.width / 2, selbox.row + 1
local dirs = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
for name, d in pairs(dirs) do
  local dx, dy = d[1], d[2]
  local best, best_score
  for id, b in pairs(lay.boxes) do
    if id ~= sel then
      local bc, br = b.col + b.width / 2, b.row + 1
      local dc, dr = bc - fc, br - fr
      local in_half = (dx < 0 and dc < -0.1) or (dx > 0 and dc > 0.1) or (dy < 0 and dr < -0.1) or (dy > 0 and dr > 0.1)
      if in_half then
        local score = dx ~= 0 and (math.abs(dc) + math.abs(dr) * 0.4) or (math.abs(dr) + math.abs(dc) * 0.4)
        if not best_score or score < best_score then best, best_score = id, score end
      end
    end
  end
  print(('move %-6s -> %s'):format(name, best and best:match('([^%z]+)$') or 'nil'))
end

print('total boxes =', vim.tbl_count(lay.boxes))
os.exit(0)
