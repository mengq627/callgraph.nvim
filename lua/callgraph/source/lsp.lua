--- LSP call-hierarchy source: the language-agnostic, cross-file provider.
--- Used when `lsp` is enabled in `config.sources` and a server that supports
--- prepareCallHierarchy is attached. If the server does not implement the
--- outgoing/incoming method (e.g. clangd < 20 for outgoingCalls) the fetch
--- resolves empty so the source manager can fall through to the next source.

local util = require('callgraph.util')

local M = {}

--- Available when the user enables `lsp` — the actual presence of a capable
--- client is enforced upstream by root resolution (resolve_root errors when no
--- server supports call hierarchy), and at fetch time a nil client resolves
--- empty so the manager falls through to the next source.
function M.available(opts)
  return true
end

local function standard_fetch(client, encoding, node, direction)
  local d = util.Deferred.new()
  local item = node.item or {
    name = node.name,
    kind = node.kind,
    uri = node.uri,
    range = node.range,
    selectionRange = node.selectionRange,
  }
  -- Only prepareCallHierarchy uses the textDocument/ prefix; the incoming /
  -- outgoing calls are callHierarchy/* methods in the LSP spec.
  local method = direction == 'callout' and 'callHierarchy/outgoingCalls' or 'callHierarchy/incomingCalls'
  client.request(method, { item = item }, function(err, result)
    if err then
      -- e.g. clangd < 20 has no outgoingCalls (-32601): resolve empty so the
      -- source manager falls through to the next configured source.
      d:resolve({ calls = {} })
      return
    end
    local calls = {}
    for _, c in ipairs(result or {}) do
      local citem = direction == 'callout' and c.to or c.from
      local cs = nil
      if c.fromRanges and c.fromRanges[1] then
        cs = { uri = citem.uri, line = c.fromRanges[1].start.line }
      end
      calls[#calls + 1] = { item = citem, call_site = cs }
    end
    d:resolve({ calls = calls })
  end, vim.uri_to_bufnr(node.uri))
  return d
end

--- Create the fetch function: node, direction -> Deferred(calls).
function M.make_fetch(encoding, client, opts)
  return function(node, direction)
    local d = util.Deferred.new()
    util.async_start(function()
      local ok, res = pcall(function()
        return util.await(standard_fetch(client, encoding, node, direction))
      end)
      if ok then d:resolve(res.calls or {}) else d:resolve({}) end
    end)
    return d
  end
end

return M
