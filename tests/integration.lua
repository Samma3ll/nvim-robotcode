-- Real RobotCode LSP, runner and (optionally) nvim-dap integration. No mocks.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd('runtime plugin/robotcode.lua')
local python = vim.fs.joinpath(root, '.venv', vim.fn.has('win32') == 1 and 'Scripts/python.exe' or 'bin/python')
local fixture = vim.fs.joinpath(root, 'tests', 'fixtures', 'project')
local file = vim.fs.joinpath(fixture, 'suites', 'cursor.robot')
local output = vim.fs.joinpath(root, 'tests', '.output')
vim.fn.mkdir(output, 'p')
local messages = {}
vim.notify = function(message, level)
  messages[#messages + 1] = { message = message, level = level }
  print(message)
end
local function wait_for(description, predicate, timeout)
  assert(vim.wait(timeout or 30000, predicate, 50), 'Timed out: ' .. description .. '\n' .. vim.inspect(messages))
end
local function request(client, bufnr)
  local response, err = client.request_sync('textDocument/documentSymbol', {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, 30000, bufnr)
  assert(response and not response.err, vim.inspect(err or response))
  return require('robotcode.symbols').tests(response.result)
end

local function main()
  require('robotcode').setup({
    cmd = { python, '-m', 'robotcode.cli' }, profiles = { 'example' },
    args = { '--outputdir', output },
    env = { ROBOTCODE_NVIM_CHECK = 'through env' },
    dap = { env = { ROBOTCODE_DAP_ONLY = 'dap-only env' } },
  })
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.bo.filetype = 'robot'
  local bufnr = vim.api.nvim_get_current_buf()
  local client_id = vim.lsp.start({
    name = 'robotcode', cmd = { python, '-m', 'robotcode.cli', 'language-server' },
    root_dir = fixture, get_language_id = function() return 'robotframework' end,
  })
  assert(client_id, 'LSP did not start')
  local client = vim.lsp.get_client_by_id(client_id)
  wait_for('RobotCode initialization', function() return client.initialized end)
  local tests = request(client, bufnr)
  assert(#tests == 3, vim.inspect(tests))
  assert(tests[2].name == 'Literal [x] * ? test')
  local parsed = require('robotcode.symbols')
  assert(parsed.at_cursor(tests, 12, 0).name == tests[2].name, 'Test body selection failed')
  assert(not parsed.at_cursor(tests, 19, 0), 'Selected a keyword')
  require('robotcode').refresh()
  local ns = vim.api.nvim_get_namespaces()['robotcode.tests']
  wait_for('three title markers', function()
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) == 3
  end)
  assert(vim.fn.exists(':RobotCodeRunTest') == 2)
  assert(vim.fn.maparg('<leader>rr', 'n') ~= '')

  -- Reject keyword positions before starting any runner.
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  vim.cmd('RobotCodeRunTest')
  wait_for('keyword rejection', function()
    return #messages > 0 and messages[#messages].message:find('outside a test case')
  end)

  local finished
  vim.api.nvim_create_autocmd('User', {
    pattern = 'RobotCodeTestFinished', callback = function(event) finished = event.data end,
  })
  vim.api.nvim_win_set_cursor(0, { 13, 0 })
  vim.cmd('RobotCodeRunTest')
  wait_for('real terminal run', function() return finished ~= nil end)
  assert(finished.code == 0, vim.inspect(finished))
  assert(finished.result.status == 'PASS', vim.inspect(finished))
  local function check_popup(status, message)
    local popup = vim.api.nvim_get_current_buf()
    assert(vim.bo[popup].filetype == 'robotcode_result', 'Result popup did not take focus')
    assert(vim.api.nvim_win_get_config(0).relative == 'editor', 'Result is not a floating popup')
    local text = table.concat(vim.api.nvim_buf_get_lines(popup, 0, -1, false), '\n')
    assert(text:find(status .. ':', 1, true), text)
    if message then assert(text:find(message, 1, true), text) end
    local mapping = vim.fn.maparg('q', 'n', false, true)
    assert(type(mapping.callback) == 'function', 'Popup has no close mapping')
    mapping.callback()
    assert(not vim.api.nvim_buf_is_valid(popup), 'Popup buffer was not cleaned up')
  end
  check_popup('PASS', 'Test passed.')
  local xml = table.concat(vim.fn.readfile(vim.fs.joinpath(output, 'output.xml')), '\n')
  assert(xml:find('name="Literal %[x%] %* %? test"'))
  assert(not xml:find('name="First test"') and not xml:find('name="Last test"') and not xml:find('name="Other"'))
  assert(xml:find('from profile'), 'Profile was not used')
  assert(xml:find('through env'), 'Environment was not passed to the runner')
  assert(xml:find('inherited'), 'Parent suite setup did not run')
  print('PASS: terminal ran exactly the cursor test, using robot.toml, profile and parent suite setup.')

  if vim.env.ROBOTCODE_TEST_DAP == '1' then
    vim.opt.runtimepath:prepend(vim.fs.joinpath(root, '.deps', 'nvim-dap'))
    local dap = require('dap')
    dap.set_log_level('TRACE')
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_win_set_cursor(0, { 13, 0 })
    dap.toggle_breakpoint()
    local stops, terminated, exited, frame = 0
    dap.listeners.after.event_stopped.robotcode_test = function(session)
      stops = stops + 1
    end
    dap.listeners.after.event_terminated.robotcode_test = function() terminated = true end
    dap.listeners.after.event_exited.robotcode_test = function(_, body) exited = body.exitCode end
    vim.cmd('RobotCodeDebugTest')
    wait_for('real DAP breakpoint', function()
      local session = dap.session()
      frame = session and session.current_frame
      return stops >= 1 and frame ~= nil
    end, 45000)
    assert(frame.line == 13, vim.inspect(frame))
    print('PASS: debugger stopped on the Robot Framework breakpoint at line 13.')
    dap.step_over()
    wait_for('step to next Robot keyword', function()
      local session = dap.session()
      frame = session and session.current_frame
      return stops >= 2 and frame and frame.line == 14
    end)
    print('PASS: debugger stepped to the next Robot Framework keyword at line 14.')
    dap.continue()
    wait_for('debug completion', function() return terminated and exited ~= nil end)
    assert(exited == 0, 'Debugger test process exited with ' .. tostring(exited))
    xml = table.concat(vim.fn.readfile(vim.fs.joinpath(output, 'output.xml')), '\n')
    assert(xml:find('name="Literal %[x%] %* %? test"') and not xml:find('name="First test"') and not xml:find('name="Last test"'))
    assert(xml:find('from profile') and xml:find('inherited') and xml:find('through env'))
    assert(xml:find('dap%-only env'), 'Existing DAP environment overrides were not preserved')
    assert(finished.mode == 'debug' and finished.result.status == 'PASS', vim.inspect(finished))
    check_popup('PASS', 'Test passed.')
    print('PASS: real nvim-dap session completed exactly the selected test.')
  end

  local function run_case(name, line, mode, status, message)
    require('robotcode.results').close()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(fixture, 'suites', name .. '.robot')))
    vim.bo.filetype = 'robot'
    vim.lsp.buf_attach_client(vim.api.nvim_get_current_buf(), client_id)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    finished = nil
    vim.cmd(mode == 'debug' and 'RobotCodeDebugTest' or 'RobotCodeRunTest')
    wait_for(mode .. ' result for ' .. name, function() return finished ~= nil end, 45000)
    assert(finished.result.status == status, vim.inspect(finished))
    assert(finished.result.message:find(message, 1, true), vim.inspect(finished))
    check_popup(status, message)
    print('PASS: ' .. mode .. ' popup shows ' .. status .. ' and full reason for ' .. name .. '.')
    return finished
  end
  local failure_message = 'Expected 42 but got 7.\nSecond line: détail & <value>'
  local failure = run_case('results', 3, 'run', 'FAIL', failure_message)
  assert(failure.code == 1)
  run_case('results', 6, 'run', 'SKIP', 'This environment is unavailable.')
  run_case('teardown', 6, 'run', 'FAIL', 'Cleanup failed after the test body passed.')
  vim.cmd('RobotCodeResult')
  check_popup('FAIL', 'Cleanup failed after the test body passed.')
  if vim.env.ROBOTCODE_TEST_DAP == '1' then
    local dap = require('dap')
    wait_for('prior debug session to close', function() return dap.session() == nil end)
    dap.clear_breakpoints()
    dap.defaults.nvim_robotcode.exception_breakpoints = {}
    run_case('results', 3, 'debug', 'FAIL', failure_message)
    wait_for('failed debug session to close', function() return dap.session() == nil end)
    run_case('teardown', 6, 'debug', 'FAIL', 'Cleanup failed after the test body passed.')
  end
  vim.lsp.stop_client(client_id, true)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print(err)
  local loaded, dap = pcall(require, 'dap')
  if loaded and dap.session() then dap.disconnect({ terminateDebuggee = true }) end
  vim.lsp.stop_client(vim.lsp.get_clients(), true)
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
