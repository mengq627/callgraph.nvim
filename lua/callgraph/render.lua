--- Render a layout into a scratch buffer: edges first, then boxes on top so
--- boxes stay readable even where an edge would pass underneath. Highlights
--- are applied as extmarks (box/focus/cycle/collapse/edge groups).

local M = {}

M.ns = vim.api.nvim_create_namespace('callgraph')

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

  -- Highlighting is opt-in and defaults to off. When off, no highlight code
  -- runs at all; the canvas is drawn with the default terminal colors.
  if not view.highlight then return end

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  -- Only the selected box's text content (name + location) is colored; box
  -- borders and connection lines stay unhighlighted.
  local box = layout.boxes[view.selected_id]
  if box then
    vim.api.nvim_buf_set_extmark(buf, M.ns, box.row, box.col, {
      end_col = box.col + box.text_width,
      hl_group = view.highlights.focus,
      priority = 2,
    })
  end
end

return M
