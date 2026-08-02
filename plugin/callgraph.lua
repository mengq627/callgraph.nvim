-- Lazy-loading entry point: only registers the user commands. The module is
-- required on first invocation, so `{ "path", cmd = { "Callout", "Callin" } }`
-- keeps file-open cost at zero.

if vim.g.loaded_callgraph then return end
vim.g.loaded_callgraph = true

vim.api.nvim_create_user_command('Callout', function()
  require('callgraph').open('callout')
end, {})

vim.api.nvim_create_user_command('Callin', function()
  require('callgraph').open('callin')
end, {})
