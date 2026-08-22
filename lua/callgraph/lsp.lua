--- LSP adapter: root resolution, documentSymbol background cache, and the
--- call-hierarchy fetcher injected into graph building.
---
--- Root resolution priority: (1) the symbol under the cursor reported by
--- `prepareCallHierarchy`; (2) fallback to the innermost enclosing function
--- found via `documentSymbol`; (3) error.

local util = require('callgraph.util')
local graph_mod = require('callgraph.graph')

local M = {}

local function notify_once(key, msg)
  if not vim.g['callgraph_notified_' .. key] then
    vim.g['callgraph_notified_' .. key] = true
    vim.notify(msg, vim.log.levels.INFO, { title = 'Callgraph' })
  end
end

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

--- documentSymbol tree for `bufnr`, cached and refreshed on change.
--- Must be called from a coroutine (uses util.await).
function M.get_symbol_tree(bufnr, encoding)
  local cache = symbol_cache[bufnr]
  local tick = vim.b[bufnr].changedtick or 0
  if cache and cache.tick == tick then return cache.tree end
  local client = find_client(bufnr, 'textDocument/documentSymbol')
  if not client then return nil end
  local d = util.Deferred.new()
  client.request('textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, function(err, result)
    if err or not result then d:resolve(nil) else d:resolve(result) end
  end, bufnr)
  local tree = util.await(d)
  if tree then symbol_cache[bufnr] = { tick = tick, tree = tree } end
  return tree
end

--- Innermost enclosing function-like symbol under `cursor` (1-based row).
--- Must be called from a coroutine (uses util.await).
function M.enclosing_function_at(bufnr, cursor, encoding)
  local tree = M.get_symbol_tree(bufnr, encoding)
  if not tree then return nil end

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
  walk(tree)
  return found
end

--- First function-like symbol named `name` in `bufnr`, preferring shallower
--- nesting (top-level first). Used when the server cannot resolve a call token.
--- Must be called from a coroutine (uses util.await).
function M.find_functions_by_name(bufnr, name, encoding)
  local tree = M.get_symbol_tree(bufnr, encoding)
  if not tree then return nil end
  local out = {}
  local function walk(symbols, depth)
    for _, s in ipairs(symbols or {}) do
      if s.name == name and graph_mod.is_function_kind(s.kind) then
        out[#out + 1] = { symbol = s, depth = depth }
      end
      walk(s.children, depth + 1)
    end
  end
  walk(tree, 0)
  if #out == 0 then return nil end
  table.sort(out, function(a, b) return a.depth < b.depth end)
  return out[1].symbol
end

--- Resolve the "current function" for `bufnr`. Returns root item, offset
--- encoding, and the client used. Must be called from a coroutine.
function M.resolve_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local client = find_client(bufnr, 'textDocument/prepareCallHierarchy')
  -- luacov: disable (defensive: no server attached)
  if not client then
    vim.notify('Callgraph: no language server with call hierarchy support for this file type — install/enable an LSP for it', vim.log.levels.WARN)
    return nil, nil, nil
  end
  -- luacov: enable
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
  local node = M.enclosing_function_at(bufnr, vim.api.nvim_win_get_cursor(win), encoding)
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
