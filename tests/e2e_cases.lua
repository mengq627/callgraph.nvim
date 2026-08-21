-- E2E driving framework: launches in a REAL interactive Neovim window and steps
-- through each case with on-screen prompts, actions and pauses so you can watch
-- and judge each step. Driven by vim.defer_fn timers on the event loop (NOT the
-- `-l` script mode, which falls back to headless under some terminals).
--
-- Launch (interactive, you watch):
--   nvim -u NONE --cmd "set rtp+=D:/code/callgraph.nvim" tests/test_complex.c \
--     -c "lua dofile('D:/code/callgraph.nvim/tests/e2e_cases.lua').run('callout')"
--
-- Headless (CI logic check):
--   nvim --headless -u NONE --cmd "set rtp+=D:/code/callgraph.nvim" \
--     -c "lua dofile('D:/code/callgraph.nvim/tests/e2e_cases.lua').run('callout')"

local M = {}

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua') -- registers :Callout / :Callin

local util = require('callgraph.util')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

local interactive = #vim.api.nvim_list_uis() > 0
local src = vim.fn.getcwd() .. '/tests/test_complex.c'

-- Mock the LSP layer so cases run without clangd (deterministic). The demo
-- graph mirrors test_complex.c: main calls alpha/beta/chain1/recursive.
local function item(name, line)
  return {
    name = name, kind = 12, uri = vim.uri_from_fname(src),
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local callees = {
  main = {
    { item('alpha', 20), 100 }, { item('beta', 29), 101 },
    { item('chain1', 38), 102 }, { item('recursive', 80), 103 },
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

-- A case is a list of steps: { msg, fn, wait_ms, check? }
local CASES = {
  callout = {
    {
      msg = '[验证] 光标定位 — 把光标移到 main（预期：光标停在 main 上）',
      fn = function() vim.api.nvim_win_set_cursor(0, { 99, 6 }) end,
      wait = 1800,
      check = function()
        local c = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(0, c[1] - 1, c[1], false)[1] or ''
        return line:find('main') ~= nil
      end,
    },
    {
      msg = '[验证] :Callout — 执行命令（预期：右侧分割出 main 的调用图窗口）',
      fn = function() vim.cmd('Callout') end,
      wait = 3000,
      check = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'nofile' then return true end
        end
        return false
      end,
    },
    {
      msg = '[验证] 方向键移动 — 按 l 移动选中框（预期：选中框移到子函数）',
      fn = function() view.move('right') end,
      wait = 2000,
    },
    {
      msg = '[验证] 空格展开 — 按 <Space> 展开/折叠（预期：边界节点折叠标记变化）',
      fn = function() view.toggle_expand() end,
      wait = 2000,
    },
    {
      msg = '[验证] 切换方向 — 按 i 切到 callin（预期：图变为"谁调用了它"）',
      fn = function() view.set_direction('callin') end,
      wait = 2500,
    },
  },
}

--- Run a case. Interactive: step through on the event loop (vim.defer_fn) with
--- pauses so the user watches; headless: run synchronously for CI.
function M.run(name)
  local steps = CASES[name]
  if not steps then
    vim.notify('E2E: 未找到用例 ' .. tostring(name), vim.log.levels.WARN)
    return
  end
  vim.cmd('edit ' .. src)
  local failed = 0
  local function do_step(s, idx)
    vim.api.nvim_echo({{ s.msg, 'Title' }}, true, {})
    s.fn()
    if s.check then
      if s.check() then
        print('PASS ' .. name .. ' #' .. idx)
      else
        failed = 1
        print('FAIL ' .. name .. ' #' .. idx)
      end
    end
  end

  if not interactive then
    for idx, s in ipairs(steps) do do_step(s, idx) end
    print('E2E ' .. name .. (failed == 0 and ' PASS' or ' FAIL'))
    os.exit(failed == 0 and 0 or 1)
  end

  local i = 0
  local function next_step()
    i = i + 1
    local s = steps[i]
    if not s then
      vim.api.nvim_echo({ { '用例完成: ' .. name .. (failed == 0 and ' ✓ PASS' or ' ✗ FAIL'), failed == 0 and 'MoreMsg' or 'ErrorMsg' } }, true, {})
      return
    end
    do_step(s, i)
    vim.defer_fn(next_step, s.wait or 1500)
  end
  next_step()
end

return M
