--- Layered layout for a callgraph: nodes are stacked in columns by depth and
--- edges are routed orthogonally. For callout the root sits in the leftmost
--- column; for callin the whole graph is mirrored (root rightmost). Edge
--- arrows always point at the callee (the right-hand box).
---
--- Pure computation: input graph + opts, output boxes/edges geometry. No
--- window or buffer interaction.

local util = require('callgraph.util')

local M = {}

local BOX_H = 3 -- top border, text row, bottom border

local function text_label(graph, n, show_call_site, max_loc_width)
  if not show_call_site then return nil end
  local loc
  if n == graph.root and n.uri and n.range then
    local path = vim.uri_to_fname(n.uri)
    loc = vim.fn.fnamemodify(path, ':t') .. ':' .. tostring((n.range.start.line or 0) + 1)
  elseif n.call_site then
    local path = vim.uri_to_fname(n.call_site.uri)
    loc = vim.fn.fnamemodify(path, ':t') .. ':' .. tostring(n.call_site.line + 1)
  end
  if not loc then return nil end
  return util.truncate(loc, max_loc_width)
end

local function all_children_visible(graph, n)
  for _, cid in ipairs(n.children) do
    local c = graph.nodes[cid]
    if c and not c.visible then return false end
  end
  return true
end

local function add_forward_edge(edges, sb, tb)
  local R1 = sb.row + 1
  local R2 = tb.row + 1
  local src_right = sb.col + sb.width - 1
  local tgt_left = tb.col
  local xj = tgt_left - 2
  if xj < src_right + 1 then xj = src_right + 1 end
  local segments = {}
  if R1 == R2 then
    if tgt_left - 2 >= src_right + 1 then
      segments[#segments + 1] = { r1 = R1, c1 = src_right + 1, r2 = R1, c2 = tgt_left - 2, ch = '─' }
    end
  elseif R1 < R2 then
    if xj - 1 >= src_right + 1 then
      segments[#segments + 1] = { r1 = R1, c1 = src_right + 1, r2 = R1, c2 = xj - 1, ch = '─' }
    end
    segments[#segments + 1] = { r1 = R1, c1 = xj, r2 = R1, c2 = xj, ch = '┐' }
    if R2 - R1 > 1 then
      segments[#segments + 1] = { r1 = R1 + 1, c1 = xj, r2 = R2 - 1, c2 = xj, ch = '│' }
    end
    segments[#segments + 1] = { r1 = R2, c1 = xj, r2 = R2, c2 = xj, ch = '└' }
  else
    if xj - 1 >= src_right + 1 then
      segments[#segments + 1] = { r1 = R1, c1 = src_right + 1, r2 = R1, c2 = xj - 1, ch = '─' }
    end
    segments[#segments + 1] = { r1 = R1, c1 = xj, r2 = R1, c2 = xj, ch = '┘' }
    if R1 - R2 > 1 then
      segments[#segments + 1] = { r1 = R2 + 1, c1 = xj, r2 = R1 - 1, c2 = xj, ch = '│' }
    end
    segments[#segments + 1] = { r1 = R2, c1 = xj, r2 = R2, c2 = xj, ch = '┌' }
  end
  edges[#edges + 1] = { segments = segments, arrow = { row = R2, col = tgt_left - 1 } }
end

--- Same-column edge: straight vertical between the caller box and the callee
--- box (same column). The arrow always points INTO the callee; its glyph is
--- derived from the relative rows so either stacking order renders correctly.
--- If a box sits between them the line passes behind it (edges are drawn
--- before boxes), acceptable for the rare same-column case.
local function add_same_column_edge(edges, caller_box, callee_box)
  local segments = {}
  local ex = caller_box.col + math.floor(caller_box.width / 2)
  if callee_box.row > caller_box.row then
    -- callee below: line from caller bottom down, arrow v into callee top
    local line_top = caller_box.row + caller_box.height
    local line_bottom = callee_box.row - 2
    if line_bottom >= line_top then
      segments[#segments + 1] = { r1 = line_top, c1 = ex, r2 = line_bottom, c2 = ex, ch = '│' }
    end
    edges[#edges + 1] = { segments = segments, arrow = { row = callee_box.row - 1, col = ex, ch = 'v' } }
  else
    -- callee above: line from caller top up, arrow ^ into callee bottom
    local line_top = caller_box.row - 1
    local line_bottom = callee_box.row + callee_box.height + 1
    if line_top >= line_bottom then
      segments[#segments + 1] = { r1 = line_bottom, c1 = ex, r2 = line_top, c2 = ex, ch = '│' }
    end
    edges[#edges + 1] = { segments = segments, arrow = { row = callee_box.row + callee_box.height, col = ex, ch = '^' } }
  end
end

--- Compute the full layout for a graph.
function M.layout(graph, opts, view_state)
  local win = opts.window
  local max_name_width = win.max_name_width
  local max_loc_width = win.max_loc_width
  local show_call_site = opts.show_call_site
  local row_gap = win.row_gap
  local col_gap = win.col_gap

  -- Visible nodes in BFS discovery order.
  local visible = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then visible[#visible + 1] = n end
  end
  table.sort(visible, function(a, b) return a.order < b.order end)

  local max_depth = graph.max_visible_depth
  local function col_of(node)
    local d = node.depth
    if graph.direction == 'callin' then return max_depth - d end
    return d
  end

  -- Per-node display text and marker positions.
  local texts = {}
  for _, n in ipairs(visible) do
    local name = util.truncate(n.name or '?', max_name_width)
    local cycle_str = ''
    if n.is_cycle then cycle_str = ' ⟳' end
    local loc_str = ''
    local label = text_label(graph, n, show_call_site, max_loc_width)
    if label then loc_str = ' ' .. label end
    local coll_str = ''
    if n.has_children and not all_children_visible(graph, n) then coll_str = ' ▸' end

    local text = name .. cycle_str .. loc_str .. coll_str
    texts[n.id] = { text = text }
  end

  -- Group into columns and size each column.
  local layers = {}
  local col_width = {}
  local max_col = 0
  for _, n in ipairs(visible) do
    local c = col_of(n)
    if c > max_col then max_col = c end
    layers[c] = layers[c] or {}
    layers[c][#layers[c] + 1] = n
    local tw = util.char_count(texts[n.id].text)
    col_width[c] = math.max(col_width[c] or 0, tw + 2)
  end

  local col_x = {}
  local x = 3 -- left margin (room for edge arrows / verticals into column 0)
  for c = 0, max_col do
    col_x[c] = x
    x = x + (col_width[c] or 0) + col_gap
  end

  -- Stack boxes within each column, all columns starting at the top.
  local boxes = {}
  local max_bottom = 0
  for c = 0, max_col do
    local cy = 1
    for _, n in ipairs(layers[c] or {}) do
      local w = col_width[c] or 0
      local t = texts[n.id]
      boxes[n.id] = {
        id = n.id,
        row = cy,
        col = col_x[c],
        width = w,
        height = BOX_H,
        text = t.text,
        text_width = util.char_count(t.text),
      }
      if cy + BOX_H - 1 > max_bottom then max_bottom = cy + BOX_H - 1 end
      cy = cy + BOX_H + row_gap
    end
  end

  local gutter_row = max_bottom + 2
  local height = gutter_row + 1
  local width = x - col_gap + 1 -- right margin
  if width < 1 then width = 1 end

  -- Route edges between visible pairs. The left box is always the source.
  local edges = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      for _, cid in ipairs(n.children) do
        local c = graph.nodes[cid]
        if c and c.visible then
          local s, t = n, c
          local sb, tb = boxes[s.id], boxes[t.id]
          if sb.col > tb.col then s, t = t, s; sb, tb = tb, sb end
          if sb.col < tb.col then
            add_forward_edge(edges, sb, tb)
          else
            -- same column: sb is the parent box, tb the child box. The callee
            -- is the child for callout, the parent for callin (its children
            -- are callers).
            local caller_box, callee_box
            if graph.direction == 'callout' then
              caller_box, callee_box = sb, tb
            else
              caller_box, callee_box = tb, sb
            end
            add_same_column_edge(edges, caller_box, callee_box)
          end
        end
      end
    end
  end

  return {
    width = width,
    height = height,
    boxes = boxes,
    edges = edges,
    gutter_row = gutter_row,
    max_col = max_col,
  }
end

return M
