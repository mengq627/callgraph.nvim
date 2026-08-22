--- cscope source: query a cscope database for callers / callees.
---
--- Query (line mode, no interactive UI):
---   cscope -dL -2 <func>   # functions called by <func>  (callout)
---   cscope -dL -3 <func>   # functions calling <func>    (callin)
--- Output per line: `file symbol line <call text>`.
---
--- Needs the `cscope` binary and a cscope.out database in the project.

local util = require('callgraph.util')

local M = {}

-- Module-level query cache: funcname\0direction -> { done, calls } or
-- { done = false, deferred = d } when a query is in flight.
-- This is needed because source.lua's session cache keys on symbol_id
-- (uri + name + selectionRange line/char), and cscope puts the *call-site*
-- line into selectionRange — so the same function called from different
-- lines gets different symbol_ids and source.lua's cache never hits.
-- Keying by funcname+direction here ensures each function is queried at
-- most once per session, regardless of how many call paths reach it.
local query_cache = {}

--- Walk up from `dir` looking for `cscope.out`; returns the db path or nil.
function M.find_db(dir)
  dir = dir or vim.fn.getcwd()
  while true do
    local f = vim.fn.fnamemodify(dir .. '/cscope.out', ':p')
    if vim.fn.filereadable(f) == 1 then return f end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == dir then return nil end
    dir = parent
  end
end

--- Is cscope usable right now (binary present + a database exists)?
function M.available(opts)
  if vim.fn.executable('cscope') ~= 1 then return false end
  return M.find_db() ~= nil
end

--- Parse cscope -L output into call records.
--- Each line: `<file> <symbol> <line> <call text>`; with `-P <dir>` the file
--- is absolute. line is 1-based.
function M.parse_output(stdout)
  local calls = {}
  for line in (stdout or ''):gmatch('[^\r\n]+') do
    local file, sym, ln = line:match('^(%S+)%s+(%S+)%s+(%d+)')
    if file and sym and ln then
      local line_no = tonumber(ln)
      calls[#calls + 1] = {
        item = {
          name = sym,
          kind = 12, -- function
          uri = vim.uri_from_fname(file),
          range = { start = { line = line_no - 1, character = 0 }, ['end'] = { line = line_no - 1, character = 0 } },
          selectionRange = { start = { line = line_no - 1, character = 0 }, ['end'] = { line = line_no - 1, character = #sym } },
        },
        call_site = { uri = vim.uri_from_fname(file), line = line_no - 1 },
      }
    end
  end
  return calls
end

--- Run one cscope query. Returns Deferred resolving to parsed calls.
--- direction: 'callout' -> -2 (callees), 'callin' -> -3 (callers).
--- Results are cached by funcname+direction at module level so the same
--- function is never queried twice per session.
function M.query(funcname, direction, opts)
  local key = (funcname or '?') .. '\0' .. (direction or '?')

  -- Cache hit (done): return a fresh Deferred resolved immediately.
  local cached = query_cache[key]
  if cached then
    if cached.done then
      local d = util.Deferred.new()
      d:resolve(cached.calls)
      return d
    end
    -- Pending: share the same Deferred so all waiters get one query's result.
    return cached.deferred
  end

  local d = util.Deferred.new()
  query_cache[key] = { done = false, deferred = d }
  local db = M.find_db()
  if not db or not funcname then
    query_cache[key] = { done = true, calls = {} }
    d:resolve({})
    return d
  end
  local op = direction == 'callin' and '-3' or '-2'
  local db_dir = vim.fn.fnamemodify(db, ':h')
  -- -P <dir> makes cscope emit absolute filenames (relative paths get the dir
  -- prepended), so parsing yields jumpable uris.
  local cmd = { 'cscope', '-dL', op, funcname, '-f', db, '-P', db_dir }
  vim.system(cmd, { text = true }, function(proc)
    -- vim.system's on_exit runs in a fast-event context where UI calls (e.g.
    -- vim.notify via the resolved Deferred chain) are forbidden — defer to the
    -- main loop so the await/notify path is safe.
    vim.schedule(function()
      if proc.code ~= 0 then
        query_cache[key] = { done = true, calls = {} }
        d:resolve({})
        return
      end
      local calls = M.parse_output(proc.stdout, db_dir)
      query_cache[key] = { done = true, calls = calls }
      d:resolve(calls)
    end)
  end)
  return d
end

--- Clear the module-level query cache (e.g. after external index changes).
function M.clear_cache()
  query_cache = {}
end

--- Fetch function for graph building: node, direction -> Deferred(calls).
function M.make_fetch(encoding, client, opts)
  return function(node, direction)
    return M.query(node.name, direction, opts)
  end
end

return M
