-- jump_to_def keeps the callgraph window open: it focuses the main window,
-- jumps to the definition there, and only q/Esc closes the view.
-- Run: nvim --headless -u NONE -l tests/jump.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
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

local jumped = nil
lsp_mod.jump_to_location = function(uri, range, enc)
  jumped = { uri = uri, line = range.start.line, enc = enc }
end

vim.cmd('edit ' .. root .. '/tests/test.c')
local orig_win = vim.api.nvim_get_current_win()
view.open_with_root(main, 'callout', 'utf-16', { name = 'fake' })
vim.wait(500, function() return false end)

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

local function win_count()
  return #vim.api.nvim_list_wins()
end

check('view open', win_count() == 2)

view.jump_to_def()
vim.wait(200, function() return false end)

check('window stays open after jump', win_count() == 2)
check('focus moved to main window', vim.api.nvim_get_current_win() == orig_win)
check('jumped to main def', jumped ~= nil and jumped.uri == U and jumped.line == 32, jumped and vim.inspect(jumped) or 'nil')

-- q still closes the view.
view.close()
vim.wait(200, function() return false end)
check('q closes the view', win_count() == 1)

print('---')
if failed == 0 then print('JUMP OK') else print('JUMP FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
