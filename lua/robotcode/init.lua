local M = {}
local symbols = require('robotcode.symbols')
local project = require('robotcode.project')
local ns = vim.api.nvim_create_namespace('robotcode.tests')
local config
local pending = {}
local generations = {}
local defaults = {
  cmd = nil, -- argv list or function(ctx); auto-detect a project venv, then PATH
  root_dir = nil, -- string or function(bufnr, client)
  client_name = 'robotcode',
  profiles = {},
  robotcode_args = {}, -- Global CLI arguments, before the subcommand
  args = {}, -- Robot Framework arguments, shared by discover/run/debug
  paths = {}, -- Empty uses robot.toml paths, falling back to the project root
  env = nil,
  save_before_run = true,
  discovery_timeout = 30000,
  markers = true,
  marker_text = '▶ Run / Debug',
  dap = { console = 'internalConsole' },
  keys = { run = '<leader>rr', debug = '<leader>rd', test = '<leader>rt' },
}

local function notify(message, level)
  vim.notify('RobotCode: ' .. message, level or vim.log.levels.ERROR)
end

local function is_robot(bufnr)
  local ft = vim.bo[bufnr].filetype
  return ft == 'robot' or ft == 'robotframework'
end

local function get_client(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == config.client_name and client.supports_method('textDocument/documentSymbol') then
      return client
    end
  end
end

local function request_tests(bufnr, callback, quiet)
  local client = get_client(bufnr)
  if not client then
    if not quiet then
      notify('Attach the RobotCode LSP first (expected client name: ' .. config.client_name .. ').')
    end
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local accepted = client.request('textDocument/documentSymbol', {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, function(err, result)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if tick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
      if not quiet then notify('Buffer changed during test selection; try again.') end
      return
    end
    if err then
      if not quiet then notify(err.message or tostring(err)) end
      return
    end
    callback(symbols.tests(result), client)
  end, bufnr)
  if not accepted and not quiet then notify('Could not request test symbols from RobotCode.') end
end

function M.refresh(bufnr)
  if not config or not config.markers then return end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not is_robot(bufnr) then return end
  generations[bufnr] = (generations[bufnr] or 0) + 1
  local generation = generations[bufnr]
  request_tests(bufnr, function(tests)
    if generation ~= generations[bufnr] then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, test in ipairs(tests) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, test.range.start.line, 0, {
        sign_text = '▶', sign_hl_group = 'RobotCodeTest',
        virt_text = { { config.marker_text, 'RobotCodeTest' } }, virt_text_pos = 'eol',
      })
    end
  end, true)
end

local function context(bufnr, client)
  return { bufnr = bufnr, file = vim.api.nvim_buf_get_name(bufnr), root = project.root(bufnr, client, config.root_dir) }
end

local function debug_test(ctx, test)
  local ok, dap = pcall(require, 'dap')
  if not ok then
    notify('Install mfussenegger/nvim-dap to debug tests. Running tests does not require it.')
    return
  end
  if dap.session() then
    notify('A debug session is already active. Stop it before debugging another test.')
    return
  end
  local cmd = project.command(ctx, config.cmd)
  local adapter_args = vim.list_slice(cmd, 2)
  vim.list_extend(adapter_args, { 'debug-launch', '--stdio' })
  local adapter_env
  if config.env then
    adapter_env = {}
    -- nvim-dap forwards executable.options.env directly to libuv (a list of
    -- KEY=value strings), unlike termopen/vim.system and the launch request.
    for key, value in pairs(vim.tbl_extend('force', vim.fn.environ(), config.env)) do
      adapter_env[#adapter_env + 1] = key .. '=' .. value
    end
  end
  -- Use a dedicated adapter name without replacing an existing Robot adapter.
  dap.adapters.nvim_robotcode = {
    type = 'executable', command = cmd[1], args = adapter_args,
    options = { cwd = ctx.root, env = adapter_env, detached = false },
  }
  -- RobotCode waits for acknowledgment of its test-progress events. Without
  -- these replies a generic DAP client incurs a 15-second pause per event.
  for _, event in ipairs({ 'robotEnqueued', 'robotStarted', 'robotEnded', 'robotSetFailed', 'robotLog', 'robotMessage', 'robotExited' }) do
    dap.listeners.after['event_' .. event].nvim_robotcode = function(session, body)
      if session.config.type == 'nvim_robotcode' and body and body.synced then
        session:request('robot/sync', {}, function(err)
          if err then notify('Could not acknowledge debug event: ' .. tostring(err.message)) end
        end)
      end
    end
  end
  local launch = vim.tbl_deep_extend('force', {}, config.dap, {
    type = 'nvim_robotcode', request = 'launch', name = 'RobotCode: ' .. test.name,
    cwd = ctx.root, args = project.test_args(test, config),
    robotCodeArgs = project.global_args(config), env = config.env,
  })
  dap.run(launch)
end

local function run_test(ctx, test)
  local cmd = project.run(ctx, test, config)
  vim.cmd('botright 12new')
  local terminal_buf = vim.api.nvim_get_current_buf()
  vim.bo[terminal_buf].bufhidden = 'hide'
  local job = vim.fn.termopen(cmd, {
    cwd = ctx.root, env = config.env,
    on_exit = function(_, code)
      vim.schedule(function()
        notify(test.name .. (code == 0 and ' passed.' or ' exited with code ' .. code .. '.'),
          code == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
        vim.api.nvim_exec_autocmds('User', {
          pattern = 'RobotCodeTestFinished', modeline = false,
          data = { test = test, code = code, bufnr = terminal_buf },
        })
      end)
    end,
  })
  if job <= 0 then notify('Could not start RobotCode. Check cmd and the Python environment.') end
end

local function execute(mode)
  if not config then M.setup() end
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_robot(bufnr) then notify('Open a Robot Framework buffer first.'); return end
  if pending[bufnr] then notify('Test discovery is already in progress.', vim.log.levels.INFO); return end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then notify('Save the test file before running it.'); return end
  if vim.bo[bufnr].modified then
    if not config.save_before_run then notify('Save the test file before running it.'); return end
    local ok, err = pcall(vim.cmd, 'update')
    if not ok then notify(tostring(err)); return end
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  -- The LSP range is UTF-16; selection only needs the line, including its title.
  request_tests(bufnr, function(tests, client)
    if pending[bufnr] then notify('Test discovery is already in progress.', vim.log.levels.INFO); return end
    local selected = symbols.at_cursor(tests, cursor[1] - 1, 0)
    if not selected then notify('The cursor is outside a test case or task.'); return end
    local ctx = context(bufnr, client)
    -- Unsaved resources or other suites in this project can change execution.
    for _, other in ipairs(vim.api.nvim_list_bufs()) do
      if other ~= bufnr and vim.api.nvim_buf_is_loaded(other) and is_robot(other)
        and vim.bo[other].modified and project.contains(ctx.root, vim.api.nvim_buf_get_name(other)) then
        notify('Save other modified Robot Framework buffers in this project before running tests.'); return
      end
    end
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    pending[bufnr] = true
    local ok, err = pcall(vim.system, project.discover(ctx, config), {
      cwd = ctx.root, env = config.env, text = true, timeout = config.discovery_timeout,
    }, function(result)
      vim.schedule(function()
        pending[bufnr] = nil
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if tick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
          notify('Buffer changed during discovery; try again.'); return
        end
        if result.code ~= 0 then
          notify('Discovery failed (' .. result.code .. '): ' .. vim.trim(result.stderr or '')
            .. '\nCheck cmd, profiles and the RobotCode runner installation.'); return
        end
        local decoded, data = pcall(vim.json.decode, result.stdout)
        if not decoded or type(data) ~= 'table' or type(data.items) ~= 'table' then
          notify('Discovery did not return RobotCode JSON test items.'); return
        end
        local test, reason = project.find_test(data.items, file, selected.range.start.line + 1)
        if not test then notify(reason); return end
        if mode == 'debug' then debug_test(ctx, test) else run_test(ctx, test) end
      end)
    end)
    if not ok then pending[bufnr] = nil; notify('Could not start discovery: ' .. tostring(err)) end
  end)
end

function M.run_test() execute('run') end
function M.debug_test() execute('debug') end

function M.test()
  local bufnr, win, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
  vim.ui.select({ 'Run test', 'Debug test' }, { prompt = 'RobotCode test under cursor:' }, function(choice)
    if not choice or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then return end
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, cursor)
    execute(choice == 'Debug test' and 'debug' or 'run')
  end)
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  local group = vim.api.nvim_create_augroup('RobotCodeTests', { clear = true })
  vim.api.nvim_set_hl(0, 'RobotCodeTest', { link = 'DiagnosticHint', default = true })
  local function attach(bufnr)
    if not is_robot(bufnr) then return end
    local actions = { run = M.run_test, debug = M.debug_test, test = M.test }
    for name, action in pairs(actions) do
      if config.keys and config.keys[name] then
        vim.keymap.set('n', config.keys[name], action, { buffer = bufnr, desc = 'RobotCode: ' .. name .. ' test' })
      end
    end
    M.refresh(bufnr)
  end
  vim.api.nvim_create_autocmd({ 'FileType', 'LspAttach' }, {
    group = group, callback = function(event) attach(event.buf) end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'InsertLeave', 'BufEnter' }, {
    group = group, callback = function(event) M.refresh(event.buf) end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'LspDetach' }, {
    group = group, callback = function(event)
      generations[event.buf] = (generations[event.buf] or 0) + 1
      vim.api.nvim_buf_clear_namespace(event.buf, ns, 0, -1)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group, callback = function(event) generations[event.buf] = nil end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      attach(bufnr)
    end
  end
end

return M
