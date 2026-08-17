-- Regression: navigating a 4-in-a-row graph must move the selection and land
-- the cursor exactly on each box's text (this was broken by `normal! zt`
-- shifting the column). Run: nvim --headless -u NONE -l tests/repro_move.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local view = require('callgraph.view')

config.set({ show_call_site = true, debug = true, debug_location = true })

local U = 'file:///C:/dev/test.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = U,
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
-- 4 boxes in one row: main -> l1a -> l2a -> l2c
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

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- Expected cursor (row = text row, col = text start) per box after each move,
-- plus the character that must be under the cursor.
-- The tab bar now lives on the native 'tabline', not in the buffer, so the
-- canvas starts at row 1 and all graph text rows are 2.
-- main box col 3, l1a col 24, l2a col 50, l2c col 76 (all text row = 2).
local expected = {
  { 2, 3, 'm' }, -- main
  { 2, 24, 'f' }, -- func_l1_a
  { 2, 50, 'f' }, -- func_l2_a
  { 2, 76, 'f' }, -- func_l2_c
}

local win = vim.api.nvim_get_current_win()
local function cur_char()
  local c = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), c[1] - 1, c[1], false)[1] or ''
  -- nvim_win_get_cursor col is a BYTE index; convert to char index for checks.
  local charcol = util.byte_to_char(line, c[2])
  return c, vim.fn.strcharpart(line, charcol, 1), charcol
end

local cur, ch, charcol = cur_char()
check('initial cursor on main text', cur[1] == expected[1][1] and charcol == expected[1][2], vim.inspect(cur))
check('initial char is "m"', ch == expected[1][3], 'got ' .. vim.inspect(ch))

view.move('right')
vim.wait(200, function() return false end)
cur, ch, charcol = cur_char()
check('move 1 cursor on l1a text', cur[1] == expected[2][1] and charcol == expected[2][2], vim.inspect(cur))
check('move 1 char is "f"', ch == expected[2][3], 'got ' .. vim.inspect(ch))

view.move('right')
vim.wait(200, function() return false end)
cur, ch, charcol = cur_char()
check('move 2 cursor on l2a text', cur[1] == expected[3][1] and charcol == expected[3][2], vim.inspect(cur))
check('move 2 char is "f"', ch == expected[3][3], 'got ' .. vim.inspect(ch))

view.move('right')
vim.wait(200, function() return false end)
cur, ch, charcol = cur_char()
check('move 3 cursor on l2c text', cur[1] == expected[4][1] and charcol == expected[4][2], vim.inspect(cur))
check('move 3 char is "f"', ch == expected[4][3], 'got ' .. vim.inspect(ch))

-- No more boxes to the right: moving right again must not move.
local before = vim.api.nvim_win_get_cursor(win)
view.move('right')
vim.wait(200, function() return false end)
local after = vim.api.nvim_win_get_cursor(win)
check('no move past the last box', before[1] == after[1] and before[2] == after[2])

view.close()
print('---')
if failed == 0 then print('REPRO OK') else print('REPRO FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
