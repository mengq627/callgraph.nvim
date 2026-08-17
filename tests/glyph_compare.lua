-- Generates comparison files (tests/glyphs/*.txt) of the same callgraph drawn
-- with different arrowhead glyph sets, including a same-column edge so both
-- horizontal and vertical arrows are visible.
-- Open the files in Neovim (with your Nerd Font terminal) and pick the best.
-- Run: nvim --headless -u NONE -l tests/glyph_compare.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local util = require('callgraph.util')
local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')

config.set({ show_call_site = true })

local U = 'file:///tmp/diamond.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
-- Diamond: main -> a, main -> b, a -> b (same-column edge -> vertical arrow).
local main2 = item('main', 20)
local A = item('func_a', 0)
local B = item('func_b', 10)
local callees = { main = { { A, 1 }, { B, 2 } }, func_a = { { B, 3 } }, func_b = {} }
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

local g = graph_mod.build(main2, 'callout', { max_depth = 4 }, make_fetch(callees)).value
local opts = config.get()

local candidates = {
  { name = '01_unicode_shaft', arrows = { right = '→', down = '↓', up = '↑', left = '←' } }, -- 参考：Unicode 带杆
  { name = '02_nf_long_arrow', arrows = { right = '', down = '', up = '', left = '' } }, -- FA long arrows（杆细）
  { name = '03_nf_fontawesome', arrows = { right = '', down = '', up = '', left = '' } }, -- FA 实心（粗但有空隙）
  { name = '04_heavy_classic', arrows = { right = '➡', down = '⬇', up = '⬆', left = '⬅' } }, -- 经典重型
  { name = '05_heavy_wide', arrows = { right = '➔', down = '⬇', up = '⬆', left = '⬅' } }, -- 宽头重型
  { name = '06_nf_chevron', arrows = { right = '', down = '', up = '', left = '' } }, -- FA 粗 chevron
}

local outdir = root .. '/tests/glyphs'
vim.fn.mkdir(outdir, 'p')

for _, cand in ipairs(candidates) do
  local lay = layout_mod.layout(g, opts, { direction = 'callout', selected_id = graph_mod.node_id(main2) })
  local buf = vim.api.nvim_create_buf(false, true)
  render_mod.render(buf, lay, g, {
    selected_id = graph_mod.node_id(main2),
    highlight = false,
    highlights = opts.highlights,
    arrows = cand.arrows,
  })
  local content = { 'arrow set: ' .. cand.arrows.right .. ' ' .. cand.arrows.down .. ' ' .. cand.arrows.up .. ' ' .. cand.arrows.left }
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do content[#content + 1] = l end
  vim.fn.writefile(content, outdir .. '/' .. cand.name .. '.txt')
  print('wrote ' .. cand.name .. '.txt')
end
os.exit(0)
