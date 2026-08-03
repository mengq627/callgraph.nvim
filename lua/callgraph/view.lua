--- The callgraph floating view: single reusable window, fit-to-content
--- sizing, buffer-local keymaps, mouse interaction, hover echo, and the async
--- glue between LSP data and the layout/render core.

local config = require('callgraph.config')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')
local lsp_mod = require('callgraph.lsp')
local util = require('callgraph.util')

local M = {}
local state = nil

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

--- Open (or reuse) the view for the function under the cursor.
function M.open(direction)
  util.async_start(function()
    local ok, err = pcall(function()
      local bufnr = vim.api.nvim_get_current_buf()
      local curr_win = vim.api.nvim_get_current_win()
      if state and state.win and curr_win == state.win and state.orig_win and vim.api.nvim_win_is_valid(state.orig_win) then
        bufnr = vim.api.nvim_win_get_buf(state.orig_win)
      end
      local root, encoding, client = lsp_mod.resolve_root(bufnr)
      if not root then return end
      M.open_with_root(root, direction, encoding, client)
    end)
    if not ok then
      vim.notify('Callgraph: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

function M.open_with_root(root, direction, encoding, client)
  local opts = config.get()
  local win = vim.api.nvim_get_current_win()

  if not state or not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    state = {
      buf = buf,
      win = nil,
      orig_win = win,
      root = root,
      direction = direction,
      encoding = encoding,
      client = client,
      view_depth = opts.max_depth,
      graph = nil,
      selected_id = nil,
      last_layout = nil,
      last_w = nil,
      last_h = nil,
      keyed = false,
    }
    M.open_float()
  else
    if state.win == win then
      -- Float is focused (command run from inside the view): keep orig_win.
    else
      state.orig_win = win
    end
    state.root = root
    state.direction = direction
    state.encoding = encoding
    state.client = client
  end
  M.rebuild()
end

function M.open_float()
  -- Right-side split window (not a float).
  local win = vim.api.nvim_open_win(state.buf, true, {
    split = 'right',
  })
  state.win = win
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  M.setup_keymaps()
end

-- ---------------------------------------------------------------------------
-- Build / render pipeline
-- ---------------------------------------------------------------------------

function M.rebuild()
  local fetch = lsp_mod.make_fetch(state.client, state.encoding, config.get())
  local d = graph_mod.build(state.root, state.direction, { max_depth = state.view_depth }, fetch)
  d:next(function(graph)
    state.graph = graph
    state.selected_id = graph.root.id
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: 建图失败: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.render_view()
  local opts = config.get()
  local layout = layout_mod.layout(state.graph, opts, {
    direction = state.direction,
    selected_id = state.selected_id,
  })
  state.last_layout = layout
  M.resize_window(opts, layout)
  render_mod.render(state.buf, layout, state.graph, {
    selected_id = state.selected_id,
    highlight = opts.highlight,
    highlights = opts.highlights,
  })
  M.focus_selected()
end

function M.resize_window(opts, layout)
  -- Split window keeps the full editor height; only the width tracks content.
  local columns = vim.o.columns
  local mw = math.floor(columns * opts.window.max_width_ratio)
  local w = math.min(layout.width + 2, mw)
  if w < 3 then w = 3 end
  if state.last_w == w then return end
  state.last_w = w
  vim.api.nvim_win_set_width(state.win, w)
end

function M.focus_selected()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local box = state.last_layout and state.last_layout.boxes[state.selected_id]
  if not box then return end
  pcall(function()
    vim.api.nvim_win_set_cursor(state.win, { box.row, box.col - 1 })
    vim.api.nvim_win_call(state.win, function() vim.cmd('normal! zt') end)
  end)
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

local function box_at(row, col)
  if not state or not state.last_layout then return nil end
  for id, b in pairs(state.last_layout.boxes) do
    if row >= b.row and row <= b.row + b.height - 1 and col >= b.col and col <= b.col + b.width - 1 then
      return id
    end
  end
  return nil
end

function M.move(dir)
  if not state or not state.last_layout then return end
  local focus = state.last_layout.boxes[state.selected_id]
  if not focus then return end
  local fc = focus.col + focus.width / 2
  local fr = focus.row + 1
  local dirs = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
  local d = dirs[dir]
  if not d then return end
  local dx, dy = d[1], d[2]
  local best, best_score
  for id, b in pairs(state.last_layout.boxes) do
    if id ~= state.selected_id then
      local bc = b.col + b.width / 2
      local br = b.row + 1
      local dc, dr = bc - fc, br - fr
      local in_half = (dx < 0 and dc < -0.1) or (dx > 0 and dc > 0.1) or (dy < 0 and dr < -0.1) or (dy > 0 and dr > 0.1)
      if in_half then
        local score
        if dx ~= 0 then score = math.abs(dc) + math.abs(dr) * 0.4 else score = math.abs(dr) + math.abs(dc) * 0.4 end
        if not best_score or score < best_score then best, best_score = id, score end
      end
    end
  end
  if best then
    state.selected_id = best
    M.render_view()
  end
end

function M.toggle_expand()
  if not state or not state.graph then return end
  local node = state.graph.nodes[state.selected_id]
  if not node then return end
  local fetch = lsp_mod.make_fetch(state.client, state.encoding, config.get())
  local d = graph_mod.expand(state.graph, node, fetch)
  d:next(function(g)
    state.graph = g
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: 展开失败: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.change_depth(delta)
  if not state then return end
  state.view_depth = math.max(1, state.view_depth + delta)
  M.rebuild()
end

function M.set_direction(dir)
  if not state or state.direction == dir then return end
  state.direction = dir
  M.rebuild()
end

function M.close()
  if not state then return end
  local orig = state.orig_win
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state = nil
  if orig and vim.api.nvim_win_is_valid(orig) then
    vim.api.nvim_set_current_win(orig)
  end
end

function M.jump_to_def()
  if not state or not state.graph then return end
  local node = state.graph.nodes[state.selected_id]
  if not node or not node.uri then return end
  local orig = state.orig_win
  M.close()
  if orig and vim.api.nvim_win_is_valid(orig) then
    vim.api.nvim_set_current_win(orig)
  end
  if node.range then
    lsp_mod.jump_to_location(node.uri, node.range, state.encoding or 'utf-16')
  end
end

function M.hover_echo()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  local id = box_at(pos[1], pos[2] + 1)
  if id and state.graph then
    local node = state.graph.nodes[id]
    if node then
      local path = vim.uri_to_fname(node.uri or '')
      local line = (node.range and node.range.start and node.range.start.line or 0) + 1
      vim.api.nvim_echo({ { node.name .. '  ' .. path .. ':' .. tostring(line), 'Normal' } }, true, {})
    end
  end
end

function M.on_mouse(clicks)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local m = vim.fn.getmousepos()
  local id = box_at(m.line, m.column)
  if id then
    state.selected_id = id
    M.render_view()
    if clicks >= 2 then M.toggle_expand() end
  end
end

function M.scroll(delta)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local cur = vim.api.nvim_win_get_cursor(state.win)
  local line = math.max(1, math.min(vim.api.nvim_buf_line_count(state.buf), cur[1] + delta))
  vim.api.nvim_win_set_cursor(state.win, { line, cur[2] })
end

function M.show_help()
  vim.notify(table.concat({
    'Callgraph 快捷键',
    '  h/j/k/l / 方向键   移动选中框',
    '  Enter               展开/折叠',
    '  q / Esc             关闭',
    '  r                   刷新',
    '  i / o               callin / callout',
    '  + / -               增加/减少深度',
    '  d                   跳转到定义',
    '  单击选中 / 双击展开  （鼠标）',
  }, '\n'), vim.log.levels.INFO, { title = 'Callgraph' })
end

-- ---------------------------------------------------------------------------
-- Keymaps & autocmds
-- ---------------------------------------------------------------------------

function M.setup_keymaps()
  if state.keyed then return end
  state.keyed = true
  local km = config.get().keymaps
  local buf = state.buf
  local opts = { buffer = buf, silent = true, nowait = true }
  local function set(keys, fn)
    if keys and keys ~= '' then vim.keymap.set('n', keys, fn, opts) end
  end
  set(km.move_left, function() M.move('left') end)
  set(km.move_down, function() M.move('down') end)
  set(km.move_up, function() M.move('up') end)
  set(km.move_right, function() M.move('right') end)
  set(km.move_left_alt, function() M.move('left') end)
  set(km.move_down_alt, function() M.move('down') end)
  set(km.move_up_alt, function() M.move('up') end)
  set(km.move_right_alt, function() M.move('right') end)
  set(km.toggle_expand, function() M.toggle_expand() end)
  set(km.close, function() M.close() end)
  set(km.close_alt, function() M.close() end)
  set(km.refresh, function() M.rebuild() end)
  set(km.to_callin, function() M.set_direction('callin') end)
  set(km.to_callout, function() M.set_direction('callout') end)
  set(km.depth_up, function() M.change_depth(1) end)
  set(km.depth_down, function() M.change_depth(-1) end)
  set(km.jump_to_def, function() M.jump_to_def() end)
  set(km.help, function() M.show_help() end)

  vim.keymap.set('n', '<LeftMouse>', function() M.on_mouse(1) end, opts)
  vim.keymap.set('n', '<2-LeftMouse>', function() M.on_mouse(2) end, opts)
  vim.keymap.set('n', '<ScrollWheelUp>', function() M.scroll(-3) end, opts)
  vim.keymap.set('n', '<ScrollWheelDown>', function() M.scroll(3) end, opts)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function() M.hover_echo() end,
  })
end

return M
