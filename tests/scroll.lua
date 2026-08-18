-- Moving the selection horizontally must scroll the window so the focused
-- box's text is visible even when the graph is wider than the fixed window.
-- Run: nvim --headless -u NONE -l tests/scroll.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local view = require('callgraph.view')

config.set({ show_call_site = false, window = { position = 'right', fixed_width = 15 } })

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
local l2c = item('func_l2_c', 3)
local callees = { main = { { l1a, 34 } }, func_l1_a = { { l2a, 22 } }, func_l2_a = { { l2c, 11 } }, func_l2_c = {} }
lsp_mod.make_fetch = function()
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

local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_win_get_buf(win)
local function char_col()
  local c = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(buf, c[1] - 1, c[1], false)[1] or ''
  return util.byte_to_char(line, c[2])
end
-- winsaveview().leftcol is the window's horizontal scroll position (char col).
local function leftcol()
  return vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
end
-- Is the cursor's character within the window's visible horizontal range?
local function visible_ok()
  local ci = char_col()
  local sc = leftcol()
  local ww = vim.api.nvim_win_get_width(win)
  return ci >= sc and ci < sc + ww
end
-- Columns of empty space between the cursor and the window's right/left edge.
-- A fully-visible box keeps >= margin columns on its trailing side.
local function right_margin()
  return leftcol() + vim.api.nvim_win_get_width(win) - 1 - char_col()
end
local function left_margin()
  return char_col() - leftcol()
end

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

check('window fixed width', vim.api.nvim_win_get_width(win) == 15)

view.move('right'); vim.wait(200, function() return false end)
view.move('right'); vim.wait(200, function() return false end)
view.move('right'); vim.wait(200, function() return false end)
local sc1 = leftcol()
check('scrolled right to reach l2c', sc1 > 0, 'leftcol=' .. sc1)
check('cursor visible after moving right', visible_ok(), 'char=' .. char_col() .. ' leftcol=' .. sc1)
-- Minimal scroll: the box stays toward the right, not dragged to center, and
-- its right edge keeps a margin so it is not clipped.
check('right box keeps margin from right edge', right_margin() >= 2,
  'char=' .. char_col() .. ' leftcol=' .. sc1 .. ' right_margin=' .. right_margin())

view.move('left'); vim.wait(200, function() return false end)
view.move('left'); vim.wait(200, function() return false end)
view.move('left'); vim.wait(200, function() return false end)
local sc2 = leftcol()
check('scrolled back left to main', sc2 < sc1, 'leftcol=' .. sc2)
check('cursor visible after moving left', visible_ok(), 'char=' .. char_col() .. ' leftcol=' .. sc2)
-- Coming back left, the leftmost box's border must not be clipped either.
check('left box border not clipped', left_margin() >= 2,
  'char=' .. char_col() .. ' leftcol=' .. sc2 .. ' left_margin=' .. left_margin())

view.close()
print('---')
if failed == 0 then print('SCROLL OK') else print('SCROLL FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
