-- Coverage runner: runs every test in tests/ under vendored luacov, merges
-- the per-process stats, generates a report, prints a coverage summary, and —
-- when given `--diff <base>` — fails if any line newly added by the diff is
-- not covered (new code must be 100% covered).
--
-- Run from the repo root:
--   nvim --headless -u NONE -l tests/run_coverage.lua              # coverage summary
--   nvim --headless -u NONE -l tests/run_coverage.lua --diff origin/main
--
-- Lines between `-- luacov: disable` / `-- luacov: enable` comments are
-- excluded from coverage (deliberately untested branches), so they are not
-- counted as misses and are skipped by the new-code check.

local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':h:h')
package.path = root .. '/tests/vendor/luacov/?.lua;' .. root .. '/tests/vendor/luacov/?/init.lua;' .. package.path

local vendor_inj = ("lua package.path='%s/tests/vendor/luacov/?.lua;%s/tests/vendor/luacov/?/init.lua;'..package.path; require('luacov').init()")
  :format(root, root)

-- nvim `-l script.lua --diff <base>` passes trailing args in the global `arg`.
-- `--no-run` skips running the tests / generating the report and only re-parses
-- an existing luacov.report.out (used by CI to reuse the hard-gate run's report
-- for the non-blocking new-code check, avoiding a duplicated test run).
local diff_base = nil
local no_run = false
for i, a in ipairs(arg or {}) do
  if a == '--diff' and arg[i + 1] then
    diff_base = arg[i + 1]
  elseif a == '--no-run' then
    no_run = true
  end
end

local failed = 0
local function fail(msg)
  failed = failed + 1
  print('FAIL ' .. msg)
end

-- ---------------------------------------------------------------------------
-- 1. Collect the test scripts (top-level tests/*.lua, skip scratch/vendor).
-- ---------------------------------------------------------------------------
local tests = {}
for _, f in ipairs(vim.fn.glob(root .. '/tests/*.lua', false, true)) do
  local name = vim.fn.fnamemodify(f, ':t')
  if name:sub(1, 1) ~= '_' and name ~= 'run_coverage.lua' then
    tests[#tests + 1] = f
  end
end
table.sort(tests)

-- ---------------------------------------------------------------------------
-- 2. Fresh stats, then run each test in its own nvim process (luacov aggregates
--    hit counts across processes by appending to luacov.stats.out).
-- ---------------------------------------------------------------------------
local run_failures = 0
if not no_run then
  os.remove(root .. '/luacov.stats.out')
  for _, t in ipairs(tests) do
    local cmd = { 'nvim', '--headless', '-u', 'NONE', '-c', vendor_inj, '-l', t }
    local res = vim.system(cmd, { cwd = root, text = true }):wait()
    if res.code ~= 0 then
      run_failures = run_failures + 1
      print('FAIL test ' .. vim.fn.fnamemodify(t, ':t'))
      local out = (res.stdout or '') .. (res.stderr or '')
      for line in (out):gmatch('[^\r\n]+') do
        if line:find('FAIL') or line:find('Error') or line:find('ERR') then print('   ' .. line) end
      end
    else
      print('PASS test ' .. vim.fn.fnamemodify(t, ':t'))
    end
  end
  print('---')
  print(('tests: %d passed, %d failed'):format(#tests - run_failures, run_failures))

  -- -----------------------------------------------------------------------
  -- 3. Generate the report from the merged stats.
  -- -----------------------------------------------------------------------
  local luacov = require('luacov') -- vendored; returns the runner module
  luacov.configuration = luacov.load_config(root .. '/.luacov')
  luacov.run_report(luacov.configuration)
end

-- ---------------------------------------------------------------------------
-- 4. Parse the report into per-file line coverage.
--    Report structure: `====` / <filename> / `====` / source lines. Hit lines
--    are prefixed with the execution count (` 3 code`), misses with `*0 code`,
--    comments/blank/`-- luacov: disable` blocks have no numeric prefix. The
--    report lists every source line in order, so the per-file line counter
--    equals the source line number. A filename line is the one whose NEXT line
--    is the `====` separator.
-- ---------------------------------------------------------------------------
local lines = {}
for line in io.lines(root .. '/luacov.report.out') do
  lines[#lines + 1] = line:gsub('\r$', '') -- luacov writes CRLF on Windows
end
local files = {} -- normalized path ('/') -> { total, missed = {line,...} }
local cur_path, lineno
for i, line in ipairs(lines) do
  local nextline = lines[i + 1] or ''
  if line:find('^Summary') then
    cur_path = nil
  elseif nextline:find('^====') and not line:find('^====') and line ~= '' then
    cur_path = line:gsub('\\', '/')
    lineno = 0
    files[cur_path] = { total = 0, missed = {}, exec = {} }
  elseif line:find('^====') then
    -- separator; ignored
  elseif cur_path then
    lineno = lineno + 1
    local miss = line:match('^%s*%*0%s')
    local hit = line:match('^%s*%d+%s')
    if hit or miss then
      local rec = files[cur_path]
      rec.total = rec.total + 1
      rec.exec[lineno] = true
      if miss then rec.missed[#rec.missed + 1] = lineno end
    end
  end
end

-- ---------------------------------------------------------------------------
-- 5. Coverage summary.
-- ---------------------------------------------------------------------------
local names = {}
for k in pairs(files) do names[#names + 1] = k end
table.sort(names)
local hits_all, total_all = 0, 0
print('---')
print(('%-28s %6s %6s %8s'):format('file', 'hit', 'total', 'cover%'))
for _, n in ipairs(names) do
  local rec = files[n]
  local hits = rec.total - #rec.missed
  hits_all, total_all = hits_all + hits, total_all + rec.total
  print(('%-28s %6d %6d %7.1f%%'):format(n, hits, rec.total, total_all > 0 and (hits * 100 / rec.total) or 0))
end
print(('%-28s %6d %6d %7.1f%%'):format('TOTAL', hits_all, total_all, total_all > 0 and (hits_all * 100 / total_all) or 0))

-- ---------------------------------------------------------------------------
-- 6. New-code coverage check (--diff <base>): every line added by the diff
--    must be covered, unless it sits in a `-- luacov: disable` block (which is
--    reported without a hit/miss marker and therefore not in `missed`).
-- ---------------------------------------------------------------------------
if diff_base then
  print('---')
  print('new-code coverage vs ' .. diff_base)
  local res = vim.system({ 'git', 'diff', '-U0', diff_base, '--', 'lua/callgraph' }, { cwd = root, text = true }):wait()
  local cur_file, new_line, uncovered = nil, nil, 0
  for line in (res.stdout or ''):gmatch('[^\r\n]+') do
    if line:find('^diff %-%-git') then
      cur_file = line:match('b/(.+)$')
      if cur_file then cur_file = cur_file:gsub('\\', '/') end
    elseif line:find('^@@') then
      local c = line:match('^@@ %-?%d+.* %+(%d+)')
      new_line = tonumber(c)
    elseif cur_file and line:sub(1, 1) == '+' and line:sub(1, 2) ~= '++' then
      local rec = files[cur_file]
      local bad = false
      if rec and rec.exec[new_line] then
        -- executable line added by the diff: it must be covered
        bad = vim.tbl_contains(rec.missed, new_line)
      elseif not rec then
        -- file not loaded by any test at all: newly added code is uncovered
        bad = cur_file:find('^lua/callgraph', 1, true) ~= nil
      end
      -- else: comment / blank / `-- luacov: disable` block -> no requirement
      if bad then
        uncovered = uncovered + 1
        print('UNCOVERED NEW LINE ' .. cur_file .. ':' .. new_line)
      end
      new_line = (new_line or 0) + 1
    elseif cur_file and line:sub(1, 1) == '-' then
      -- deletion; no effect on new-file line numbers
    end
  end
  if uncovered > 0 then
    fail(('diff coverage: %d newly added line(s) not covered'):format(uncovered))
  else
    print('all newly added lines are covered')
  end
end

print('---')
if failed == 0 and run_failures == 0 then
  print('COVERAGE OK')
  os.exit(0)
else
  print(('COVERAGE FAILED (test fails=%d, checks=%d)'):format(run_failures, failed))
  os.exit(1)
end
