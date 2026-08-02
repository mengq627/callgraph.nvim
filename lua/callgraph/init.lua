--- Public API and plugin entry point.

local M = {}
local config = require('callgraph.config')
local view = require('callgraph.view')
local lsp = require('callgraph.lsp')

local function ensure_highlights()
  config.define_highlights()
  if not vim.g.callgraph_highlights_ready then
    vim.g.callgraph_highlights_ready = true
    vim.api.nvim_create_autocmd('ColorScheme', {
      callback = function() config.define_highlights() end,
    })
  end
end

--- `require('callgraph').setup({ ... })`
function M.setup(opts)
  config.set(opts or {})
  ensure_highlights()
end

--- Open the callgraph view. `direction` is 'callout' (default) or 'callin'.
function M.open(direction)
  ensure_highlights()
  view.open(direction == 'callin' and 'callin' or 'callout')
end

-- Background documentSymbol cache so opening the view stays fast. Registered
-- at require time (lazy: happens on first command) and costs nothing per file.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    if args and args.buf then lsp.ensure_document_symbol(args.buf) end
  end,
})

return M
