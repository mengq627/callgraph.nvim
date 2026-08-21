-- E2E demo: open a real file, move the cursor onto a function, run :Callout and
-- verify the rendered call graph. Run WITHOUT --headless so a real window shows
-- the steps:
--   nvim -u NONE -l tests/e2e_callout.lua
-- (headless also works for CI: nvim --headless -u NONE -l tests/e2e_callout.lua)

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')

-- Mock the LSP layer so the demo runs without clangd: resolve `main`, and
-- serve a small graph main -> alpha, beta.
local src = root .. '/tests/test_complex.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = vim.uri_from_fname(src),
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local callees = {
  main = { { item('alpha', 20), 100 }, { item('beta', 29), 101 } },
  alpha = {},
  beta = {},
}
lsp_mod.resolve_root = function()
  return item('main', 99), 'utf-16', nil
end
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local out = {}
    for _, e in ipairs(callees[node.name] or {}) do
      out[#out + 1] = { item = e[1], call_site = { uri = vim.uri_from_fname(src), line = e[2] } }
    end
    d:resolve(out)
    return d
  end
end

-- 1. Open the file, 2. put the cursor on main, 3. run :Callout.
vim.cmd('edit ' .. src)
vim.api.nvim_win_set_cursor(0, { 99, 6 })
vim.cmd('Callout')
vim.wait(1500, function() return false end) -- let the async render + UI paint

-- Find the callgraph window and verify the rendered canvas.
local graph_buf = nil
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(win)
  if vim.bo[b].buftype == 'nofile' then graph_buf = b end
end

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

check('callgraph window opened', graph_buf ~= nil)
if graph_buf then
  local lines = vim.api.nvim_buf_get_lines(graph_buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  check('graph shows main', text:find('main') ~= nil)
  check('graph shows alpha and beta', text:find('alpha') ~= nil and text:find('beta') ~= nil)
  -- The canvas is Unicode; on Windows the terminal stdout is often not UTF-8,
  -- so save the snapshot to a file (open it with a UTF-8 editor / nvim).
  local snap = vim.fn.stdpath('cache') .. '/callgraph_e2e_render.txt'
  vim.fn.writefile(lines, snap)
  print('render snapshot saved to ' .. snap)
end

-- Give the user a moment to see the window when running with a real UI
-- (headless has no UI, so skip the pause there).
if #vim.api.nvim_list_uis() > 0 then vim.wait(3000, function() return false end) end

print('---')
if failed == 0 then print('E2E CALLOUT OK') else print('E2E CALLOUT FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
