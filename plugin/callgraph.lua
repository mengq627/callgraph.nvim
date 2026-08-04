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

-- Debug tooling: `:CallgraphLog` opens the log file; `:CallgraphDebug on|off`
-- toggles the location/move debug logging at runtime (see config `debug`).
vim.api.nvim_create_user_command('CallgraphLog', function()
  require('callgraph.debug').open_log()
end, {})

vim.api.nvim_create_user_command('CallgraphDebug', function(args)
  local config = require('callgraph.config')
  local arg = (args.args or ''):lower()
  if arg == 'on' then
    config.update({ debug = true, debug_location = true, debug_move = true })
    vim.notify('Callgraph debug on (location + move)', vim.log.levels.INFO, { title = 'Callgraph' })
  elseif arg == 'off' then
    config.update({ debug = false })
    vim.notify('Callgraph debug off', vim.log.levels.INFO, { title = 'Callgraph' })
  else
    vim.notify('用法: :CallgraphDebug on | off', vim.log.levels.WARN, { title = 'Callgraph' })
  end
end, { nargs = '?' })
