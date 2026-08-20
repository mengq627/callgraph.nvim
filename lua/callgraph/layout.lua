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

-- Emit a plain axis-aligned run (no glyphs): junction glyphs are resolved at
-- render time so crossings/turns render as proper ┬ ├ ┼ shapes, and the arrow
-- connects to the line through a short dash (`└─→`) instead of floating (`└>`).
local function add_run(segments, r1, c1, r2, c2, dir)
  segments[#segments + 1] = { r1 = r1, c1 = c1, r2 = r2, c2 = c2, dir = dir }
end

local function add_forward_edge(edges, sb, tb)
  local R1 = sb.row + 1
  local R2 = tb.row + 1
  local src_right = sb.col + sb.width - 1
  local tgt_left = tb.col
  local segments = {}
  if R1 == R2 then
    -- straight: dashes up to the arrowhead at the child's left gap
    if tgt_left - 2 >= src_right + 1 then
      add_run(segments, R1, src_right + 1, R1, tgt_left - 2, 'h')
    end
  else
    -- Vertical channel near the source: a same-row (straight) edge runs
    -- continuously from the branch point to the target. (The junction glyphs
    -- were previously swapped in render.lua, which made the branch stub stick
    -- out left of the vertical line — that is fixed there.)
    local xj = src_right + 2
    if xj > tgt_left - 3 then xj = tgt_left - 3 end
    if xj >= src_right + 1 then
      add_run(segments, R1, src_right + 1, R1, xj, 'h')
    end
    if R1 < R2 then
      add_run(segments, R1, xj, R2, xj, 'v')
    else
      add_run(segments, R2, xj, R1, xj, 'v')
    end
    -- connector to the cell before the arrowhead; includes the corner cell
    if tgt_left - 2 >= xj then
      add_run(segments, R2, xj, R2, tgt_left - 2, 'h')
    end
  end
  edges[#edges + 1] = { segments = segments, arrow = { row = R2, col = tgt_left - 1, dir = 'r' } }
end

--- Compute the full layout for a graph (tree mode).
function M.layout(graph, opts, view_state)
  local win = opts.window
  local max_name_width = win.max_name_width
  local max_loc_width = win.max_loc_width
  local show_call_site = opts.show_call_site
  local row_gap = win.row_gap
  local col_gap = win.col_gap

  local max_depth = graph.max_visible_depth
  local function col_of(node)
    local d = node.depth
    if graph.direction == 'callin' then return max_depth - d end
    return d
  end

  -- Per-node display text and marker positions (iterate the tree, no sort).
  local texts = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      local name = util.truncate(n.name or '?', max_name_width)
      local cycle_str = ''
      if n.is_cycle then cycle_str = ' ⟳' end
      local loc_str = ''
      local label = text_label(graph, n, show_call_site, max_loc_width)
      if label then loc_str = ' ' .. label end
      local coll_str = ''
      if n.has_children and not all_children_visible(graph, n) then coll_str = ' ' .. win.collapse_marker end

      local text = name .. cycle_str .. loc_str .. coll_str
      texts[n.id] = { text = text, name_width = util.char_count(name) }
    end
  end

  -- Size each depth column by its widest visible box.
  local col_width = {}
  local max_col = 0
  for id, n in pairs(graph.nodes) do
    if n.visible then
      local c = col_of(n)
      if c > max_col then max_col = c end
      local tw = util.char_count(texts[id].text)
      col_width[c] = math.max(col_width[c] or 0, tw + 2)
    end
  end

  local col_x = {}
  local x = 3 -- left margin (room for edge arrows / verticals into column 0)
  for c = 0, max_col do
    col_x[c] = x
    x = x + (col_width[c] or 0) + col_gap
  end

  -- Tree layout: rows are assigned by a post-order DFS so each node's subtree
  -- occupies a contiguous vertical band and sibling subtrees never overlap.
  -- That keeps every parent->child L-shaped edge inside its own band — no
  -- shared vertical channels, no crossings.
  local boxes = {}
  local max_bottom = 0
  local y_cursor = 1
  local function make_box(node, c, row)
    local w = col_width[c] or 0
    local t = texts[node.id]
    local box = {
      id = node.id,
      row = row,
      col = col_x[c],
      width = w,
      height = BOX_H,
      text = t.text,
      text_width = util.char_count(t.text),
      name_width = t.name_width,
      -- Function-name span in 0-based buffer columns: [name_start, name_end).
      -- Only the name is highlighted (not the trailing location label).
      name_start = col_x[c],
      name_end = col_x[c] + t.name_width,
    }
    boxes[node.id] = box
    if row + BOX_H - 1 > max_bottom then max_bottom = row + BOX_H - 1 end
    return box
  end
  local function place(node)
    local children = {}
    for _, cid in ipairs(node.children) do
      local ch = graph.nodes[cid]
      if ch and ch.visible then children[#children + 1] = ch end
    end
    local top, bottom
    if #children == 0 then
      top, bottom = y_cursor, y_cursor
      y_cursor = y_cursor + BOX_H + row_gap
    else
      for _, ch in ipairs(children) do
        local t, b = place(ch)
        if not top then top = t end
        bottom = b
      end
      -- Align the parent to its first child's top so its outgoing edges fan
      -- top-down to every child.
      top = boxes[children[1].id].row
    end
    make_box(node, col_of(node), top)
    return top, bottom
  end
  place(graph.root)

  local gutter_row = max_bottom + 2
  local height = gutter_row + 1
  local width = x - col_gap + 1 -- right margin
  if width < 1 then width = 1 end

  -- Route edges: parent -> child between adjacent columns. For callin the
  -- parent (deeper) sits right of its callers, so swap to keep the left box
  -- as the source of the L-shaped edge.
  local edges = {}
  for id, n in pairs(graph.nodes) do
    if n.visible then
      for _, cid in ipairs(n.children) do
        local c = graph.nodes[cid]
        if c and c.visible then
          local s, t = n, c
          local sb, tb = boxes[s.id], boxes[t.id]
          if sb and tb then
            if sb.col > tb.col then s, t = t, s; sb, tb = tb, sb end
            if sb.col < tb.col then
              add_forward_edge(edges, sb, tb)
            end
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
