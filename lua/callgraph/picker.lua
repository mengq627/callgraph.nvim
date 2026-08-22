--- Definition picker: a small floating window listing candidate definitions
--- (used when a cscope name resolves to several definitions). j/k move, <CR>
--- picks, q/<Esc> cancels. Selection is delivered via a callback — the caller
--- keeps control of what happens after the choice.

local M = {}

local ns = vim.api.nvim_create_namespace('callgraph_picker')
local picker = nil -- { win, buf, idx, defs, cb }

local function render()
  if not picker then return end
  local lines = {}
  for i, d in ipairs(picker.defs) do
    local rel = vim.fn.fnamemodify(vim.uri_to_fname(d.uri), ':~:.')
    lines[i] = string.format('%s:%d', rel, d.line + 1)
  end
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(picker.buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(picker.buf, ns, 'CursorLine', picker.idx - 1, 0, -1)
  vim.api.nvim_win_set_cursor(picker.win, { picker.idx, 0 })
end

local function close(result)
  if not picker then return end
  local cb = picker.cb
  local win = picker.win
  picker = nil
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if cb then cb(result) end
end

local function move(delta)
  if not picker or #picker.defs == 0 then return end
  local n = #picker.defs
  picker.idx = ((picker.idx - 1 + delta) % n) + 1
  render()
end

local function setup_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'j', function() move(1) end, opts)
  vim.keymap.set('n', 'k', function() move(-1) end, opts)
  vim.keymap.set('n', '<Down>', function() move(1) end, opts)
  vim.keymap.set('n', '<Up>', function() move(-1) end, opts)
  vim.keymap.set('n', '<CR>', function()
    local cur = picker and picker.defs[picker.idx]
    close(cur)
  end, opts)
  vim.keymap.set('n', 'q', function() close(nil) end, opts)
  vim.keymap.set('n', '<Esc>', function() close(nil) end, opts)
end

--- Show a definition picker. `defs` is a list of `{ uri, line }`; on pick the
--- callback receives the chosen definition, on cancel it receives nil.
function M.pick(defs, on_pick)
  if not defs or #defs == 0 then on_pick(nil); return end
  if picker then close(nil) end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    row = 1,
    col = 1,
    width = 60,
    height = math.min(#defs, 10),
    style = 'minimal',
    border = 'rounded',
    title = 'Select definition',
    title_pos = 'center',
  })
  picker = { win = win, buf = buf, idx = 1, defs = defs, cb = on_pick }
  setup_keymaps(buf)
  render()
end

return M
