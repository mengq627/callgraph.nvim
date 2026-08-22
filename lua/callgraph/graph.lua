--- Graph construction: build a TREE from LSP call-hierarchy data — every call
--- path expands into its own nodes (no dedup), so the same symbol called from
--- different places appears once per path. This keeps the layout's edges
--- crossing-free and the graph easy to read (see layout.lua).
---
--- The graph is built in *render direction*: for callout the expansion edges
--- follow the call direction (caller -> callee); for callin they follow the
--- reverse (callee -> caller). Nodes carry a path-qualified id and a stable
--- `symbol_id` (uri + name + selection range start). Cycles become terminal
--- leaf nodes carrying the cycle glyph instead of back-edges.
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

--- Create a tree node. `id` is PATH-unique (parent path + symbol id) so the
--- same symbol reached via different call paths becomes distinct boxes;
--- `symbol_id` keeps the stable identity used for cycle detection.
local function new_node(graph, item, depth, parent_id)
  local sym_id = M.node_id(item)
  local n = {
    id = parent_id and (parent_id .. '\0' .. sym_id) or sym_id,
    symbol_id = sym_id,
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
    parents = {}, -- single parent in tree mode
    call_site = nil, -- { uri, line } of the single arriving edge
    children_fetched = false,
    has_children = false,
    is_cycle = false,
    cycle_of = nil,
    visible = depth <= graph.max_depth,
    -- Multiple-definition state (cscope): when a name resolves to more than
    -- one definition the user picks one; chosen_def drives expand filtering
    -- (call sites restricted to that definition's file) and jump-to-def.
    def_pending = false,      -- name has several cscope definitions, not chosen yet
    def_candidates = nil,     -- list of { uri, line } while def_pending
    chosen_def = nil,         -- the user-selected { uri, line }
  }
  graph.next_order = graph.next_order + 1
  return n
end

local function add_edge(graph, parent, child, call_site)
  parent.children[#parent.children + 1] = child.id
  child.parents[#child.parents + 1] = parent.id
  if not child.call_site and call_site then child.call_site = call_site end
end

--- Whether `symbol_id` appears on the call path from `node` up to the root
--- (tree mode: follow the single parent chain).
local function is_ancestor(graph, node, symbol_id)
  local cur = node
  local guard = 0
  while cur and guard < 100000 do
    if cur.symbol_id == symbol_id then return true end
    local p = cur.parents[1]
    cur = p and graph.nodes[p] or nil
    guard = guard + 1
  end
  return false
end

--- Create `node`'s children from fetched `calls` (shared by build_sync,
--- expand_sync and rebuild_node). Handles cycle back-edges; returns the newly
--- created ordinary children so callers can queue / hide them.
local function add_children(graph, node, calls)
  local new_nodes = {}
  local seen = {}
  for _, c in ipairs(calls) do
    local sym_id = M.node_id(c.item)
    if not seen[sym_id] then
      seen[sym_id] = true
      node.has_children = true
      if is_ancestor(graph, node, sym_id) then
        -- Back-edge: close the cycle as a terminal leaf under `node`.
        local cyc_key = node.id .. '\0#cycle\0' .. sym_id
        if not graph.nodes[cyc_key] then
          local cyc = new_node(graph, c.item, node.depth + 1, node.id)
          cyc.id = cyc_key
          cyc.is_cycle = true
          cyc.cycle_of = node.id
          cyc.children_fetched = true
          cyc.has_children = false
          graph.nodes[cyc_key] = cyc
          add_edge(graph, node, cyc, c.call_site)
        end
      else
        -- Tree mode: no dedup — each call path gets its own node.
        local cid = node.id .. '\0' .. sym_id
        if not graph.nodes[cid] then
          local n = new_node(graph, c.item, node.depth + 1, node.id)
          n.id = cid
          graph.nodes[cid] = n
          add_edge(graph, node, n, c.call_site)
          new_nodes[#new_nodes + 1] = n
        end
      end
    end
  end
  return new_nodes
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
      local added = add_children(graph, node, calls)
      for _, n in ipairs(added) do
        if n.depth <= max_depth then queue[#queue + 1] = n end
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
      local added = add_children(graph, c, calls)
      for _, n in ipairs(added) do n.visible = false end -- one level per expand
    end
  end

  recompute_max_visible(graph)
  return graph
end

--- Async wrapper for rebuild_node (its fetch may await async providers).
function M.rebuild(graph, node, fetch)
  local d = util.Deferred.new()
  util.async_start(function()
    local ok, res = pcall(M.rebuild_node, graph, node, fetch)
    if ok then d:resolve(res) else d:reject(res) end
  end)
  return d
end

--- Rebuild `node`'s subtree with a (possibly filtered) fetch: drop its old
--- children and re-query from `node` down to max_depth. Used after the user
--- picks a definition so the expansion reflects that definition's call sites
--- (the view injects a fetch that keeps only calls in the chosen file).
function M.rebuild_node(graph, node, fetch)
  local function drop(n)
    for _, cid in ipairs(n.children) do
      local c = graph.nodes[cid]
      if c then drop(c) end
    end
    graph.nodes[n.id] = nil
  end
  for _, cid in ipairs(node.children) do
    local c = graph.nodes[cid]
    if c then drop(c) end
  end
  node.children = {}
  node.children_fetched = false
  node.has_children = false

  -- BFS rebuild like build_sync.
  local queue = { node }
  local head = 1
  while head <= #queue do
    local n = queue[head]
    head = head + 1
    if not n.is_cycle and n.depth <= graph.max_depth then
      n.children_fetched = true
      local calls = util.await(fetch(n, graph.direction))
      local added = add_children(graph, n, calls)
      for _, c in ipairs(added) do
        if c.depth <= graph.max_depth then queue[#queue + 1] = c end
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
