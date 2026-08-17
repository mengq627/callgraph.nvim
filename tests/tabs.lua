-- Tab behavior: same (function, direction) reuses the tab; different roots
-- create new tabs; close_tab removes the active tab; last tab closes the window.
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

-- Tab labels now render on the native 'tabline'. Parse them out of the
-- "%N@func@%#HL#label%*%X" segments (in tab order).
local function tab_labels()
  local tl = vim.o.tabline
  local labels = {}
  for n, label in tl:gmatch('%%(%d+)@.-@%%#.-#(.-)%%%*%%X') do
    labels[tonumber(n)] = label
  end
  return labels
end
local function labels_str()
  local t = tab_labels()
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  return table.concat(out, '|')
end
local function win_count()
  return #vim.api.nvim_list_wins()
end

local arr = config.get().window.arrows.right -- 

view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('tab1: callout main', labels_str() == '[' .. 'main' .. arr .. ']', labels_str())
check('window open', win_count() == 2)
check('tabline enabled', vim.o.showtabline == 2, tostring(vim.o.showtabline))

view.open_with_root(l1a, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('tab2: new tab added', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']', labels_str())

view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('reopen main -> jump to tab1', labels_str() == '[' .. 'main' .. arr .. ']|' .. 'func_l1_a' .. arr, labels_str())

view.open_with_root(main, 'callin', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)
check('callin is a different tab', labels_str() == 'main' .. arr .. '|' .. 'func_l1_a' .. arr .. '|[' .. arr .. 'main]', labels_str())

-- Left click on a tabline label switches to that tab.
view.on_tab_click(2, 1, 'l')
vim.wait(200, function() return false end)
check('tabline click switches tab', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']|' .. arr .. 'main', labels_str())

view.on_tab_click(3, 1, 'l')
vim.wait(200, function() return false end)
check('tabline click back to callin', labels_str() == 'main' .. arr .. '|' .. 'func_l1_a' .. arr .. '|[' .. arr .. 'main]', labels_str())

view.close_tab()
vim.wait(200, function() return false end)
-- The previous active tab was func_l1_a (we clicked it above), so closing
-- callin-main returns there.
check('close active tab (callin main)', labels_str() == 'main' .. arr .. '|[' .. 'func_l1_a' .. arr .. ']', labels_str())

-- Middle click closes the tab under the pointer.
view.on_tab_click(1, 1, 'm')
vim.wait(200, function() return false end)
check('middle click closes tab1', labels_str() == '[' .. 'func_l1_a' .. arr .. ']', labels_str())

view.close_tab()
vim.wait(200, function() return false end)
check('last tab closed -> window closed', win_count() == 1)
check('focus restored', vim.api.nvim_get_current_win() == orig_win)

print('---')
if failed == 0 then print('TABS OK') else print('TABS FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
