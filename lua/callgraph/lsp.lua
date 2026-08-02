--- LSP adapter: root resolution, documentSymbol background cache, and the
--- call-hierarchy fetcher injected into graph building.
---
--- Root resolution priority: (1) the symbol under the cursor reported by
--- `prepareCallHierarchy`; (2) fallback to the innermost enclosing function
--- found via `documentSymbol`; (3) error.

local util = require('callgraph.util')
local graph_mod = require('callgraph.graph')

local M = {}

-- bufnr -> { tick = changedtick, tree = DocumentSymbol[] }
local symbol_cache = {}

local function find_client(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, c in ipairs(clients) do
    if c.supports_method and c.supports_method(method, bufnr) then
      return c
    end
  end
  return nil
end

--- Background documentSymbol cache, fired on LspAttach. Does not block
--- opening a file; the request is issued and forgotten.
function M.ensure_document_symbol(bufnr)
  local client = find_client(bufnr, 'textDocument/documentSymbol')
  if not client then return end
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  client.request('textDocument/documentSymbol', params, function(err, result)
    if err or not result then return end
    symbol_cache[bufnr] = { tick = vim.b[bufnr].changedtick or 0, tree = result }
  end, bufnr)
end

local function contains(range, line, char)
  if not range then return false end
  local s, e = range.start, range['end']
  if line < s.line or line > e.line then return false end
  if line == s.line and char < s.character then return false end
  if line == e.line and char > e.character then return false end
  return true
end

--- Innermost enclosing function-like symbol under `cursor` (1-based row).
--- Must be called from a coroutine (uses util.await).
local function enclosing_function_at(bufnr, cursor, encoding)
  local cache = symbol_cache[bufnr]
  local tick = vim.b[bufnr].changedtick or 0
  if not cache or cache.tick ~= tick then
    local client = find_client(bufnr, 'textDocument/documentSymbol')
    if not client then return nil end
    local d = util.Deferred.new()
    client.request('textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, function(err, result)
      if err or not result then d:resolve(nil) else d:resolve(result) end
    end, bufnr)
    local tree = util.await(d)
    if not tree then return nil end
    symbol_cache[bufnr] = { tick = tick, tree = tree }
    cache = symbol_cache[bufnr]
  end

  local line = cursor[1] - 1
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''
  local char = util.byte_to_pos(line_text, cursor[2], encoding)

  local found
  local function walk(symbols)
    for _, s in ipairs(symbols or {}) do
      if contains(s.range, line, char) then
        walk(s.children)
        if not found and graph_mod.is_function_kind(s.kind) then
          found = s
        end
      end
    end
  end
  walk(cache.tree)
  return found
end

--- Resolve the "current function" for `bufnr`. Returns root item, offset
--- encoding, and the client used. Must be called from a coroutine.
function M.resolve_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local client = find_client(bufnr, 'textDocument/prepareCallHierarchy')
  if not client then
    vim.notify('Callgraph: 没有支持 call hierarchy 的语言服务器（C 请使用 clangd）', vim.log.levels.WARN)
    return nil, nil, nil
  end
  local encoding = client.offset_encoding or 'utf-16'
  local win = vim.fn.bufwinid(bufnr)
  if win < 0 then win = 0 end
  local params = vim.lsp.util.make_position_params(win, encoding)

  local d = util.Deferred.new()
  client.request('textDocument/prepareCallHierarchy', params, function(err, result)
    if err then
      d:reject(err)
    else
      local items
      if result then
        if type(result) == 'table' and result[1] then items = result else items = { result } end
      end
      d:resolve(items)
    end
  end, bufnr)
  local items = util.await(d)

  if items and #items > 0 and graph_mod.is_function_kind(items[1].kind) then
    return items[1], encoding, client
  end

  -- Fallback: enclosing function.
  local node = enclosing_function_at(bufnr, vim.api.nvim_win_get_cursor(win), encoding)
  if node then
    return {
      name = node.name,
      kind = 12,
      uri = vim.uri_from_bufnr(bufnr),
      range = node.range,
      selectionRange = node.selectionRange,
    }, encoding, client
  end
  return nil, nil, nil
end

--- Create the fetch function injected into graph building. Issues the
--- incoming/outgoing call request on `client` and returns a Deferred resolving
--- to `{ item, call_site }` entries.
function M.make_fetch(client, encoding)
  return function(node, direction)
    local d = util.Deferred.new()
    -- Pass the item through verbatim (including the server's opaque `data`
    -- field) — clangd resolves the symbol via that data on later requests.
    local item = node.item or {
      name = node.name,
      kind = node.kind,
      uri = node.uri,
      range = node.range,
      selectionRange = node.selectionRange,
    }
    -- Note: only prepareCallHierarchy uses the textDocument/ prefix; the
    -- incoming/outgoing calls are callHierarchy/* methods in the LSP spec.
    local method = direction == 'callout' and 'callHierarchy/outgoingCalls' or 'callHierarchy/incomingCalls'
    client.request(method, { item = item }, function(err, result)
      if err then
        -- clangd < 20 advertises call hierarchy but does not implement
        -- outgoingCalls; turn the opaque -32601 into something actionable.
        if err.code == -32601 or (err.message and err.message:find('method not found')) then
          d:reject('语言服务器未实现 ' .. method .. '（clangd 的 outgoingCalls 需要 LLVM ≥ 20，callin/incomingCalls 通常可用）')
        else
          d:reject(err)
        end
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
      d:resolve(calls)
    end, vim.uri_to_bufnr(node.uri))
    return d
  end
end

--- Jump to a definition location, converting the LSP position to buffer bytes.
function M.jump_to_location(uri, range, offset_encoding)
  if not range or not range.start then return end
  local fname = vim.uri_to_fname(uri)
  local buf = vim.fn.bufadd(fname)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  local line_text = vim.api.nvim_buf_get_lines(buf, range.start.line, range.start.line + 1, false)[1] or ''
  local byte_col = util.pos_to_byte(line_text, range.start.character, offset_encoding or 'utf-16')
  vim.api.nvim_win_set_cursor(0, { range.start.line + 1, byte_col })
  vim.cmd('normal! zz')
end

return M
