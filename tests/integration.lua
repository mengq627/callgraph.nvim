-- Real-LSP integration probe (needs clangd on PATH).
--
-- Uses tests/clean.c (well-formed, unlike test.c). Verifies on the real
-- server:
--   * callout from `twice` — clangd < 20 has no outgoingCalls, so this must
--     go through the body-scan heuristic and still find `add`.
--   * callin from `add` — standard incomingCalls finds `main` and `twice`.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l tests/integration.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local config_mod = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')

config_mod.set({ show_call_site = true })

vim.cmd('edit ' .. root .. '/tests/clean.c')
vim.lsp.start({
  name = 'clangd',
  cmd = { 'clangd' },
  root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then
  print('FAIL: clangd did not attach')
  os.exit(1)
end
vim.wait(3000, function() return false end) -- let clangd parse

local failed = 0
local function check(name, cond, detail)
  if cond then
    print('PASS ' .. name)
  else
    failed = failed + 1
    print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or ''))
  end
end

local function render_graph(graph, root, direction)
  local lay = layout_mod.layout(graph, config_mod.get(), { direction = direction, selected_id = graph_mod.node_id(root) })
  local buf = vim.api.nvim_create_buf(false, true)
  render_mod.render(buf, lay, graph, { selected_id = graph_mod.node_id(root), highlights = config_mod.get().highlights })
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function names_of(graph)
  local names = {}
  for _, n in pairs(graph.nodes) do names[#names + 1] = n.name end
  table.sort(names)
  return names
end

local function check_build(name, root, direction, client, encoding, min_nodes, expect_names)
  local d = graph_mod.build(root, direction, { max_depth = 4 }, lsp_mod.make_fetch(client, encoding, config_mod.get()))
  d:next(function(g)
    local names = names_of(g)
    print(name .. ' nodes: ' .. table.concat(names, ', '))
    check(name .. ' graph built', vim.tbl_count(g.nodes) >= min_nodes)
    if expect_names then
      local found = {}
      for _, n in pairs(g.nodes) do found[n.name] = true end
      for _, en in ipairs(expect_names) do
        check(name .. ' contains ' .. en, found[en] == true)
      end
    end
    local lines = render_graph(g, root, direction)
    print('--- rendered ' .. name .. ' ---')
    for _, l in ipairs(lines) do print(l) end
  end, function(e)
    print('FAIL: ' .. name .. ' build error: ' .. tostring(e))
    failed = failed + 1
  end)
end

util.async_start(function()
  local ok, err = pcall(function()
    -- ---- Part 1: callout from `twice` via the body-scan fallback
    vim.api.nvim_win_set_cursor(0, { 7, 13 }) -- on `twice` name (line 6, 0-based)
    local root, encoding, client = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
    check('resolve root twice', root ~= nil and root.name == 'twice')
    if root then
      check_build('callout(twice)', root, 'callout', client, encoding, 2, { 'add' })
    end

    -- ---- Part 2: callin from `add` (standard incomingCalls)
    vim.api.nvim_win_set_cursor(0, { 3, 13 }) -- on `add` name (line 2)
    local root2, enc2, client2 = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
    check('resolve root add', root2 ~= nil and root2.name == 'add')
    if root2 then
      check_build('callin(add)', root2, 'callin', client2, enc2, 2, { 'main' })
    end
  end)
  if not ok then
    print('FAIL: ' .. tostring(err))
    os.exit(1)
  end
end)

vim.wait(30000, function() return false end)
print('---')
if failed == 0 then
  print('INTEGRATION OK')
else
  print('INTEGRATION FAILED: ' .. failed .. ' failure(s)')
end
os.exit(failed == 0 and 0 or 1)
