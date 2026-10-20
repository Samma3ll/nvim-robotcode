-- Real CLI discovery and terminal runs through the explorer; no LSP required.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/robotcode.lua')
local python = vim.fs.joinpath(root, '.venv', vim.fn.has('win32') == 1 and 'Scripts/python.exe' or 'bin/python')
local fixture = vim.fs.joinpath(root, 'tests', 'fixtures', 'project')
local output = vim.fs.joinpath(root, 'tests', '.output', 'explorer')
vim.env.XDG_STATE_HOME = vim.fn.tempname() .. '-robotcode-state'
local explorer = require('robotcode.explorer')
local results = require('robotcode.results')
local state = require('robotcode.state')
local messages, finished, started_text = {}, nil, nil
vim.notify = function(message) messages[#messages + 1] = message end
local panel, panel_win

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(panel, 0, -1, false), '\n')
end

local function wait_for(description, predicate)
  assert(vim.wait(30000, predicate, 20), description .. '\n' .. vim.inspect(messages))
end

local function select_line(needle)
  vim.api.nvim_set_current_win(panel_win)
  for line, value in ipairs(vim.api.nvim_buf_get_lines(panel, 0, -1, false)) do
    if value:find(needle, 1, true) then vim.api.nvim_win_set_cursor(panel_win, { line, 0 }); return end
  end
  error('Missing explorer row: ' .. needle .. '\n' .. text())
end

local function key(mapping)
  vim.api.nvim_set_current_win(panel_win)
  local action = vim.fn.maparg(mapping, 'n', false, true)
  assert(type(action.callback) == 'function', 'Missing mapping: ' .. mapping)
  action.callback()
end

local function main()
  vim.fn.mkdir(output, 'p')
  require('robotcode').setup({
    cmd = { python, '-m', 'robotcode.cli' }, root_dir = fixture,
    profiles = { 'example' }, args = { '--outputdir', output }, result_popup = false,
  })
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(fixture, 'suites', 'cursor.robot')))
  vim.bo.filetype = 'robot'
  vim.cmd('RobotCodeExplorer')
  panel, panel_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  assert(vim.bo[panel].filetype == 'robotcode_explorer')
  wait_for('Initial test discovery', function() return text():find('Passing body with failing teardown', 1, true) end)
  assert(text():find('Literal [x] * ? test', 1, true))
  select_line('Cursor')
  key('<CR>')
  assert(not text():find('First test', 1, true), 'Suite did not collapse')
  key('<CR>')
  assert(text():find('First test', 1, true), 'Suite did not expand')
  select_line('First test')
  key('o')
  assert(vim.api.nvim_buf_get_name(0):find('cursor.robot', 1, true))
  assert(vim.api.nvim_win_get_cursor(0)[1] == 8, 'Source jump missed test title')

  vim.api.nvim_create_autocmd('User', {
    pattern = 'RobotCodeTestStarted', callback = function() started_text = text() end,
  })
  vim.api.nvim_create_autocmd('User', {
    pattern = 'RobotCodeTestFinished', callback = function(event) finished = event.data end,
  })
  -- Includes a passing test and a failing test: a nonzero suite exit must not
  -- incorrectly change the individual passing test into an ERROR.
  select_line('Cursor')
  key('r')
  wait_for('Suite terminal run', function() return finished ~= nil end)
  assert(started_text:find('[RUN ]', 1, true), 'Running status was not shown')
  assert(finished.result.status == 'FAIL' and #finished.result.tests == 3, vim.inspect(finished))
  assert(finished.result.tests[1].status == 'PASS' and finished.result.tests[3].status == 'FAIL')
  assert(text():find('2 passed · 1 failed · 0 skipped', 1, true), text())
  local xml = table.concat(vim.fn.readfile(vim.fs.joinpath(output, 'output.xml')), '\n')
  assert(xml:find('inherited', 1, true) and xml:find('from profile', 1, true))
  assert(not xml:find('name="Other"', 1, true), 'Suite selection ran another suite')
  select_line('Last test')
  key('p')
  assert(vim.bo.filetype == 'robotcode_result')
  local popup = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(popup:find('This test must never run', 1, true), popup)
  results.close()

  -- Run all seven discovered tests, including SKIP and suite teardown failure.
  finished = nil
  key('R')
  wait_for('Run all terminal run', function() return finished ~= nil end)
  assert(#finished.result.tests == 7 and finished.result.status == 'FAIL', vim.inspect(finished))
  assert(text():find('2 passed · 4 failed · 1 skipped', 1, true), text())
  assert(text():find('[SKIP] Skipped result', 1, true), text())
  assert(text():find('[FAIL] Passing body with failing teardown', 1, true), text())

  package.loaded['robotcode.state'] = nil
  local restored = require('robotcode.state').get(fixture)
  assert(restored.last.name == 'All tests' and #restored.last.tests == 7, vim.inspect(restored))
  local count = 0
  for _ in pairs(restored.tests) do count = count + 1 end
  assert(count == 7, 'Results did not survive module reload')

  if vim.env.ROBOTCODE_TEST_DAP == '1' then
    vim.opt.runtimepath:prepend(vim.fs.joinpath(root, '.deps', 'nvim-dap'))
    local dap = require('dap')
    dap.defaults.nvim_robotcode.exception_breakpoints = {}
    finished = nil
    select_line('Results')
    key('d')
    wait_for('Explorer suite debug run', function() return finished ~= nil end)
    assert(finished.mode == 'debug' and #finished.result.tests == 2, vim.inspect(finished))
    assert(finished.result.tests[1].status == 'FAIL' and finished.result.tests[2].status == 'SKIP')
    assert(text():find('0 passed · 1 failed · 1 skipped', 1, true), text())
    wait_for('Debugger closes', function() return dap.session() == nil end)
  end

  -- Refuse execution when another Robot buffer has unsaved edits.
  local other = vim.fn.bufadd(vim.fs.joinpath(fixture, 'suites', 'other.robot'))
  vim.fn.bufload(other)
  vim.bo[other].filetype, vim.bo[other].modified = 'robot', true
  finished = nil
  key('R')
  assert(messages[#messages]:find('Save modified Robot Framework buffers', 1, true))
  assert(not finished)
  vim.bo[other].modified = false
  key('q')
  assert(not explorer.is_open() and not vim.api.nvim_buf_is_valid(panel))

  -- Ambiguous names must be rejected even for a suite/all selection.
  local duplicate_root = vim.fs.joinpath(output, 'duplicate')
  vim.fn.mkdir(duplicate_root, 'p')
  vim.fn.writefile({ 'paths = ["duplicate.robot"]' }, vim.fs.joinpath(duplicate_root, 'robot.toml'))
  vim.fn.writefile({ '*** Test Cases ***', 'Same name', '    No Operation', 'Same name', '    No Operation' },
    vim.fs.joinpath(duplicate_root, 'duplicate.robot'))
  require('robotcode').setup({
    cmd = { python, '-m', 'robotcode.cli' }, root_dir = duplicate_root, result_popup = false,
  })
  vim.cmd('RobotCodeExplorer')
  panel, panel_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  wait_for('Duplicate fixture discovery', function() return text():find('Same name', 1, true) end)
  finished = nil
  key('R')
  wait_for('Duplicate name guard', function() return messages[#messages]:find('duplicate full names', 1, true) end)
  assert(not finished)
  key('q')

  -- Invalid CLI commands should leave a usable, closable sidebar with an error.
  require('robotcode').setup({ cmd = { 'robotcode-nonexistent-test-command' }, root_dir = fixture })
  vim.cmd('RobotCodeExplorer')
  panel, panel_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  wait_for('Discovery launch error', function() return text():find('Discovery error:', 1, true) end)
  vim.cmd('only')
  key('q')
  assert(not explorer.is_open() and vim.bo.filetype ~= 'robotcode_explorer', 'Closing the last window failed')
  print('Explorer integration passed: discovery, folding, source jumps, suite/all execution, running/results, persistence and unsaved-buffer guard.')
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print(err)
  local loaded, dap = pcall(require, 'dap')
  if loaded and dap.session() then dap.disconnect({ terminateDebuggee = true }) end
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
