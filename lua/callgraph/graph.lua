--- Graph construction: build a deduplicated DAG from LSP call-hierarchy data.
---
--- The graph is built in *render direction*: for callout the expansion edges
--- follow the call direction (caller -> callee); for callin they follow the
--- reverse (callee -> caller). Nodes are identified by (uri, name, selection
--- range start) and merged (true DAG, min-depth placement). Cycles become
--- terminal leaf nodes carrying the cycle glyph instead of back-edges.
---
--- The module is pure with respect to LSP: it receives a `fetch(node,
--- direction)` function that returns a Deferred resolving to a list of
--- `{ item, call_site }`. This keeps the core testable headlessly with a fake
--- fetch, and lets the async orchestration live entirely in the coroutine.

local util = require('callgraph.util')

local M = {}

local KIND_FUNCTION = 12
local KIND_METHOD = 6
local KIND_CONSTRUCTOR = 9

function M.is_function_kind(kind)
  return kind == KIND_FUNCTION or kind == KIND_METHOD or kind == KIND_CONSTRUCTOR
end

--- Stable identity for a call-hierarchy item.
function M.node_id(item)
  local s = item.selectionRange and item.selectionRange.start
  return table.concat({
    item.uri or '',
    '\0',
    item.name or '',
    '\0',
    tostring(s and s.line),
    '\0',
    tostring(s and s.character),
  })
end

local function new_node(graph, item, depth)
  local n = {
    id = M.node_id(item),
    -- Keep the original item verbatim: LSP call-hierarchy items carry an
    -- opaque `data` field that servers (clangd) require on later requests.
    item = item,
    name = item.name,
    uri = item.uri,
    kind = item.kind,
    range = item.range,
    selectionRange = item.selectionRange,
    depth = depth,
    order = graph.next_order,
    children = {}, -- render-direction children (callout: callees; callin: callers)
    parents = {}, -- opposite direction
    call_site = nil, -- { uri, line } of the first arriving edge
    children_fetched = false,
    has_children = false,
    is_cycle = false,
    cycle_of = nil,
    visible = depth <= graph.max_depth,
  }
  graph.next_order = graph.next_order + 1
  return n
end

local function add_edge(graph, parent, child, call_site)
  local dup = false
  for i = 1, #parent.children do
    if parent.children[i] == child.id then dup = true; break end
  end
  if not dup then parent.children[#parent.children + 1] = child.id end

  dup = false
  for i = 1, #child.parents do
    if child.parents[i] == parent.id then dup = true; break end
  end
  if not dup then
    child.parents[#child.parents + 1] = parent.id
    if not child.call_site and call_site then child.call_site = call_site end
  end
end

local function first_parent(graph, node)
  if #node.parents == 0 then return nil end
  return graph.nodes[node.parents[1]]
end

--- Whether `candidate_id` appears on the build path from `node` up to the root.
--- The first parent recorded is the path the BFS took, which is a valid
--- ancestor chain for cycle detection (see build_sync).
local function is_ancestor(graph, node, candidate_id)
  local cur = node
  local guard = 0
  while cur and guard < 100000 do
    if cur.id == candidate_id then return true end
    cur = first_parent(graph, cur)
    guard = guard + 1
  end
  return false
end

local function recompute_max_visible(graph)
  local md = -1
  for _, n in pairs(graph.nodes) do
    if n.visible and n.depth > md then md = n.depth end
  end
  graph.max_visible_depth = math.max(md, 0)
end

-- ---------------------------------------------------------------------------

--- Build the graph. Returns a Deferred resolving to the graph object.
--- `opts.max_depth` is the number of levels fetched; nodes at that depth are
--- fetched (so their children/cycle state is known for the collapse marker)
--- but their children are created hidden.
function M.build(root, direction, opts, fetch)
  local d = util.Deferred.new()
  util.async_start(function()
    local ok, res = pcall(M.build_sync, root, direction, opts, fetch)
    if ok then d:resolve(res) else d:reject(res) end
  end)
  return d
end

function M.build_sync(root, direction, opts, fetch)
  local max_depth = opts.max_depth
  local graph = {
    direction = direction,
    root = nil,
    nodes = {},
    max_depth = max_depth,
    next_order = 0,
    max_visible_depth = 0,
  }

  local rn = new_node(graph, root, 0)
  graph.nodes[rn.id] = rn
  graph.root = rn

  -- Breadth-first expansion. Processing strictly by depth guarantees that a
  -- node is first created at its minimum depth (min-depth placement).
  local queue = { rn }
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    if not node.is_cycle and node.depth <= max_depth then
      node.children_fetched = true
      local calls = util.await(fetch(node, direction))
      local seen = {}
      for _, c in ipairs(calls) do
        local cid = M.node_id(c.item)
        if not seen[cid] then
          seen[cid] = true
          node.has_children = true
          local existing = graph.nodes[cid]
          if existing then
            if is_ancestor(graph, node, cid) then
              -- Back-edge: close the cycle as a terminal leaf under `node`.
              -- Give it a distinct id so it never collides with the original.
              local cyc_key = cid .. '\0#cycle\0' .. node.id
              if not graph.nodes[cyc_key] then
                local cyc = new_node(graph, c.item, node.depth + 1)
                cyc.id = cyc_key
                cyc.is_cycle = true
                cyc.cycle_of = existing.id
                cyc.children_fetched = true
                cyc.has_children = false
                graph.nodes[cyc_key] = cyc
                add_edge(graph, node, cyc, c.call_site)
              end
            else
              -- Diamond: merge into the existing node, keep min depth.
              add_edge(graph, node, existing, c.call_site)
              if existing.depth > node.depth + 1 then
                existing.depth = node.depth + 1
              end
            end
          else
            local n = new_node(graph, c.item, node.depth + 1)
            graph.nodes[cid] = n
            add_edge(graph, node, n, c.call_site)
            if n.depth <= max_depth then queue[#queue + 1] = n end
          end
        end
      end
    end
  end

  recompute_max_visible(graph)
  return graph
end

--- Toggle a node's children: collapse its subtree if expanded, otherwise reveal
--- its children (fetching grandchildren on demand so collapse markers appear).
--- Returns a Deferred resolving to the (mutated) graph.
function M.expand(graph, node, fetch)
  local d = util.Deferred.new()
  util.async_start(function()
    local ok, err = pcall(M.expand_sync, graph, node, fetch)
    if ok then d:resolve(graph) else d:reject(err) end
  end)
  return d
end

function M.expand_sync(graph, node, fetch)
  if node.is_cycle then return graph end

  local all_visible = true
  for _, cid in ipairs(node.children) do
    local c = graph.nodes[cid]
    if c and not c.visible then all_visible = false; break end
  end

  if all_visible and #node.children > 0 then
    M.collapse_subtree(graph, node)
    return graph
  end

  -- Expand: reveal direct children.
  for _, cid in ipairs(node.children) do
    local c = graph.nodes[cid]
    if c and not c.visible then c.visible = true end
  end

  -- Fetch one level below the newly shown children so they can show their own
  -- collapse markers, and so cycles there are still caught.
  for _, cid in ipairs(node.children) do
    local c = graph.nodes[cid]
    if c and not c.is_cycle and not c.children_fetched then
      c.children_fetched = true
      local calls = util.await(fetch(c, graph.direction))
      local seen = {}
      for _, cc in ipairs(calls) do
        local ccid = M.node_id(cc.item)
        if not seen[ccid] then
          seen[ccid] = true
          c.has_children = true
          if graph.nodes[ccid] then
            local existing = graph.nodes[ccid]
            if is_ancestor(graph, c, ccid) then
              local cyc_key = ccid .. '\0#cycle\0' .. c.id
              if not graph.nodes[cyc_key] then
                local cyc = new_node(graph, cc.item, c.depth + 1)
                cyc.id = cyc_key
                cyc.is_cycle = true
                cyc.cycle_of = existing.id
                cyc.children_fetched = true
                cyc.has_children = false
                graph.nodes[cyc_key] = cyc
                add_edge(graph, c, cyc, cc.call_site)
              end
            else
              add_edge(graph, c, existing, cc.call_site)
            end
          else
            local n = new_node(graph, cc.item, c.depth + 1)
            n.visible = false -- one level per expand
            graph.nodes[ccid] = n
            add_edge(graph, c, n, cc.call_site)
          end
        end
      end
    end
  end

  recompute_max_visible(graph)
  return graph
end

--- Hide a node and its visible subtree (nodes stay in the graph, just hidden).
function M.collapse_subtree(graph, node)
  local function hide(n)
    for _, cid in ipairs(n.children) do
      local c = graph.nodes[cid]
      if c and c.visible then
        c.visible = false
        hide(c)
      end
    end
  end
  hide(node)
  recompute_max_visible(graph)
end

return M
