--- Heuristic call-graph fetcher for servers without call hierarchy support.
---
--- callout (callees): scan the function body for `identifier(` tokens, then
--- resolve each one to the callee via `prepareCallHierarchy` at that token
--- (clangd returns the called function there). This is the poor-man's
--- `outgoingCalls`, needed because LSP has no standard "callees" request and
--- clangd < 20 implements no outgoingCalls at all.
---
--- callin (callers): resolve `references` on the function name, then find the
--- enclosing function of each reference via the documentSymbol tree.
---
--- Both fetch functions return a Deferred resolving to
--- `{ { item, call_site }, ... }` — the same shape as the standard fetcher,
--- so the graph builder is server-agnostic.

local util = require('callgraph.util')
local scanner = require('callgraph.scanner')
local graph_mod = require('callgraph.graph')

local M = {}

local function prepare_at(client, encoding, uri, pos, bufnr)
  local d = util.Deferred.new()
  client.request(
    'textDocument/prepareCallHierarchy',
    { textDocument = { uri = uri }, position = pos },
    function(err, result)
      if err then
        d:resolve(nil)
        return
      end
      local item = (type(result) == 'table' and result[1]) or result
      if not item or not graph_mod.is_function_kind(item.kind) then
        d:resolve(nil)
      else
        d:resolve(item)
      end
    end,
    bufnr
  )
  return d
end

local function callout_fetch(node, client, encoding, find_by_name)
  local uri = node.uri
  local range = node.range
  if not uri or not range then return {} end
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range['end'].line + 1, false)
  if #lines == 0 then return {} end
  local positions = scanner.scan_calls(table.concat(lines, '\n'))
  if #positions == 0 then return {} end

  -- Resolve each call token in parallel via prepareCallHierarchy at the token.
  local deferreds = {}
  local metas = {}
  for _, p in ipairs(positions) do
    local bline = range.start.line + p[1]
    local line_text = lines[p[1] + 1] or ''
    local character = util.byte_to_pos(line_text, p[2], encoding)
    deferreds[#deferreds + 1] = prepare_at(client, encoding, uri, { line = bline, character = character }, bufnr)
    metas[#metas + 1] = { uri = uri, line = bline, name = p[3] }
  end
  local results = util.await(util.all(deferreds))

  -- When the server can't resolve a token (e.g. implicit declaration in
  -- poorly-ordered source), match the identifier name against the file's
  -- functions so the graph still builds. Iterate `positions` (dense) rather
  -- than `results` (which has nil holes that would stop ipairs early).
  for i = 1, #positions do
    if not results[i] and metas[i].name and find_by_name then
      local sym = find_by_name(bufnr, metas[i].name, encoding)
      if sym then
        results[i] = { name = sym.name, kind = sym.kind, uri = uri, range = sym.range, selectionRange = sym.selectionRange }
      end
    end
  end

  local calls = {}
  for i = 1, #positions do
    if results[i] then
      calls[#calls + 1] = { item = results[i], call_site = { uri = metas[i].uri, line = metas[i].line } }
    end
  end
  return calls
end

local function callin_fetch(node, client, encoding, enclosing_fn)
  local uri = node.uri
  local sel = node.selectionRange
  if not uri or not sel then return {} end
  local d = util.Deferred.new()
  client.request(
    'textDocument/references',
    { textDocument = { uri = uri }, position = sel.start, context = { includeDeclaration = false } },
    function(err, result)
      if err then d:resolve(nil) else d:resolve(result) end
    end,
    vim.uri_to_bufnr(uri)
  )
  local refs = util.await(d) or {}

  local calls = {}
  for _, r in ipairs(refs) do
    local rbufnr = vim.uri_to_bufnr(r.uri)
    vim.fn.bufload(rbufnr)
    local line_text = vim.api.nvim_buf_get_lines(rbufnr, r.range.start.line, r.range.start.line + 1, false)[1] or ''
    local byte_col = util.pos_to_byte(line_text, r.range.start.character, encoding)
    local sym = enclosing_fn(rbufnr, { r.range.start.line + 1, byte_col }, encoding)
    if sym then
      calls[#calls + 1] = {
        item = {
          name = sym.name,
          kind = sym.kind,
          uri = r.uri,
          range = sym.range,
          selectionRange = sym.selectionRange,
        },
        call_site = { uri = r.uri, line = r.range.start.line },
      }
    end
  end
  return calls
end

--- Create the heuristic fetch. `enclosing_fn` and `find_by_name` are the
--- documentSymbol-based resolvers (injected to avoid a circular require with
--- the LSP adapter).
function M.make_fetch(client, encoding, enclosing_fn, find_by_name)
  return function(node, direction)
    local d = util.Deferred.new()
    util.async_start(function()
      local ok, calls = pcall(function()
        if direction == 'callout' then
          return callout_fetch(node, client, encoding, find_by_name)
        end
        return callin_fetch(node, client, encoding, enclosing_fn)
      end)
      if ok then d:resolve(calls) else d:reject(calls) end
    end)
    return d
  end
end

return M
