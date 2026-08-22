-- Verify the language-agnostic LSP path against a NON-C server: pyright
-- (Python), which implements both incomingCalls and outgoingCalls (>= 1.1.44).
-- Proves that resolve_root + graph build are language-independent, not just C.
-- Skips (exit 0) when pyright is not installed.
-- Run: nvim --headless -u NONE -l tests/integration_py.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config_mod = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local graph_mod = require('callgraph.graph')

-- npm shims ship both a bare `pyright-langserver` (a bash script) and a
-- `pyright-langserver.cmd`; prefer the .cmd so libuv spawns it via cmd.exe.
local pyright = vim.fn.exepath('pyright-langserver.cmd')
if pyright == '' then pyright = vim.fn.exepath('pyright.cmd') end
if pyright == '' then pyright = vim.fn.exepath('pyright-langserver') end
if pyright == '' then
  print('SKIP: pyright not found (install pyright for the Python integration test)')
  os.exit(0)
end

config_mod.set({ show_call_site = true, sources = { 'lsp' } })

vim.cmd('edit ' .. root .. '/tests/sample.py')
vim.lsp.start({
  name = 'pyright',
  cmd = { pyright, '--stdio' },
  root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(20000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then print('FAIL: pyright did not attach'); os.exit(1) end
vim.wait(3000, function() return false end)

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- 1-based line of the `def <name>(` in sample.py.
local function def_line(name)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find('^def ' .. name .. '%(') then return i end
  end
  return nil
end

-- Resolve the root item at a function's definition, retrying until the server
-- has analyzed the file (pyright needs a moment after attach).
local function resolve_with_retry(name, line)
  for attempt = 1, 15 do
    vim.api.nvim_win_set_cursor(0, { line, 6 })
    local item = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
    if item and item.name == name then return item end
    vim.wait(2000, function() return false end)
  end
  return nil
end

util.async_start(function()
  local ok, err = pcall(function()
    local main_line = def_line('main')
    check('found main definition', main_line ~= nil)
    if not main_line then os.exit(1) end

    -- callout(main): pure LSP outgoingCalls in Python.
    local item = resolve_with_retry('main', main_line)
    check('resolve root main (Python)', item ~= nil and item.name == 'main')
    if not item then os.exit(1) end
    local d = graph_mod.build(item, 'callout', { max_depth = 4 }, source_mod.make_fetch('utf-16', vim.lsp.get_clients({ bufnr = 0 })[1], config_mod.get()))
    d:next(function(g)
      local found = {}
      for _, n in pairs(g.nodes) do found[n.name] = true end
      print('callout(main) nodes: ' .. table.concat(vim.tbl_keys(found), ', '))
      check('callout reaches leaf_common via diamond (4 levels)', found.leaf_common == true)
      check('callout reaches shared', found.shared == true)
      check('callout reaches alpha/beta', found.alpha == true and found.beta == true)
      check('callout reaches chain1/chain2', found.chain1 == true and found.chain2 == true)
      check('callout sees recursive', found.recursive == true)

      -- callin(leaf_common): incomingCalls, multi-level up to main.
      local ll_line = def_line('leaf_common')
      local item2 = resolve_with_retry('leaf_common', ll_line)
      check('resolve root leaf_common (Python)', item2 ~= nil and item2.name == 'leaf_common')
      if not item2 then os.exit(1) end
      local d2 = graph_mod.build(item2, 'callin', { max_depth = 3 }, source_mod.make_fetch('utf-16', vim.lsp.get_clients({ bufnr = 0 })[1], config_mod.get()))
      d2:next(function(g2)
        local callers = {}
        for _, n in pairs(g2.nodes) do callers[#callers + 1] = n.name end
        table.sort(callers)
        print('callin(leaf_common) nodes: ' .. table.concat(callers, ', '))
        local has = {}
        for _, n in ipairs(callers) do has[n] = true end
        check('callin finds shared + chain2', has.shared == true and has.chain2 == true)
        check('callin climbs to main (3 levels)', has.main == true, table.concat(callers, ', '))
        os.exit(failed == 0 and 0 or 1)
      end, function(e)
        print('FAIL: callin build error: ' .. tostring(e))
        os.exit(1)
      end)
    end, function(e)
      print('FAIL: callout build error: ' .. tostring(e))
      os.exit(1)
    end)
  end)
  if not ok then print('ERR: ' .. tostring(err)); os.exit(1) end
end)

vim.wait(40000, function() return false end)
print('TIMEOUT')
os.exit(1)
