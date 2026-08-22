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

-- Definition cache: funcname -> { uri, line } or false (not found).
-- Populated lazily on jump (cscope -1), not during graph building, so the
-- graph appears immediately without waiting for definition lookups.
local def_cache = {}

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

--- Each line: `<file> <symbol> <line> <call text>`; line is 1-based.
--- `db_dir` is the directory containing cscope.out — relative file names in
--- the output are resolved against it so uris are absolute and jumpable.
function M.parse_output(stdout, db_dir)
  local calls = {}
  for line in (stdout or ''):gmatch('[^\r\n]+') do
    local file, sym, ln = line:match('^(%S+)%s+(%S+)%s+(%d+)')
    if file and sym and ln then
      local line_no = tonumber(ln)
      -- Resolve relative paths against the cscope.out directory.
      if db_dir and not file:match('^/') then
        file = db_dir .. '/' .. file
      end
      local uri = vim.uri_from_fname(file)
      calls[#calls + 1] = {
        item = {
          name = sym,
          kind = 12, -- function
          uri = uri,
          range = { start = { line = line_no - 1, character = 0 }, ['end'] = { line = line_no - 1, character = 0 } },
          selectionRange = { start = { line = line_no - 1, character = 0 }, ['end'] = { line = line_no - 1, character = #sym } },
        },
        call_site = { uri = uri, line = line_no - 1 },
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

--- Look up a function's definition location via `cscope -1`.
--- Returns a Deferred resolving to { uri, line } (0-based line) or nil.
--- Cached by funcname so each function is queried at most once per session.
--- This is called lazily on jump, not during graph building, so the graph
--- appears immediately — definition lookup only happens when the user
--- actually presses Enter on a cscope node.
function M.find_definition(funcname)
  local d = util.Deferred.new()
  if not funcname then d:resolve(nil); return d end
  if def_cache[funcname] ~= nil then
    d:resolve(def_cache[funcname] or nil)
    return d
  end
  local db = M.find_db()
  if not db then
    def_cache[funcname] = false
    d:resolve(nil)
    return d
  end
  local db_dir = vim.fn.fnamemodify(db, ':h')
  local cmd = { 'cscope', '-dL', '-1', funcname, '-f', db, '-P', db_dir }
  vim.system(cmd, { text = true }, function(proc)
    vim.schedule(function()
      if proc.code ~= 0 or not proc.stdout then
        def_cache[funcname] = false
        d:resolve(nil)
        return
      end
      local first = proc.stdout:match('^[^\r\n]+')
      if first then
        local file, _, ln = first:match('^(%S+)%s+(%S+)%s+(%d+)')
        if file and ln then
          if not file:match('^/') then
            file = db_dir .. '/' .. file
          end
          local result = { uri = vim.uri_from_fname(file), line = tonumber(ln) - 1 }
          def_cache[funcname] = result
          d:resolve(result)
          return
        end
      end
      def_cache[funcname] = false
      d:resolve(nil)
    end)
  end)
  return d
end

--- Clear the module-level query cache (e.g. after external index changes).
function M.clear_cache()
  query_cache = {}
  def_cache = {}
end

--- Fetch function for graph building: node, direction -> Deferred(calls).
function M.make_fetch(encoding, client, opts)
  return function(node, direction)
    return M.query(node.name, direction, opts)
  end
end

return M
