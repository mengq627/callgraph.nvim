-- Reproduce the user's exact scenario: callout from main on the real test.c,
-- render with main selected, dump main's text row chars vs highlight coverage.
-- Run: nvim --headless -u NONE -l tests/inspect_real.lua

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

vim.cmd('edit ' .. root .. '/tests/test.c')
vim.lsp.start({
  name = 'clangd',
  cmd = { 'clangd' },
  root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then print('no clangd'); os.exit(1) end
vim.wait(3000, function() return false end)

util.async_start(function()
  local ok, err = pcall(function()
    vim.api.nvim_win_set_cursor(0, { 32, 4 }) -- on main
    local item, enc, client = lsp_mod.resolve_root(vim.api.nvim_get_current_buf())
    print('root =', item and item.name)
    if not item or item.name ~= 'main' then os.exit(1) end

    local d = graph_mod.build(item, 'callout', { max_depth = 4 }, lsp_mod.make_fetch(client, enc, config_mod.get()))
    d:next(function(g)
      local sel = graph_mod.node_id(item)
      local lay = layout_mod.layout(g, config_mod.get(), { direction = 'callout', selected_id = sel })
      local buf = vim.api.nvim_create_buf(false, true)
      render_mod.render(buf, lay, g, { selected_id = sel, highlights = config_mod.get().highlights })
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      local hlmap = {}
      local em = vim.api.nvim_buf_get_extmarks(buf, render_mod.ns, 0, -1, { details = true })
      for _, e in ipairs(em) do
        local r0, c0 = e[2], e[3]
        local det = e[4]
        local r1, c1 = det.end_row or r0, det.end_col or (c0 + 1)
        local last_r = (r1 > r0) and (r1 - 1) or r0
        for rr = r0, last_r do
          for cc = c0, c1 - 1 do hlmap[rr .. ',' .. cc] = det.hl_group end
        end
      end

      local box = lay.boxes[sel]
      print('main box: row', box.row, 'col', box.col, 'width', box.width, 'text', box.text)
      local tr = box.row + 1 -- text row (1-based)
      print('text row ' .. tr .. ' chars: |' .. lines[tr] .. '|')
      local mrow = {}
      for cc = 1, #lines[tr] do
        local h = hlmap[(tr - 1) .. ',' .. (cc - 1)]
        if h == 'CallgraphFocus' then mrow[cc] = 'G'
        elseif h == 'CallgraphBox' then mrow[cc] = 'g'
        else mrow[cc] = '.' end
      end
      print('text row highlight:   |' .. table.concat(mrow) .. '|')
      os.exit(0)
    end, function(e) print('build error:', tostring(e)); os.exit(1) end)
  end)
  if not ok then print('ERR:', tostring(err)); os.exit(1) end
end)

vim.wait(30000, function() return false end)
print('TIMEOUT')
os.exit(1)
