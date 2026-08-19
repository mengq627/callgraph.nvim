--- Default configuration and user-config merging.

local M = {}

M.defaults = {
  -- Maximum depth (number of edges) from the root to fetch/render. It is the
  -- default viewport, not a hard cap: expanding a node reveals deeper levels.
  max_depth = 4,
  -- Show the call-site location (file:line) inside each box.
  show_call_site = true,
  -- Highlight toggle. When true, the selected box's function name is colored
  -- (default green) and its location label dimmed; borders and lines stay
  -- unhighlighted. When false, no highlight code runs at all.
  highlight = true,
  -- Symbol / call-graph sources, in priority order. At startup the plugin
  -- checks which are actually available on this machine (executable + index
  -- present) and only enables those — the check result is cached, so per-query
  -- lookups never re-probe.
  --   lsp    : LSP call hierarchy — language-agnostic, cross-file. Needs a
  --            server implementing outgoingCalls (clangd >= 20).
  --   cscope : cscope database queries (needs `cscope` + cscope.out; C/C++).
  --   ctags  : ctags (needs `ctags` + tags file; reserved, not implemented yet).
  --   auto   : heuristic single-file fallback (body scan / name match).
  sources = { 'lsp', 'auto' },
  window = {
    -- Split position: "right" (vertical split) or "bottom" (horizontal split).
    position = 'bottom',

    -- Right-split maximum width (fraction of the editor), used only when
    -- `fixed_width` is 0.
    max_width_ratio = 0.8,

    -- Fixed window size (0 = fit to content). "right" uses fixed_width in
    -- columns; "bottom" uses fixed_height in rows.
    fixed_width = 80,
    fixed_height = 20,

    -- Vertical gap between stacked boxes within a column.
    row_gap = 2,
    -- Horizontal gap between columns.
    col_gap = 5,
    -- Box text limits (in characters) before truncation kicks in.
    max_name_width = 26,
    max_loc_width = 22,
    -- Arrowhead glyphs (Nerd Font). Default: Font Awesome solid arrows.
    -- Alternatives:
    --   { right='', down='', up='', left='' }  -- FA chevrons（粗 > 风格）
    --   { right='➡', down='⬇', up='⬆', left='⬅' }   -- 重型 Unicode 箭头（无需 Nerd Font）
    --   { right='→', down='↓', up='↑', left='←' }   -- Unicode 带杆（无需 Nerd Font）
    arrows = { right = '', down = '', up = '', left = '' },
  },
  highlights = {
    focus = 'CallgraphFocus', -- selected box text color (used when highlight = true)
    -- Bold the focused function name. Default off: bold causes the text to
    -- look thicker/sharper as the selection moves, which reads as a font
    -- size jump. Turn on for a stronger selection cue.
    focus_bold = false,
    loc = 'CallgraphLoc',     -- file:line label (dimmer)
    tab_active = 'CallgraphTabActive', -- current tab label on the tabline
    tab_inactive = 'CallgraphTabInactive', -- other tab labels on the tabline
  },
  -- All in-view keymaps. Set an entry to '' to disable that binding.
  keymaps = {
    move_left = 'h',
    move_down = 'j',
    move_up = 'k',
    move_right = 'l',
    move_left_alt = '<Left>',
    move_down_alt = '<Down>',
    move_up_alt = '<Up>',
    move_right_alt = '<Right>',
    toggle_expand = '<Space>',
    close = 'q', -- 关闭当前 tab（最后一个 tab 关闭时关闭窗口）
    close_alt = '<Esc>',
    refresh = 'r',
    to_callin = 'i',
    to_callout = 'o',
    depth_up = '+',
    depth_down = '-',
    jump_to_def = '<CR>', -- 跳转到主界面中的函数定义
    jump_to_def_alt = 'd',
    tab_next = '<Tab>', -- 下一个 tab（覆盖 barbar 等全局映射）
    tab_prev = '<S-Tab>', -- 上一个 tab
    help = '?',
  },
}

M.merged = nil

function M.set(opts)
  M.merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

function M.get()
  return M.merged or vim.deepcopy(M.defaults)
end

--- Incrementally update the active config at runtime (used by :CallgraphDebug).
function M.update(opts)
  M.merged = M.merged or vim.deepcopy(M.defaults)
  M.merged = vim.tbl_deep_extend('force', M.merged, opts or {})
end

--- Define highlight groups. `default = true` lets a colorscheme override them.
--- The selected-box `focus` group only matters when `highlight` is on; the
--- tabline groups are always needed (the tab bar renders regardless).
function M.define_highlights()
  local h = M.get().highlights
  if M.get().highlight then
    -- The focus group is always applied (no `default = true`, which would skip
    -- updates once the group exists): focus_bold must take effect reliably.
    local focus_attrs = { fg = '#98c379' }
    if h.focus_bold then focus_attrs.bold = true end
    vim.api.nvim_set_hl(0, h.focus, focus_attrs)
    vim.api.nvim_set_hl(0, h.loc, { fg = '#5c6370' })
  end
  vim.api.nvim_set_hl(0, h.tab_active, { default = true, fg = '#ffffff', bg = '#444444', bold = true })
  vim.api.nvim_set_hl(0, h.tab_inactive, { default = true, fg = '#888888' })
end

return M
