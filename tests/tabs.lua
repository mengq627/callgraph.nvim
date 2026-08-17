-- Tab behavior: same (function, direction) reuses the tab; different roots
-- create new tabs; close_tab removes the active tab; last tab closes the
-- window. Tab labels render on the window's winbar; <Tab>/<S-Tab> cycle tabs.
-- Run: nvim --headless -u NONE -l tests/tabs.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local view = require('callgraph.view')

config.set({ show_call_site = false })

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
local callees = { main = { { l1a, 34 } }, func_l1_a = {} }
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
local orig_win = vim.api.nvim_get_current_win()

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- Tab labels render on the callgraph window's winbar ("%#HL#label%*...").
local function winbar_labels()
  local win = vim.api.nvim_get_current_win()
  local wb = vim.wo[win].winbar or ''
  local labels = {}
  local i = 0
  for label in wb:gmatch('%%#.-#(.-)%%%*') do
    i = i + 1
    labels[i] = label
  end
  return labels
end
local function labels_str()
  return table.concat(winbar_labels(), '|')
end
local function win_count()
  return #vim.api.nvim_list_wins()
end

local arr = config.get().window.arrows.right -- 

view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('tab1: callout main', labels_str() == '[' .. 'main' .. arr .. ']', labels_str())
check('window open', win_count() == 2)
check('winbar set on view window', vim.wo[vim.api.nvim_get_current_win()].winbar ~= '', vim.wo[vim.api.nvim_get_current_win()].winbar)
check('global tabline untouched', vim.o.tabline == '' or vim.o.tabline == vim.NIL, tostring(vim.o.tabline))

view.open_with_root(l1a, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('tab2: new tab added', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']', labels_str())

view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('reopen main -> jump to tab1', labels_str() == '[' .. 'main' .. arr .. ']|' .. 'func_l1_a' .. arr, labels_str())

view.open_with_root(main, 'callin', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('callin is a different tab', labels_str() == 'main' .. arr .. '|' .. 'func_l1_a' .. arr .. '|[' .. arr .. 'main]', labels_str())

-- Pressing <Tab> inside the view must cycle callgraph tabs (the buffer-local
-- binding overrides global mappings such as barbar's <Tab> -> BufferNext).
local g_tab = false
vim.keymap.set('n', '<Tab>', function() g_tab = true end, {})
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Tab>', true, false, true), 'x', false)
vim.wait(200, function() return false end)
check('Tab key cycles tabs in view', labels_str() == '[' .. 'main' .. arr .. ']|' .. 'func_l1_a' .. arr .. '|' .. arr .. 'main', labels_str())
check('global Tab mapping not triggered', g_tab == false, tostring(g_tab))
-- Restore the active tab to callin (tab 3) for the remaining checks.
view.tab_next()
vim.wait(200, function() return false end)
view.tab_next()
vim.wait(200, function() return false end)
check('restored active to callin tab', labels_str() == 'main' .. arr .. '|' .. 'func_l1_a' .. arr .. '|[' .. arr .. 'main]', labels_str())

-- <S-Tab> from the last tab goes back to tab 2.
view.tab_prev()
vim.wait(200, function() return false end)
check('tab_prev switches tab', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']|' .. arr .. 'main', labels_str())

-- <Tab> moves forward again to the callin tab.
view.tab_next()
vim.wait(200, function() return false end)
check('tab_next switches tab', labels_str() == 'main' .. arr .. '|' .. 'func_l1_a' .. arr .. '|[' .. arr .. 'main]', labels_str())

view.close_tab()
vim.wait(200, function() return false end)
-- The previous active tab was func_l1_a, so closing callin-main returns there.
check('close active tab (callin main)', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']', labels_str())

-- <Tab> wraps from tab 2 back to tab 1.
view.tab_next()
vim.wait(200, function() return false end)
check('tab_next wraps to tab1', labels_str() == '[' .. 'main' .. arr .. ']|' .. 'func_l1_a' .. arr, labels_str())

view.tab_prev()
vim.wait(200, function() return false end)
check('tab_prev back to func_l1_a', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']', labels_str())

view.close_tab()
vim.wait(200, function() return false end)
view.close_tab()
vim.wait(200, function() return false end)
check('last tab closed -> window closed', win_count() == 1)
check('focus restored', vim.api.nvim_get_current_win() == orig_win)

print('---')
if failed == 0 then print('TABS OK') else print('TABS FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
