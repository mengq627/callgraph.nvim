-- Verifies every module requires cleanly.
-- Run from the repo root:
--   nvim --headless -u NONE -l tests/load_check.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)

local mods = {
  'callgraph',
  'callgraph.util',
  'callgraph.config',
  'callgraph.scanner',
  'callgraph.fallback',
  'callgraph.lsp',
  'callgraph.graph',
  'callgraph.layout',
  'callgraph.render',
  'callgraph.view',
}

local ok_all = true
for _, m in ipairs(mods) do
  local ok, res = pcall(require, m)
  print(string.format('require %-22s %s', m, ok and 'OK' or ('ERR: ' .. tostring(res))))
  if not ok then ok_all = false end
end
print(ok_all and 'LOAD OK' or 'LOAD FAILED')
os.exit(ok_all and 0 or 1)
