-- Interactive E2E driving framework: launches in a REAL Neovim window and walks
-- through every plugin capability step by step with on-screen prompts and
-- pauses, so you can watch and judge each step. Driven by vim.defer_fn timers on
-- the event loop (NOT the `-l` script mode, which falls back to headless under
-- some terminals).
--
-- Run all cases in one command (watch it):
--   nvim -u NONE --cmd "set rtp+=D:/code/callgraph.nvim" tests/test_complex.c \
--     -c "lua dofile('D:/code/callgraph.nvim/tests/e2e_cases.lua').run_all()"
-- Run a single case:
--   ... -c "lua dofile('D:/code/callgraph.nvim/tests/e2e_cases.lua').run('tabs')"
-- Headless (CI) runs every case synchronously and asserts each step:
--   nvim --headless -u NONE -c "lua dofile('...e2e_cases.lua').run_all()"

local M = {}

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua') -- registers :Callout / :Callin

local util = require('callgraph.util')
local config = require('callgraph.config')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
local view = require('callgraph.view')

local interactive = #vim.api.nvim_list_uis() > 0
local src = root .. '/tests/test_complex.c'

-- ---- Mock the LSP layer (no clangd needed) so cases are deterministic. ----
-- resolve_root maps the cursor's line to a function; the fetch serves a small
-- graph that exercises diamond / deep chain / self-recursion. FUNC_LINES holds
-- LSP (0-based) definition lines in test_complex.c; the cases move the cursor
-- with 1-based line numbers.
local FUNC_LINES = { main = 98, alpha = 24, beta = 29, chain1 = 50, recursive = 74, leaf = 13 }
local function item(name, line)
  return {
    name = name, kind = 12, uri = vim.uri_from_fname(src),
    range = { start = { line = line, character = 0 }, ['end'] = { line = line + 4, character = 0 } },
    selectionRange = { start = { line = line, character = 0 }, ['end'] = { line = line, character = #name } },
  }
end
local callees = {
  main = { { item('alpha', 20), 100 }, { item('beta', 29), 101 }, { item('chain1', 38), 102 }, { item('recursive', 80), 103 } },
  alpha = { { item('leaf', 5), 21 } },
  beta = {}, chain1 = {}, leaf = {},
  recursive = { { item('recursive', 80), 150 } }, -- self-recursion -> ⟳
}
local callers = {
  main = {},
  alpha = { { item('main', 99), 100 } },
  beta = { { item('main', 99), 101 } },
  chain1 = { { item('main', 99), 102 } },
  recursive = { { item('main', 99), 103 }, { item('recursive', 80), 150 } },
  leaf = { { item('alpha', 20), 21 } },
}
lsp_mod.resolve_root = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local win = vim.fn.bufwinid(bufnr)
  local cur = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(bufnr, cur[1] - 1, cur[1], false)[1] or ''
  for name, ln in pairs(FUNC_LINES) do
    if line:find(name, 1, true) then return item(name, ln), 'utf-16', nil end
  end
  return nil, nil, nil
end
source_mod.make_fetch = function()
  return function(node, direction)
    local d = util.Deferred.new()
    local list = (direction == 'callin') and (callers[node.name] or {}) or (callees[node.name] or {})
    local out = {}
    for _, e in ipairs(list) do
      out[#out + 1] = { item = e[1], call_site = { uri = vim.uri_from_fname(src), line = e[2] } }
    end
    d:resolve(out)
    return d
  end
end

-- ---- Helpers ----
local function graph_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'nofile' then return w end
  end
  return nil
end
local function graph_text()
  local w = graph_win()
  if not w then return '' end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), '\n')
end
local function cursor_on(name)
  local c = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(0, c[1] - 1, c[1], false)[1] or ''
  return line:find(name, 1, true) ~= nil
end
local function start_case(cfg)
  -- view.close() is idempotent; the previous case's view (if any) must be torn
  -- down, otherwise `edit` below runs in the graph window and wipes its buffer.
  view.close()
  vim.cmd('edit ' .. src)
  if cfg then config.set(cfg) end
end

-- ---- Cases ----
local CASES = {
  callout = {
    { msg = '[callout] 把光标移到 main', fn = function() vim.api.nvim_win_set_cursor(0, { 99, 6 }) end, wait = 1500,
      check = function() return cursor_on('main') end },
    { msg = '[callout] 执行 :Callout —— 右侧弹出 main 的调用图', fn = function() vim.cmd('Callout') end, wait = 2500,
      check = function() local t = graph_text(); return graph_win() ~= nil and t:find('alpha') ~= nil and t:find('recursive') ~= nil end },
    { msg = '[callout] 按 l 移动选中框', fn = function() view.move('right') end, wait = 1500 },
    { msg = '[callout] 按空格展开/折叠', fn = function() view.toggle_expand() end, wait = 1500 },
  },
  callin = {
    { msg = '[callin] 光标移到 alpha', fn = function() vim.api.nvim_win_set_cursor(0, { 25, 6 }) end, wait = 1500,
      check = function() return cursor_on('alpha') end },
    { msg = '[callin] 执行 :Callin —— 显示谁调用了 alpha（预期 main）', fn = function() vim.cmd('Callin') end, wait = 2500,
      check = function() return graph_text():find('main') ~= nil end },
  },
  direction = {
    { msg = '[direction] :Callout main 后，按 i 切到 callin（预期图反向）', fn = function()
        vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[direction] 按 i 切换为 callin', fn = function() view.set_direction('callin') end, wait = 2000 },
    { msg = '[direction] 再按 o 切回 callout', fn = function() view.set_direction('callout') end, wait = 1500 },
  },
  expand = {
    { msg = '[expand] 设 max_depth=1 再 :Callout（预期边界节点带折叠标记）', fn = function()
        start_case({ max_depth = 1, show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000,
      check = function() return graph_text():find('❯') ~= nil end },
    { msg = '[expand] 按空格展开一层（预期露出下一层子节点）', fn = function() view.toggle_expand() end, wait = 2000 },
    { msg = '[expand] 再按空格折叠回', fn = function() view.toggle_expand() end, wait = 1500 },
  },
  depth = {
    { msg = '[depth] :Callout main（默认深度 4）', fn = function()
        start_case({ max_depth = 4, show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[depth] 按 - 减少深度（预期图变浅）', fn = function() view.change_depth(-1) end, wait = 2000 },
    { msg = '[depth] 按 + 增加深度（预期图变深）', fn = function() view.change_depth(1) end, wait = 2000 },
    { msg = '[depth] 按 = 增加深度（= 与 + 等价，免 Shift）', fn = function()
        local km = config.get().keymaps
        assert(km.depth_up_alt ~= '', 'depth_up_alt 未配置')
        assert(vim.fn.maparg(km.depth_up_alt, 'n', false, true).callback ~= vim.NIL, '= 键未绑定到深度+1')
        view.change_depth(1) end, wait = 2000 },
  },
  tabs = {
    { msg = '[tabs] :Callout main（tab1）', fn = function()
        start_case({ show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[tabs] 光标移到 alpha 再 :Callout（新建 tab2）', fn = function()
        vim.api.nvim_set_current_win(vim.fn.bufwinid(vim.fn.bufadd(src)))
        vim.api.nvim_win_set_cursor(0, { 25, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[tabs] 按 Tab 在标签间切换', fn = function() view.tab_next() end, wait = 1500 },
    { msg = '[tabs] 按 q 关闭当前 tab', fn = function() view.close_tab() end, wait = 1500 },
  },
  jump = {
    { msg = '[jump] :Callout main 后按 Enter 跳转到定义', fn = function()
        start_case({ show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[jump] 按 Enter（预期：跳到 main 定义处，视图保持打开）', fn = function()
        view.jump_to_def() end, wait = 2000,
      check = function() return cursor_on('main') end },
  },
  close = {
    { msg = '[close] :Callout 后按 q 关闭视图', fn = function()
        start_case({ show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[close] 按 q（预期：callgraph 窗口关闭）', fn = function() view.close_tab() end, wait = 1500,
      check = function() return graph_win() == nil end },
  },
  cycle = {
    { msg = '[cycle] :Callout main（预期 recursive 显示循环 ⟳）', fn = function()
        start_case({ show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2500,
      check = function() return graph_text():find('⟳') ~= nil end },
  },
  scroll = {
    { msg = '[scroll] 窄窗口（fixed_width=20）+ :Callout 宽图', fn = function()
        start_case({ show_call_site = true, window = { position = 'right', fixed_width = 20 } })
        vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2500 },
    { msg = '[scroll] 连续右移选中框（预期窗口自动横向滚动）', fn = function()
        view.move('right'); view.move('right'); view.move('right') end, wait = 2000,
      check = function()
        local w = graph_win()
        return w ~= nil and (vim.api.nvim_win_call(w, function() return vim.fn.winsaveview().leftcol end) > 0)
      end },
  },
  resize = {
    { msg = '[resize] 右侧视图 :Callout（fixed_width=20）', fn = function()
        start_case({ show_call_site = false, window = { position = 'right', fixed_width = 20 } })
        vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[resize] 按 > 放大窗口（预期变宽）', fn = function() view.resize_window_size(1) end, wait = 1500,
      check = function()
        local w = graph_win()
        return w ~= nil and vim.api.nvim_win_get_width(w) > 20
      end },
    { msg = '[resize] 按 < 缩小窗口（预期回到 20）', fn = function() view.resize_window_size(-1) end, wait = 1500,
      check = function()
        local w = graph_win()
        return w ~= nil and vim.api.nvim_win_get_width(w) == 20
      end },
  },
  help = {
    { msg = '[help] 打开视图后按 ? 弹出按键速查', fn = function()
        start_case({ show_call_site = false }); vim.api.nvim_win_set_cursor(0, { 99, 6 }); vim.cmd('Callout') end, wait = 2000 },
    { msg = '[help] 按 ?（预期：消息区显示快捷键）', fn = function() view.show_help() end, wait = 1500 },
  },
}

local ORDER = { 'callout', 'callin', 'direction', 'expand', 'depth', 'tabs', 'jump', 'close', 'cycle', 'scroll', 'resize', 'help' }

-- ---- Runner ----
local function run_steps(steps, name, on_done)
  local failed, i = 0, 0
  local function do_step(s)
    vim.api.nvim_echo({ { s.msg, 'Title' } }, true, {})
    local ok, err = pcall(s.fn)
    if not ok then failed = failed + 1; print('FAIL ' .. name .. ' #' .. (i + 1) .. ' ' .. tostring(err)); return end
    if s.check then
      local cok, cres = pcall(s.check)
      if cok and cres then
        print('PASS ' .. name .. ' #' .. (i + 1))
      else
        failed = failed + 1
        print('FAIL ' .. name .. ' #' .. (i + 1) .. (cok and '' or (' ' .. tostring(cres))))
      end
    end
  end
  if not interactive then
    for idx, s in ipairs(steps) do
      i = idx
      do_step(s)
      if failed > 0 then break end
    end
    print('E2E ' .. name .. (failed == 0 and ' PASS' or ' FAIL'))
    if on_done then on_done(failed == 0) end
    return
  end
  local function next()
    i = i + 1
    local s = steps[i]
    if not s then
      vim.api.nvim_echo({ { '用例完成: ' .. name .. (failed == 0 and ' ✓ PASS' or ' ✗ FAIL'), failed == 0 and 'MoreMsg' or 'ErrorMsg' } }, true, {})
      if on_done then on_done(failed == 0) end
      return
    end
    do_step(s)
    vim.defer_fn(next, s.wait or 1500)
  end
  next()
end

--- Run a single case.
function M.run(name)
  local steps = CASES[name]
  if not steps then vim.notify('E2E: 未找到用例 ' .. tostring(name), vim.log.levels.WARN); return end
  start_case(nil)
  run_steps(steps, name, function(ok)
    if not interactive then os.exit(ok and 0 or 1) end
  end)
end

--- Run every case in order (one command watches the whole suite).
function M.run_all()
  local total_fail, i = 0, 0
  local function next_case()
    i = i + 1
    local name = ORDER[i]
    if not name then
      if not interactive then
        print('E2E ALL ' .. (total_fail == 0 and 'PASS' or 'FAIL (' .. total_fail .. ')'))
        os.exit(total_fail == 0 and 0 or 1)
      end
      vim.api.nvim_echo({ { '全部用例完成：' .. (total_fail == 0 and '✓ 全部通过' or '✗ ' .. total_fail .. ' 个失败') .. '（:qa 关闭）', total_fail == 0 and 'MoreMsg' or 'ErrorMsg' } }, true, {})
      return
    end
    start_case(nil)
    vim.api.nvim_echo({ { '======== 用例 ' .. i .. '/' .. #ORDER .. ': ' .. name .. ' ========', 'Title' } }, true, {})
    run_steps(CASES[name], name, function(ok)
      if not ok then total_fail = total_fail + 1 end
      if interactive then vim.defer_fn(next_case, 2000) else next_case() end
    end)
  end
  next_case()
end

return M
