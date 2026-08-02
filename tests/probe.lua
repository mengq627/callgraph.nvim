-- Probe what a real LSP server actually provides for call-graph data.
-- Run: nvim --headless -u NONE -l tests/probe.lua
-- Opens tests/clean.c, starts clangd, then reports:
--   definition / prepareCallHierarchy-at-token / references / incomingCalls / outgoingCalls

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')

vim.cmd('edit ' .. root .. '/tests/clean.c')
vim.lsp.start({
  name = 'clangd',
  cmd = { 'clangd' },
  root_dir = root,
  capabilities = vim.lsp.protocol.make_client_capabilities(),
})
local attached = vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
if not attached then
  print('clangd did not attach')
  os.exit(1)
end
vim.wait(3000, function() return false end) -- let clangd parse

local c = vim.lsp.get_clients({ bufnr = 0 })[1]
local enc = c.offset_encoding or 'utf-16'
local U = vim.uri_from_bufnr(0)

-- clean.c layout (0-based): line 2 'add' def name; line 7 'return add(x, x);' call
local ADD_DEF = { line = 2, character = 12 }
local ADD_CALL = { line = 7, character = 11 }

local function pos(line, char)
  return { line = line, character = char }
end

-- 1) definition at the call token
c.request('textDocument/definition', { textDocument = { uri = U }, position = pos(7, 11) }, function(err, res)
  print('definition@call-token  ->', err and tostring(err.message) or (res and #res > 0 and ('line ' .. (res[1].range.start.line + 1)) or 'EMPTY'))

  -- 2) prepareCallHierarchy at the call token
  c.request('textDocument/prepareCallHierarchy', { textDocument = { uri = U }, position = pos(7, 11) }, function(err2, res2)
    local it = (type(res2) == 'table' and res2[1]) or res2
    print('prepareCH@call-token   ->', err2 and tostring(err2.message) or (it and it.name or 'nil'))

    -- 3) references on 'add' definition name (exclude declaration)
    c.request('textDocument/references', { textDocument = { uri = U }, position = pos(2, 12), context = { includeDeclaration = false } }, function(err3, res3)
      print('references             ->', err3 and ('ERR ' .. tostring(err3.message)) or ('OK ' .. #(res3 or {})))

      -- 4) standard incomingCalls on 'add'
      c.request('textDocument/prepareCallHierarchy', { textDocument = { uri = U }, position = pos(2, 12) }, function(err4, res4)
        local item = (type(res4) == 'table' and res4[1]) or res4
        c.request('callHierarchy/incomingCalls', { item = item }, function(err5, res5)
          print('incomingCalls (std)    ->', err5 and ('ERR ' .. tostring(err5.message)) or ('OK ' .. #(res5 or {})))
          if res5 then
            for _, r in ipairs(res5) do print('   caller:', r.from.name) end
          end
          os.exit(0)
        end, 0)
      end, 0)
    end, 0)
  end, 0)
end, 0)

vim.wait(25000, function() return false end)
print('TIMEOUT')
os.exit(1)
