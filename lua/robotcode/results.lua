local M = {}
local last_result, last_options, window
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local function clean(value)
  return tostring(value or ''):gsub('\27%[[%d;?]*[A-Za-z]', '')
    :gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('[%z\1-\8\11\12\14-\31\127]', '')
end

function M.prepare(test, config, mode)
  local run = {
    file = vim.fn.tempname() .. '.json', test = vim.deepcopy(test), mode = mode,
    options = vim.deepcopy(config.result_popup),
  }
  local run_config = vim.deepcopy(config)
  local debug_env = mode == 'debug' and config.dap and config.dap.env or {}
  run_config.env = vim.tbl_extend('force', {}, debug_env or {}, config.env or {}, { NVIM_ROBOTCODE_RESULT_FILE = run.file })
  vim.list_extend(run_config.args, { '--listener', vim.fs.joinpath(plugin_root, 'python', 'robotcode_nvim_listener.py') })
  return run, run_config
end

function M.read(run, code, fallback, cancelled)
  local result = { name = run.test.name, longname = run.test.longname, mode = run.mode, code = code }
  if cancelled then
    result.status, result.message = 'STOPPED', fallback or 'Debug session ended before a final test result was reported.'
    return result
  end
  local ok, lines = pcall(vim.fn.readfile, run.file)
  local decoded, data = false, nil
  if ok then decoded, data = pcall(vim.json.decode, table.concat(lines, '\n')) end
  if decoded and type(data) == 'table' and type(data.tests) == 'table' then
    for _, test in ipairs(data.tests) do
      if test.longname == run.test.longname then
        result.status, result.message, result.elapsed_ms = test.status, clean(test.message), test.elapsed_ms
        break
      end
    end
  end
  if not result.status or (code ~= 0 and result.status == 'PASS') then
    result.status = code == 0 and 'UNKNOWN' or 'ERROR'
    result.message = 'RobotCode exited with code ' .. tostring(code) .. '.'
    if code == 0 then result.message = result.message .. '\nNo structured test result was captured.' end
    if fallback and vim.trim(fallback) ~= '' then result.message = result.message .. '\n\n' .. clean(fallback) end
  elseif result.status == 'FAIL' and result.message == '' then
    result.message = 'The test failed without a failure message.'
  end
  return result
end

function M.close()
  if window and vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
  window = nil
end

function M.show(result, options)
  options = type(options) == 'table' and options or {}
  M.close()
  local lines = { result.status .. ': ' .. clean(result.name), '' }
  if result.elapsed_ms then
    lines[#lines + 1] = string.format('Duration: %.3f s', result.elapsed_ms / 1000)
    lines[#lines + 1] = ''
  end
  if result.message and result.message ~= '' then
    vim.list_extend(lines, vim.split(clean(result.message), '\n', { plain = true }))
  elseif result.status == 'PASS' then
    lines[#lines + 1] = 'Test passed.'
  elseif result.status == 'SKIP' then
    lines[#lines + 1] = 'Test skipped.'
  end
  vim.list_extend(lines, { '', 'q / <Esc> / <Enter> to close' })
  local width = 40
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.max(1, math.min(width, options.max_width or 90, vim.o.columns - 4))
  local height = 0
  for _, line in ipairs(lines) do height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width)) end
  height = math.max(1, math.min(height, options.max_height or 20, vim.o.lines - vim.o.cmdheight - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'wipe', false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].filetype = false, 'robotcode_result'
  local hl = ({ PASS = 'DiagnosticOk', FAIL = 'DiagnosticError', ERROR = 'DiagnosticError', SKIP = 'DiagnosticWarn' })[result.status] or 'DiagnosticWarn'
  window = vim.api.nvim_open_win(buf, options.focus ~= false, {
    relative = 'editor', style = 'minimal', border = options.border or 'rounded',
    title = ' RobotCode result ', title_pos = 'center', width = width, height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    noautocmd = true,
  })
  vim.wo[window].wrap, vim.wo[window].linebreak = true, true
  vim.wo[window].winhl = 'Normal:NormalFloat,FloatBorder:' .. hl
  vim.api.nvim_buf_add_highlight(buf, -1, hl, 0, 0, -1)
  for _, key in ipairs({ 'q', '<Esc>', '<CR>' }) do
    vim.keymap.set('n', key, M.close, { buffer = buf, silent = true, nowait = true, desc = 'Close test result' })
  end
  return buf, window
end

function M.finish(run, code, fallback, cancelled)
  if run.finished then return end
  run.finished = true
  local result = M.read(run, code, fallback, cancelled)
  vim.fn.delete(run.file)
  vim.fn.delete(run.file .. '.tmp')
  last_result, last_options = result, run.options
  if run.options ~= false and (type(run.options) ~= 'table' or run.options.enabled ~= false) then
    M.show(result, run.options)
  else
    vim.notify('RobotCode: ' .. result.status .. ': ' .. result.name
      .. (result.message ~= '' and '\n' .. result.message or ''),
      result.status == 'PASS' and vim.log.levels.INFO or vim.log.levels.WARN)
  end
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'RobotCodeTestFinished', modeline = false,
    data = { test = run.test, code = code, bufnr = run.terminal_buf, mode = run.mode, result = result },
  })
end

function M.show_last()
  if not last_result then
    vim.notify('RobotCode: No test result yet.', vim.log.levels.INFO)
    return
  end
  return M.show(last_result, vim.tbl_extend('force', {}, type(last_options) == 'table' and last_options or {}, { focus = true }))
end

return M
