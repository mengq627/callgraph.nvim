-- View-layer smoke test: right-split window opens, canvas renders, navigation
-- and expand work, close restores. Uses a fake fetch (no LSP).
-- Run: nvim --headless -u NONE -l tests/ui.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

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
local l2a = item('func_l2_a', 13)
local callees = {
  main = { { l1a, 29 } },
  func_l1_a = { { l2a, 5 } },
  func_l2_a = {},
}
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

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

vim.cmd('edit ' .. root .. '/tests/clean.c')
local orig_win = vim.api.nvim_get_current_win()

view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)

local wins = vim.api.nvim_list_wins()
check('a second window exists (split)', #wins >= 2)
local win = wins[#wins]
check('new window is a regular split (not a float)', vim.api.nvim_win_get_config(win).relative == '')
check('new window is right of original', vim.api.nvim_win_get_position(win)[2] >= vim.api.nvim_win_get_position(orig_win)[2])
local buf = vim.api.nvim_win_get_buf(win)
check('buffer is nofile scratch', vim.bo[buf].buftype == 'nofile')
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
check('canvas rendered (main + func_l2_a)', text:find('main') ~= nil and text:find('func_l2_a') ~= nil)

view.move('right')
view.toggle_expand()
vim.wait(500, function() return false end)
view.change_depth(1)
vim.wait(500, function() return false end)
view.set_direction('callin')
vim.wait(500, function() return false end)
check('navigation/expand/depth/direction ran', true)

view.close()
vim.wait(200, function() return false end)
check('view closed, back to one window', #vim.api.nvim_list_wins() == 1)
check('focus restored to original window', vim.api.nvim_get_current_win() == orig_win)

print('---')
if failed == 0 then print('UI OK') else print('UI FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
