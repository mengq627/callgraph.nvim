-- Real-LSP check for tests/test.c with the HEURISTIC fallback explicitly
-- enabled: the body-scan fallback resolves callees by name-match even when
-- the LSP server (clangd 17, no outgoingCalls) cannot. The pure-LSP path with
-- clangd >= 20 is covered separately by tests/integration_lsp.lua.
-- Run: nvim --headless -u NONE -l tests/integration_testc.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config_mod = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local graph_mod = require('callgraph.graph')

config_mod.set({ show_call_site = true, fallback = true })

vim.cmd('edit ' .. root .. '/tests/test.c')
vim.lsp.start({
  name = 'clangd',
  cmd = { 'clangd' },
  root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then print('FAIL: clangd did not attach'); os.exit(1) end
vim.wait(3000, function() return false end)

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

util.async_start(function()
  local ok, err = pcall(function()
    vim.api.nvim_win_set_cursor(0, { 32, 4 }) -- on `main` (test.c line 32)
    -- clangd can be momentarily not-ready in headless; poll until it resolves main.
    local item, enc, client
    for attempt = 1, 10 do
      item, enc, client = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
      if item and item.name == 'main' then break end
      if item then print('  root attempt ' .. attempt .. ' -> ' .. tostring(item.name)) end
      vim.wait(2000, function() return false end)
    end
    check('resolve root main', item ~= nil and item.name == 'main')
    if not item or item.name ~= 'main' then os.exit(1) end

    local d = graph_mod.build(item, 'callout', { max_depth = 4 }, lsp_mod.make_fetch(client, enc, config_mod.get()))
    d:next(function(g)
      local names = {}
      for _, n in pairs(g.nodes) do names[#names + 1] = n.name end
      table.sort(names)
      print('callout(main) nodes: ' .. table.concat(names, ', '))
      check('4+ levels built', vim.tbl_count(g.nodes) >= 5)
      local found = {}
      for _, n in pairs(g.nodes) do found[n.name] = true end
      check('reaches func_l2_c (name-match fallback)', found.func_l2_c == true)
      check('reaches func_l2_a', found.func_l2_a == true)
      os.exit(failed == 0 and 0 or 1)
    end, function(e)
      print('FAIL: build error: ' .. tostring(e))
      os.exit(1)
    end)
  end)
  if not ok then print('ERR: ' .. tostring(err)); os.exit(1) end
end)

vim.wait(30000, function() return false end)
print('TIMEOUT')
os.exit(1)
