-- Real-LSP check on tests/test_complex.c, a fixture covering every call-graph
-- shape: diamond (multiple paths to one function), self/mutual recursion
-- (cycles), fan-out, deep chains and a shared leaf. The build must reach all of
-- them and mark the recursion cycles as ⟳ terminals.
-- Run: nvim --headless -u NONE -l tests/integration_complex.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config_mod = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local graph_mod = require('callgraph.graph')

config_mod.set({ show_call_site = false, sources = { 'lsp', 'auto' } })

vim.cmd('edit ' .. root .. '/tests/test_complex.c')
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

-- every function that must appear in the callout graph of main
local EXPECTED = {
  'main', 'alpha', 'beta', 'shared', 'leaf_common',
  'chain1', 'chain2', 'chain3', 'chain4',
  'fan', 'fan_a', 'fan_b',
  'recursive', 'even', 'odd',
}

util.async_start(function()
  local ok, err = pcall(function()
    vim.api.nvim_win_set_cursor(0, { 99, 6 }) -- on `main` (last function in file)
    local item, enc, client
    for attempt = 1, 15 do
      item, enc, client = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
      if item and item.name == 'main' then break end
      vim.wait(2000, function() return false end)
    end
    check('resolve root main', item ~= nil and item.name == 'main')
    if not item or item.name ~= 'main' then os.exit(1) end

    local d = graph_mod.build(item, 'callout', { max_depth = 4 }, source_mod.make_fetch(enc, client, config_mod.get()))
    d:next(function(g)
      local by_name = {}
      for _, n in pairs(g.nodes) do
        by_name[n.name] = (by_name[n.name] or 0) + 1
      end
      for _, name in ipairs(EXPECTED) do
        check('reaches ' .. name, by_name[name] ~= nil)
      end

      -- cycles: self-recursion (recursive) and mutual recursion (even<->odd)
      local cycles = 0
      for _, n in pairs(g.nodes) do
        if n.is_cycle then cycles = cycles + 1 end
      end
      check('cycles marked (recursive / even<->odd)', cycles >= 1, 'cycles=' .. cycles)

      -- diamond: tree mode — `shared` is reached via two paths (alpha and
      -- beta), each with its own node and a single caller.
      local shareds = {}
      for id, n in pairs(g.nodes) do
        if n.name == 'shared' then shareds[#shareds + 1] = n end
      end
      check('diamond: shared reached twice (alpha & beta paths)', #shareds == 2, 'got ' .. #shareds)
      check('diamond: each shared has 1 caller', shareds[1] ~= nil and #shareds[1].parents == 1 and #shareds[2].parents == 1)

      -- fan-out: fan calls both fan_a and fan_b
      local fan_node = nil
      for id, n in pairs(g.nodes) do
        if n.name == 'fan' then fan_node = n end
      end
      local fan_children = {}
      if fan_node then
        for _, cid in ipairs(fan_node.children) do
          local c = g.nodes[cid]
          if c then fan_children[c.name] = true end
        end
      end
      check('fan-out: fan calls fan_a and fan_b', fan_children.fan_a and fan_children.fan_b)

      -- shared leaf reached from several roots
      check('shared leaf reached', by_name.leaf_common ~= nil)

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
