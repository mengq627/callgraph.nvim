-- cscope source provider: output parsing, db discovery and availability probe.
-- The actual `cscope` binary is NOT required (this machine may not have it);
-- parsing and discovery are environment-independent.
-- Run: nvim --headless -u NONE -l tests/cscope.lua

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
vim.opt.runtimepath:append(root)
vim.cmd('runtime! plugin/callgraph.lua')

local cscope = require('callgraph.source.cscope')

local failed = 0
local function check(name, cond, detail)
  if cond then print('PASS ' .. name) else failed = failed + 1; print('FAIL ' .. name .. (detail and (' :: ' .. tostring(detail)) or '')) end
end

-- ---- find_db: walks up from a directory looking for cscope.out ----
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local db = tmp .. '/cscope.out'
vim.fn.writefile({ '' }, db)
check('find_db finds cscope.out in dir', cscope.find_db(tmp) ~= nil and vim.fn.filereadable(cscope.find_db(tmp)) == 1)
check('find_db finds cscope.out from subdir', cscope.find_db(tmp .. '/a/b') ~= nil)
vim.fn.delete(db)
check('find_db returns nil when missing', cscope.find_db(tmp) == nil)
vim.fn.delete(tmp, 'rf')

-- ---- parse_output: cscope -L line format `file symbol line text` ----
local calls = cscope.parse_output([[
D:/code/proj/src/main.c main 5 printf("hello");
D:/code/proj/src/util.c helper 12 do_thing();
]])
check('parse_output returns 2 calls', #calls == 2, 'got ' .. #calls)
check('callout name parsed', calls[1].item.name == 'main')
check('uri parsed', calls[1].item.uri == 'file:///D:/code/proj/src/main.c', tostring(calls[1].item.uri))
check('line is 0-based', calls[1].item.range.start.line == 4, tostring(calls[1].item.range.start.line))
check('call_site recorded', calls[1].call_site ~= nil and calls[1].call_site.line == 4)
check('second call parsed', calls[2].item.name == 'helper' and calls[2].item.range.start.line == 11)

check('parse_output handles empty', #cscope.parse_output('') == 0)
check('parse_output ignores malformed lines', #cscope.parse_output('no-tabs-here\n') == 0)

-- ---- available: returns a boolean (binary + db probe) ----
check('available returns a bool', type(cscope.available({})) == 'boolean')

print('---')
if failed == 0 then print('CSCOPE OK') else print('CSCOPE FAILED: ' .. failed) end
os.exit(failed == 0 and 0 or 1)
