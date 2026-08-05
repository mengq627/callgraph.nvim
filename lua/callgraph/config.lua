--- Default configuration and user-config merging.

local M = {}

M.defaults = {
  -- Maximum depth (number of edges) from the root to fetch/render. It is the
  -- default viewport, not a hard cap: expanding a node reveals deeper levels.
  max_depth = 4,
  -- Show the call-site location (file:line) inside each box.
  show_call_site = true,
  -- Highlight toggle. When true, the selected box's text (name + location)
  -- is colored (default green); borders and lines stay unhighlighted. When
  -- false (default), no highlight code runs at all.
  highlight = true,
  -- When a server lacks call-hierarchy support (clangd < 20 for outgoingCalls),
  -- fall back to heuristics: scan the function body and resolve each call token
  -- (callout), or use references + documentSymbol (callin). Set false to use
  -- only the standard call hierarchy and error when the server can't provide it.
  fallback = true,
  window = {
    -- Right-split maximum width (fraction of the editor).
    max_width_ratio = 0.8,
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
    toggle_expand = '<CR>',
    close = 'q',
    close_alt = '<Esc>',
    refresh = 'r',
    to_callin = 'i',
    to_callout = 'o',
    depth_up = '+',
    depth_down = '-',
    jump_to_def = 'd',
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
--- No-op when the `highlight` toggle is off (no highlight-related work runs).
function M.define_highlights()
  if not M.get().highlight then return end
  local h = M.get().highlights
  vim.api.nvim_set_hl(0, h.focus, { default = true, fg = '#98c379', bold = true })
end

return M
