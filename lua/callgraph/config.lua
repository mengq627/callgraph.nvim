--- Default configuration and user-config merging.

local M = {}

M.defaults = {
  -- Maximum depth (number of edges) from the root to fetch/render. It is the
  -- default viewport, not a hard cap: expanding a node reveals deeper levels.
  max_depth = 4,
  -- Show the call-site location (file:line) inside each box.
  show_call_site = true,
  window = {
    max_width_ratio = 0.8,
    max_height_ratio = 0.8,
    border = 'rounded',
    -- Vertical gap between stacked boxes within a column.
    row_gap = 2,
    -- Horizontal gap between columns.
    col_gap = 5,
    -- Box text limits (in characters) before truncation kicks in.
    max_name_width = 26,
    max_loc_width = 22,
  },
  highlights = {
    canvas = 'CallgraphCanvas',
    box = 'CallgraphBox',
    focus = 'CallgraphFocus',
    cycle = 'CallgraphCycle',
    edge = 'CallgraphEdge',
    collapsed = 'CallgraphCollapsed',
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

--- Define highlight groups. `default = true` lets a colorscheme override them.
function M.define_highlights()
  local h = M.get().highlights
  vim.api.nvim_set_hl(0, h.canvas, { default = true, link = 'NormalFloat' })
  vim.api.nvim_set_hl(0, h.box, { default = true, fg = '#5d6478' })
  vim.api.nvim_set_hl(0, h.focus, { default = true, fg = '#e0af68', bg = '#2b2f3c', bold = true })
  vim.api.nvim_set_hl(0, h.cycle, { default = true, fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, h.edge, { default = true, fg = '#3f4659' })
  vim.api.nvim_set_hl(0, h.collapsed, { default = true, fg = '#7aa2f7' })
end

return M
