-- The focused-name highlight must be non-bold by default (soft) and bold only
-- when highlights.focus_bold is enabled.
-- Run: nvim --headless -u NONE -l tests/focus_bold.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local config = require('callgraph.config')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

config.set({ highlight = true })
config.define_highlights()
local hl_default = vim.api.nvim_get_hl(0, { name = 'CallgraphFocus' })
check('focus not bold by default', hl_default.bold ~= true, 'bold=' .. tostring(hl_default.bold))

config.set({ highlight = true, highlights = { focus_bold = true } })
config.define_highlights()
local hl_on = vim.api.nvim_get_hl(0, { name = 'CallgraphFocus' })
check('focus bold when focus_bold enabled', hl_on.bold == true, 'bold=' .. tostring(hl_on.bold))

print('---')
if failed == 0 then print('FOCUS_BOLD OK') else print('FOCUS_BOLD FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
