--- The callgraph view: a right-side split window hosting multiple independent
--- tabs (one per function + direction), a tab bar, fixed-width sizing,
--- buffer-local keymaps, mouse interaction, hover echo, and the async glue
--- between LSP data and the layout/render core.

local config = require('callgraph.config')
local debug = require('callgraph.debug')
local graph_mod = require('callgraph.graph')
local layout_mod = require('callgraph.layout')
local render_mod = require('callgraph.render')
local lsp_mod = require('callgraph.lsp')
local source_mod = require('callgraph.source')
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
      local opts = config.get()
      source_mod.check_available(opts)
      local root, encoding, client = source_mod.resolve_root(bufnr, opts)
      if not root then return end
      M.open_with_root(root, direction, encoding, client)
    end)
    if not ok then
      vim.notify('Callgraph: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

--- Tab identity: arrow before the name = callin, after = callout.
local function tab_key(name, direction, arrows)
  if direction == 'callin' then return arrows.right .. name end
  return name .. arrows.right
end

-- Switch the active tab, remembering the previous one so closing a tab can
-- return to wherever the user was before (temporarily flipping direction with
-- i/o and closing lands back on the originating tab).
local function set_active(i)
  if i ~= state.active then
    state.prev_active = state.active
    state.active = i
  end
end

-- Make the callgraph window the current one. The very first open focuses it
-- via open_float; every later open/reuse must switch focus here so calling
-- :Callout/:Callin from the editor lands in the graph window.
local function focus_view()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  if vim.api.nvim_get_current_win() ~= state.win then
    vim.api.nvim_set_current_win(state.win)
  end
end

-- ---------------------------------------------------------------------------
-- Tab bar on the window's winbar
-- ---------------------------------------------------------------------------

-- Render the logical tabs onto vim.wo[win].winbar, the native window-local
-- top bar. Unlike the global 'tabline' (which would span the whole editor and
-- clash with barbar), the winbar shows only across the callgraph window. Uses
-- statusline syntax; switching tabs is keyboard-driven (<Tab>/<S-Tab>) because
-- winbar has no click targets like 'tabline' does.
local function update_winbar()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local opts = config.get()
  local hl_active = opts.highlights.tab_active
  local hl_inactive = opts.highlights.tab_inactive
  local parts = {}
  for i, t in ipairs(state.tabs) do
    local label = (i == state.active) and ('[' .. t.key .. ']') or t.key
    local hl = (i == state.active) and hl_active or hl_inactive
    parts[#parts + 1] = '%#' .. hl .. '#' .. label .. '%*'
  end
  vim.wo[state.win].winbar = table.concat(parts, '  ')
end

function M.open_with_root(root, direction, encoding, client)
  local opts = config.get()
  local win = vim.api.nvim_get_current_win()
  local key = tab_key(root.name, direction, opts.window.arrows)

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
      encoding = encoding,
      client = client,
      tabs = {},
      active = 0,
      prev_active = nil, -- tab active before the current one
      last_w = nil,
      keyed = false,
    }
    M.open_float()
  else
    if state.win ~= win then
      state.orig_win = win
    end
    state.encoding = encoding
    state.client = client
  end

  -- Same function + same direction -> reuse the tab (jump to it).
  for i, t in ipairs(state.tabs) do
    if t.key == key then
      set_active(i)
      M.render_view()
      M.focus_selected()
      focus_view()
      return
    end
  end

  state.tabs[#state.tabs + 1] = {
    key = key,
    root = root,
    direction = direction,
    view_depth = opts.max_depth,
    graph = nil,
    selected_id = nil,
    last_layout = nil,
  }
  set_active(#state.tabs)
  focus_view()
  M.rebuild()
end

function M.open_float()
  -- Right-side or bottom-side split window (not a float).
  local pos = config.get().window.position
  local split = (pos == 'bottom') and 'below' or 'right'
  local win = vim.api.nvim_open_win(state.buf, true, {
    split = split,
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
-- Tab bar
-- ---------------------------------------------------------------------------

local function active_tab()
  if not state then return nil end
  return state.tabs[state.active]
end

-- ---------------------------------------------------------------------------
-- Build / render pipeline
-- ---------------------------------------------------------------------------

function M.rebuild()
  local tab = active_tab()
  if not tab then return end
  local fetch = source_mod.make_fetch(state.encoding, state.client, config.get())
  local d = graph_mod.build(tab.root, tab.direction, { max_depth = tab.view_depth }, fetch)
  d:next(function(graph)
    tab.graph = graph
    tab.selected_id = graph.root.id
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: graph build failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.render_view()
  local opts = config.get()
  local tab = active_tab()
  if not tab then return end
  local layout = layout_mod.layout(tab.graph, opts, {
    direction = tab.direction,
    selected_id = tab.selected_id,
  })
  tab.last_layout = layout

  -- Resolve canvas colors each render so `auto` picks up the colorscheme, and
  -- mirror the code area's background onto this window.
  local colors = config.resolve_colors()
  config.apply_colors()
  if colors and colors.bg then
    vim.wo[state.win].winhighlight = 'Normal:CallgraphNormal'
  end

  M.resize_window(opts)
  render_mod.render(state.buf, layout, tab.graph, {
    selected_id = tab.selected_id,
    highlight = opts.highlight,
    highlights = opts.highlights,
    arrows = opts.window.arrows,
    collapse_marker = opts.window.collapse_marker,
    colors = colors,
  })
  update_winbar()
  M.focus_selected()
end

function M.resize_window(opts)
  local pos = opts.window.position
  if pos == 'bottom' then
    local fh = opts.window.fixed_height or 0
    local h = fh > 0 and fh or 20
    if h < 3 then h = 3 end
    if state.last_w ~= h then
      state.last_w = h
      vim.api.nvim_win_set_height(state.win, h)
    end
  else
    local fw = opts.window.fixed_width or 0
    local w
    if fw > 0 then
      w = fw
    else
      local tab = active_tab()
      local columns = vim.o.columns
      local mw = math.floor(columns * opts.window.max_width_ratio)
      w = math.min((tab and tab.last_layout and tab.last_layout.width or 10) + 2, mw)
    end
    if w < 3 then w = 3 end
    if state.last_w == w then return end
    state.last_w = w
    vim.api.nvim_win_set_width(state.win, w)
  end
end

function M.focus_selected()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local tab = active_tab()
  if not tab then return end
  local layout = tab.last_layout
  if not layout then return end
  local mark_id = layout.box_marks and layout.box_marks[tab.selected_id]
  if not mark_id then return end
  -- The selected box's text start comes from its anchor extmark (source of
  -- truth), so the cursor always lands on the same character the highlight
  -- covers.
  local pos = vim.api.nvim_buf_get_extmark_by_id(state.buf, render_mod.anchor_ns, mark_id, {})
  if not pos then return end
  -- pos[2] is a BYTE column (nvim_win_set_cursor is byte-based).
  local crow, ccol = pos[1] + 1, pos[2]
  pcall(function()
    vim.api.nvim_win_set_cursor(state.win, { crow, ccol })
    -- Vertically center the cursor line so the 3-row box sits mid-window.
    vim.api.nvim_win_call(state.win, function()
      vim.cmd('normal! zz')
    end)
    -- Keep the focused function name visible with a small margin, scrolling as
    -- little as possible (a full centering scrolls too far and makes the
    -- cursor's on-screen position jump backwards). `vim.wo.scroll` does NOT
    -- control horizontal scroll; the window's left edge is winsaveview().leftcol
    -- (a character column), set via winrestview().
    local box = layout.boxes[tab.selected_id]
    local line_text = vim.api.nvim_buf_get_lines(state.buf, crow - 1, crow, false)[1] or ''
    local char_idx = util.byte_to_char(line_text, ccol)
    if box then
      local winw = vim.api.nvim_win_get_width(state.win)
      local bw = box.width
      local view = vim.api.nvim_win_call(state.win, function()
        return vim.fn.winsaveview()
      end)
      local cur_left = view.leftcol or 0
      local target = cur_left
      local margin = 2
      -- Keep the focused box fully visible when it fits. A box wider than the
      -- window cannot fully fit, so favor the function name (cursor) over
      -- aligning the box's right edge — the old edge-alignment pushed the
      -- cursor out of the window's left side for wide boxes, making the
      -- selection invisible.
      local box_left = char_idx - 1 -- box left border column
      local box_right = char_idx + box.width - 2 -- box right border column
      if box.width <= winw - 2 * margin then
        local bl = box_left - margin
        local br = box_right + margin
        if bl < cur_left then
          target = math.max(0, bl)
        elseif br > cur_left + winw - 1 then
          target = math.max(0, br - winw + 1)
        end
      else
        local want_left = char_idx - margin
        local want_right = char_idx + margin
        if want_left < cur_left then
          target = math.max(0, want_left)
        elseif want_right > cur_left + winw - 1 then
          target = math.max(0, want_right - winw + 1)
        end
      end
      if target ~= cur_left then
        view.leftcol = target
        vim.api.nvim_win_call(state.win, function()
          vim.fn.winrestview(view)
        end)
      end
      local char_at = vim.fn.strcharpart(line_text, char_idx, 1)
      debug.log('location', 'focus_selected', 'anchor=(' .. pos[1] .. ',' .. pos[2] .. ')',
        'cursor=(' .. crow .. ',' .. ccol .. ')', 'char=' .. vim.inspect(char_at), 'box_w=' .. bw,
        'leftcol=' .. target)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

local function box_at(row, col)
  if not state then return nil end
  local tab = active_tab()
  if not tab or not tab.last_layout then return nil end
  for id, b in pairs(tab.last_layout.boxes) do
    if row >= b.row and row <= b.row + b.height - 1 and col >= b.col and col <= b.col + b.width - 1 then
      return id
    end
  end
  return nil
end

function M.move(dir)
  local tab = active_tab()
  if not tab or not tab.last_layout then return end
  local focus = tab.last_layout.boxes[tab.selected_id]
  if not focus then return end
  local fc = focus.col + focus.width / 2
  local fr = focus.row + 1
  local dirs = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }
  local d = dirs[dir]
  if not d then return end
  local dx, dy = d[1], d[2]
  local best, best_score
  for id, b in pairs(tab.last_layout.boxes) do
    if id ~= tab.selected_id then
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
    tab.selected_id = best
    M.render_view()
  end
end

function M.toggle_expand()
  local tab = active_tab()
  if not tab or not tab.graph then return end
  local node = tab.graph.nodes[tab.selected_id]
  if not node then return end
  local fetch = source_mod.make_fetch(state.encoding, state.client, config.get())
  local d = graph_mod.expand(tab.graph, node, fetch)
  d:next(function(g)
    tab.graph = g
    M.render_view()
  end, function(err)
    vim.notify('Callgraph: expand failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

function M.change_depth(delta)
  local tab = active_tab()
  if not tab then return end
  tab.view_depth = math.max(1, tab.view_depth + delta)
  M.rebuild()
end

--- Grow/shrink the view window: width for `right` layout, height for `bottom`.
--- The adjusted size is written back to config so later renders and re-opens
--- keep it.
function M.resize_window_size(delta)
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local opts = config.get()
  local pos = opts.window.position
  local step = (pos == 'right') and 5 or 2
  if pos == 'right' then
    local w = vim.api.nvim_win_get_width(state.win) + delta * step
    local max = math.floor(vim.o.columns * (opts.window.max_width_ratio or 0.8))
    w = math.max(3, math.min(w, max))
    config.update({ window = { fixed_width = w } })
  else
    local h = vim.api.nvim_win_get_height(state.win) + delta * step
    local max = math.max(3, vim.o.lines - 1) -- keep at least one row for the editor
    h = math.max(3, math.min(h, max))
    config.update({ window = { fixed_height = h } })
  end
  M.resize_window(config.get())
end

--- Switch to the other direction for the current root (a different tab).
function M.set_direction(dir)
  local tab = active_tab()
  if not tab or tab.direction == dir then return end
  M.open_with_root(tab.root, dir, state.encoding, state.client)
end

--- Close the active tab; when the last tab closes, close the window.
function M.close_tab()
  if not state then return end
  if #state.tabs <= 1 then
    M.close()
    return
  end
  table.remove(state.tabs, state.active)
  -- Return to the tab that was active before this one (e.g. closing a
  -- direction-flip tab lands back where the user came from). Fall back to the
  -- adjacent tab when there's no recorded previous one or it was removed.
  local target = state.prev_active
  state.prev_active = nil
  if target and target >= 1 and target <= #state.tabs then
    state.active = target
  elseif state.active > #state.tabs then
    state.active = #state.tabs
  end
  M.render_view()
  M.focus_selected()
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
  local tab = active_tab()
  if not tab or not tab.graph then return end
  local node = tab.graph.nodes[tab.selected_id]
  if not node or not node.uri then return end
  -- Keep the view open; only q/Esc closes it. Focus the main window, jump to
  -- the definition there, and leave the callgraph window on screen.
  local orig = state.orig_win
  if orig and vim.api.nvim_win_is_valid(orig) then
    vim.api.nvim_set_current_win(orig)
  end
  -- cscope nodes carry the *call-site* location in uri/range (cscope -L output
  -- is call sites, not definitions). Detect this: when the node's uri/line
  -- matches its call_site, the uri/range point at the caller, not the def — so
  -- lazily look up the real definition via `cscope -1` and jump there.
  local cscope = source_mod.provider('cscope')
  local is_cscope_node = cscope
    and node.call_site
    and node.uri == node.call_site.uri
    and node.range
    and node.range.start
    and node.range.start.line == node.call_site.line
  if is_cscope_node then
    cscope.find_definition(node.name):next(function(def)
      if def then
        lsp_mod.jump_to_location(def.uri,
          { start = { line = def.line, character = 0 }, ['end'] = { line = def.line, character = 0 } },
          state.encoding)
      elseif node.range then
        -- Fallback: jump to the call site if definition lookup fails.
        lsp_mod.jump_to_location(node.uri, node.range, state.encoding)
      end
    end)
    return
  end
  if node.range then
    lsp_mod.jump_to_location(node.uri, node.range, state.encoding)
  end
end

function M.hover_echo()
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  local tab = active_tab()
  local id = box_at(pos[1], pos[2] + 1)
  if id and tab and tab.graph then
    local node = tab.graph.nodes[id]
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
    local tab = active_tab()
    tab.selected_id = id
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
    'Callgraph keymaps',
    '  h/j/k/l / arrows    move selection',
    '  <Space>             expand / collapse',
    '  Enter / d           jump to definition',
    '  q / Esc             close tab',
    '  r                   refresh',
    '  i / o               callin / callout',
    '  + / = -            depth +1 / -1',
    '  > / <               grow / shrink view window',
    '  click / dbl-click   select / expand (mouse)',
    '  Tab / Shift-Tab     switch tab',
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
  set(km.close, function() M.close_tab() end)
  set(km.close_alt, function() M.close_tab() end)
  set(km.refresh, function() M.rebuild() end)
  set(km.to_callin, function() M.set_direction('callin') end)
  set(km.to_callout, function() M.set_direction('callout') end)
  set(km.depth_up, function() M.change_depth(1) end)
  set(km.depth_up_alt, function() M.change_depth(1) end)
  set(km.depth_down, function() M.change_depth(-1) end)
  set(km.win_grow, function() M.resize_window_size(1) end)
  set(km.win_shrink, function() M.resize_window_size(-1) end)
  set(km.jump_to_def, function() M.jump_to_def() end)
  set(km.jump_to_def_alt, function() M.jump_to_def() end)
  -- Tab keys switch between callgraph tabs. These buffer-local bindings
  -- override global ones (e.g. barbar's <Tab> -> BufferNext), so pressing Tab
  -- inside the view cycles tabs instead of leaving it.
  set(km.tab_next, function() M.tab_next() end)
  set(km.tab_prev, function() M.tab_prev() end)
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

--- Cycle to the next tab (wraps around).
function M.tab_next()
  if not state or #state.tabs <= 1 then return end
  local n = #state.tabs
  set_active(state.active % n + 1)
  M.render_view()
  M.focus_selected()
end

--- Cycle to the previous tab (wraps around).
function M.tab_prev()
  if not state or #state.tabs <= 1 then return end
  local n = #state.tabs
  set_active((state.active - 2) % n + 1)
  M.render_view()
  M.focus_selected()
end

return M
