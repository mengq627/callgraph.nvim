-- "Movie-style" E2E demo: a real Neovim window opens and walks through the
-- plugin step by step (open file -> place cursor -> :Callout -> move selection
-- -> toggle direction -> expand/collapse -> depth) with on-screen prompts and
-- pauses so you can watch it. Run WITHOUT --headless:
--   nvim -u NONE -l tests/e2e_demo.lua
-- (headless also works for CI logic checks: nvim --headless -u NONE -l ...)

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local util = require('callgraph.util')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

-- Mock the LSP layer (no clangd needed): resolve `main`, serve a small graph.
local src = root .. '/tests/test_complex.c'
local function item(name, line)
  return {
    name = name, kind = 12, uri = vim.uri_from_fname(src),
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local callees = {
  main = {
    { item('alpha', 20), 100 },
    { item('beta', 29), 101 },
    { item('chain1', 38), 102 },
    { item('recursive', 80), 103 },
  },
  alpha = {}, beta = {}, chain1 = {}, recursive = {},
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

local interactive = #vim.api.nvim_list_uis() > 0
local function step(msg, ms)
  vim.api.nvim_echo({ { msg, 'Title' } }, true, {})
  vim.wait(ms, function() return false end)
end
local function pause(msg, ms)
  step(msg, ms)
end

vim.cmd('edit ' .. src)
step('Step 1/6: 打开 test_complex.c', 1200)

vim.api.nvim_win_set_cursor(0, { 99, 6 })
step('Step 2/6: 光标移到 main 上', 1200)

vim.cmd('Callout')
step('Step 3/6: :Callout — 渲染 main 的调用图', 3000)

if view.state then
  view.move('right')
  pause('Step 4/6: 按 h/l 移动选中框', 1800)
  view.set_direction('callin')
  pause('Step 5/6: 按 i 切换为 callin（谁调用了它）', 2500)
  view.set_direction('callout')
  view.toggle_expand()
  pause('Step 6/6: 空格展开 / 折叠', 2500)
end

pause(interactive and '演示结束，窗口保持打开（输入 :qa 关闭）' or 'DEMO done', 2500)
if not interactive then
  os.exit(0)
end
-- With a real UI: leave the window open so the user can inspect it, then quit
-- manually with :qa. Used via `nvim-qt -u NONE -c "lua dofile('...e2e_demo.lua')"`.
