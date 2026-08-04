--- Render a layout into a scratch buffer: edges first, then boxes on top so
--- boxes stay readable even where an edge would pass underneath. Highlights
--- are applied as extmarks (box/focus/cycle/collapse/edge groups).

local M = {}

-- ns: highlight extmarks (only populated when the `highlight` toggle is on).
-- anchor_ns: one anchor extmark per box at its text start, always populated.
-- The anchor is the source of truth for the text position — cursor placement
-- and highlighting query it via nvim_buf_get_extmarks, so both always land on
-- the exact same character (no off-by-one between them).
M.ns = vim.api.nvim_create_namespace('callgraph')
M.anchor_ns = vim.api.nvim_create_namespace('callgraph_anchors')

local util = require('callgraph.util')

-- Box height in rows (top border, text, bottom border).
local BOX_H = 3

local function make_grid(H, W)
  local grid = {}
  for r = 1, H do
    local row = {}
    for c = 1, W do row[c] = ' ' end
    grid[r] = row
  end
  return grid
end

local function put(grid, r, c, ch)
  if r < 1 or c < 1 then return end
  local row = grid[r]
  if row and c <= #row then row[c] = ch end
end

local function draw_box(grid, b)
  local r, c, w = b.row, b.col, b.width
  local top, bottom = r, r + BOX_H - 1

  put(grid, top, c, '╭')
  put(grid, top, c + w - 1, '╮')
  put(grid, bottom, c, '╰')
  put(grid, bottom, c + w - 1, '╯')
  for i = c + 1, c + w - 2 do
    put(grid, top, i, '─')
    put(grid, bottom, i, '─')
  end
  put(grid, r + 1, c, '│')
  put(grid, r + 1, c + w - 1, '│')

  -- Box text (text row), one character per grid cell.
  local text = b.text
  local col = c + 1
  local last = c + w - 2
  local i, n = 1, #text
  while i <= n do
    local byte = string.byte(text, i)
    local char
    if byte < 0x80 then
      char = string.sub(text, i, i); i = i + 1
    elseif byte < 0xE0 then
      char = string.sub(text, i, i + 1); i = i + 2
    elseif byte < 0xF0 then
      char = string.sub(text, i, i + 2); i = i + 3
    else
      char = string.sub(text, i, i + 3); i = i + 4
    end
    if col <= last then
      grid[r + 1][col] = char
      col = col + 1
    end
  end
end

--- Render `layout` into `buf`.
--- `view` = { selected_id = id, highlights = config.highlights }
function M.render(buf, layout, graph, view)
  local W = math.max(layout.width, 1)
  local H = math.max(layout.height, 1)
  local grid = make_grid(H, W)

  -- Edges first.
  for _, e in ipairs(layout.edges) do
    for _, seg in ipairs(e.segments) do
      for rr = seg.r1, seg.r2 do
        for cc = seg.c1, seg.c2 do
          put(grid, rr, cc, seg.ch)
        end
      end
    end
    if e.arrow then
      put(grid, e.arrow.row, e.arrow.col, e.arrow.ch or '>')
    end
  end

  -- Boxes on top.
  for _, b in pairs(layout.boxes) do
    draw_box(grid, b)
  end

  local lines = {}
  for r = 1, H do lines[r] = table.concat(grid[r]) end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable

  -- Clear stale marks and anchor every box to its text start. nvim_buf_set_extmark
  -- uses BYTE columns, so convert the character index (b.col) to bytes.
  vim.api.nvim_buf_clear_namespace(buf, M.anchor_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  layout.box_marks = {}
  for id, b in pairs(layout.boxes) do
    local line_text = lines[b.row + 1] or ''
    local byte_col = util.char_to_byte(line_text, b.col)
    layout.box_marks[id] = vim.api.nvim_buf_set_extmark(buf, M.anchor_ns, b.row, byte_col, {})
  end

  -- Highlighting is opt-in and defaults to off. When off, no highlight code
  -- runs at all; the canvas is drawn with the default terminal colors.
  if not view.highlight then return end

  -- Only the selected box's function name is colored (not the trailing
  -- location label); box borders and connection lines stay unhighlighted.
  -- Position is taken from the anchor (byte col) so it always matches where
  -- the cursor lands; end is the byte col of (name_start + name_width chars).
  local box = layout.boxes[view.selected_id]
  if box then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.anchor_ns, layout.box_marks[view.selected_id], {})
    if pos then
      local line_text = lines[box.row + 1] or ''
      local end_byte = util.char_to_byte(line_text, box.col + box.name_width)
      vim.api.nvim_buf_set_extmark(buf, M.ns, pos[1], pos[2], {
        end_col = end_byte,
        hl_group = view.highlights.focus,
        priority = 3,
      })
    end
  end
end

return M
