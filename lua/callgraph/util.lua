--- Shared helpers: Deferred (thenable), coroutine-based async, and
--- LSP position <-> buffer byte conversions.

local M = {}

-- ---------------------------------------------------------------------------
-- Deferred: a minimal promise/thenable so LSP request chains read cleanly.
-- Resolving an already-resolved Deferred is a no-op; attaching :next() to a
-- resolved Deferred invokes the callback immediately (synchronous path), which
-- lets the headless smoke test run the whole graph build without an event loop.
-- ---------------------------------------------------------------------------

local Deferred = {}
Deferred.__index = Deferred

function Deferred.new()
  return setmetatable({ done = false, value = nil, error = nil, nexts = {} }, Deferred)
end

function Deferred:resolve(value)
  if self.done then return self end
  self.done = true
  self.value = value
  local nexts = self.nexts
  self.nexts = nil
  for _, fn in ipairs(nexts) do fn(value) end
  return self
end

function Deferred:reject(err)
  if self.done then return self end
  self.done = true
  self.error = err
  local nexts = self.nexts
  self.nexts = nil
  for _, fn in ipairs(nexts) do fn(nil, err) end
  return self
end

function Deferred:next(on_ok, on_err)
  if self.done then
    if self.error then
      if on_err then on_err(self.error) end
    elseif on_ok then
      on_ok(self.value)
    end
    return self
  end
  self.nexts[#self.nexts + 1] = function(value, err)
    if err ~= nil then
      if on_err then on_err(err) end
    elseif on_ok then
      on_ok(value)
    end
  end
  return self
end

M.Deferred = Deferred

-- ---------------------------------------------------------------------------
-- Coroutine async: run a body that may call M.await() on Deferreds.
-- ---------------------------------------------------------------------------

function M.async_start(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then error(err, 0) end
end

function M.await(deferred)
  assert(deferred and deferred.next, 'await expects a Deferred')
  if deferred.done then
    if deferred.error then error(deferred.error, 0) end
    return deferred.value
  end
  local co = coroutine.running()
  assert(co, 'await must be called from a coroutine')
  local result
  deferred:next(
    function(value)
      result = { true, value }
      local ok, err = coroutine.resume(co)
      if not ok and err then
        vim.notify('Callgraph: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end,
    function(err)
      result = { false, err }
      coroutine.resume(co)
    end
  )
  coroutine.yield()
  if not result[1] then error(result[2], 0) end
  return result[2]
end

-- ---------------------------------------------------------------------------
-- LSP position helpers. LSP positions are (line, character) where character is
-- in the negotiated offset encoding (clangd defaults to utf-16). Convert
-- between that and 0-based byte columns used by the Neovim buffer.
-- ---------------------------------------------------------------------------

--- 0-based byte column -> LSP character offset in the given encoding.
function M.byte_to_pos(line, byte_col, encoding)
  if encoding ~= 'utf-16' then return byte_col end
  local u, i = 0, 1
  local n = #line
  while i <= byte_col and i <= n do
    local b = string.byte(line, i)
    if b < 0x80 then
      u = u + 1; i = i + 1
    elseif b < 0xE0 then
      u = u + 1; i = i + 2
    elseif b < 0xF0 then
      u = u + 1; i = i + 3
    else
      u = u + 2; i = i + 4
    end
  end
  return u
end

--- LSP character offset (given encoding) -> 0-based byte column.
function M.pos_to_byte(line, pos_char, encoding)
  if encoding ~= 'utf-16' then return pos_char end
  local u, i = 0, 1
  local n = #line
  while u < pos_char and i <= n do
    local b = string.byte(line, i)
    if b < 0x80 then
      u = u + 1; i = i + 1
    elseif b < 0xE0 then
      u = u + 1; i = i + 2
    elseif b < 0xF0 then
      u = u + 1; i = i + 3
    else
      u = u + 2; i = i + 4
    end
  end
  return i - 1
end

--- Resolve when all Deferreds resolve. Results are collected positionally;
--- a rejected Deferred contributes `nil` (never rejects the aggregate).
function M.all(deferreds)
  local d = M.Deferred.new()
  local n = #deferreds
  if n == 0 then d:resolve({}); return d end
  local results = {}
  local pending = n
  for i, dd in ipairs(deferreds) do
    dd:next(
      function(value)
        results[i] = value
        pending = pending - 1
        if pending == 0 then d:resolve(results) end
      end,
      function()
        results[i] = nil
        pending = pending - 1
        if pending == 0 then d:resolve(results) end
      end
    )
  end
  return d
end

-- ---------------------------------------------------------------------------
-- Character-count helpers (box widths are character-based, not display-based).
-- ---------------------------------------------------------------------------

function M.char_count(s)
  return vim.fn.strchars(s or '')
end

--- Truncate a string to `maxchars` characters, appending an ellipsis.
function M.truncate(s, maxchars)
  if not s then return '' end
  if vim.fn.strchars(s) <= maxchars then return s end
  if maxchars <= 1 then return '…' end
  return vim.fn.strcharpart(s, 0, maxchars - 1) .. '…'
end

return M
