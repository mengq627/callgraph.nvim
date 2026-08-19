-- Fixed window width stays stable across expand/collapse; the toggle_expand
-- (<Space>) and jump_to_def (<CR>) keymaps are bound in the view buffer.
-- Run: nvim --headless -u NONE -l tests/fixed_width.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

config.set({ show_call_site = false, window = { position = 'right', fixed_width = 40 } })

local U = 'file:///C:/dev/test.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local main = item('main', 32)
local l1a = item('func_l1_a', 20)
local l2a = item('func_l2_a', 9)
local callees = { main = { { l1a, 34 } }, func_l1_a = { { l2a, 22 } }, func_l2_a = {} }
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local list = callees[node.name] or {}
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = { item = e[1], call_site = { uri = U, line = e[2] } } end
    d:resolve(out)
    return d
  end
end

vim.cmd('edit ' .. root .. '/tests/test.c')
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- The view window is the one that is not the original.
local function view_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'nofile' then return w end
  end
end

local win = view_win()
check('window open', win ~= nil)

local w0 = vim.api.nvim_win_get_width(win)
check('initial width is fixed', w0 == 40, 'got ' .. w0)

-- Expand the root (reveals level 2) then collapse; width must not change.
view.toggle_expand()
vim.wait(500, function() return false end)
local w1 = vim.api.nvim_win_get_width(win)
check('width stable after expand', w1 == 40, 'got ' .. w1)

view.toggle_expand()
vim.wait(500, function() return false end)
local w2 = vim.api.nvim_win_get_width(win)
check('width stable after collapse', w2 == 40, 'got ' .. w2)

-- Keymaps bound in the view buffer.
local buf = vim.api.nvim_win_get_buf(win)
local km = config.get().keymaps
local function bound(keys)
  return vim.fn.maparg(keys, 'n', false, true).callback ~= vim.NIL
end
check('toggle_expand keymap bound', bound(km.toggle_expand), km.toggle_expand)
check('jump_to_def keymap bound', bound(km.jump_to_def), km.jump_to_def)
check('close keymap bound', bound(km.close), km.close)

view.close()
print('---')
if failed == 0 then print('FIXED_WIDTH OK') else print('FIXED_WIDTH FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
