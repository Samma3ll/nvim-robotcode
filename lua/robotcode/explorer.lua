local M = {}
local project = require('robotcode.project')
local state = require('robotcode.state')
local results = require('robotcode.results')
local ns = vim.api.nvim_create_namespace('robotcode.explorer')
local ctx, config, execute, buf, win, source_win
local items, rows, collapsed = {}, {}, {}
local loading, error_message, generation = false, nil, 0
local highlights = {
  PASS = 'DiagnosticOk', FAIL = 'DiagnosticError', ERROR = 'DiagnosticError',
  SKIP = 'DiagnosticWarn', STOPPED = 'DiagnosticWarn', UNKNOWN = 'DiagnosticWarn',
  RUNNING = 'DiagnosticInfo', PARTIAL = 'DiagnosticHint',
}
local badges = { RUNNING = 'RUN ', PARTIAL = 'PART', UNKNOWN = '????', STOPPED = 'STOP', ERROR = 'ERR ' }

local function clean(text)
  return tostring(text or ''):gsub('[%z\1-\31\127]', ' ')
end

local function id(item)
  return item.id or (item.type .. ':' .. state.key(item))
end

local function notify(text)
  vim.notify('RobotCode: ' .. text, vim.log.levels.WARN)
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.close()
  generation, loading = generation + 1, false
  if M.is_open() then
    if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1 then
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
    else
      vim.api.nvim_win_close(win, true)
    end
  end
  win = nil
end

local function selected()
  if M.is_open() then return rows[vim.api.nvim_win_get_cursor(win)[1]] end
end

function M.status(item)
  local counts, total = {}, 0
  for _, test in ipairs(state.tests(item)) do
    local saved = state.get(ctx.root).tests[state.key(test)]
    local status = state.running(ctx.root, test) and 'RUNNING' or saved and saved.status or 'NONE'
    counts[status], total = (counts[status] or 0) + 1, total + 1
  end
  for _, status in ipairs({ 'RUNNING', 'ERROR', 'FAIL', 'STOPPED', 'UNKNOWN' }) do
    if counts[status] then return status end
  end
  if counts.NONE then return counts.NONE == total and 'NONE' or 'PARTIAL' end
  if counts.PASS then return 'PASS' end
  return counts.SKIP and 'SKIP' or 'NONE'
end

function M.render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local current = selected()
  local lines, colors = { 'RobotCode Test Explorer', '' }, {}
  local last = state.get(ctx.root).last
  if last then
    lines[#lines + 1] = 'Latest: ' .. clean(last.completed_at) .. ' · ' .. clean(last.mode)
    lines[#lines + 1] = clean(last.longname or last.name) .. ' [' .. clean(last.status) .. ']'
    if last.tests then
      local counts = { PASS = 0, FAIL = 0, SKIP = 0 }
      for _, test in ipairs(last.tests) do counts[test.status] = (counts[test.status] or 0) + 1 end
      lines[#lines + 1] = string.format('%d passed · %d failed · %d skipped', counts.PASS, counts.FAIL, counts.SKIP)
    elseif last.elapsed_ms then
      lines[#lines + 1] = string.format('Duration: %.3f s', last.elapsed_ms / 1000)
    end
  else
    lines[#lines + 1] = 'No test runs yet.'
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = loading and 'Discovering tests…' or error_message and ('Discovery error: ' .. clean(error_message))
    or 'Suites / tests (latest known result)'
  lines[#lines + 1] = ''
  rows = {}
  local target
  local function visit(nodes, depth)
    for _, item in ipairs(nodes) do
      if item.type == 'workspace' then
        visit(item.children or {}, depth)
      else
        local branch = item.type == 'suite'
        local status = M.status(item)
        local prefix = string.rep('  ', depth) .. (branch and (collapsed[id(item)] and '▸ ' or '▾ ') or '  ')
        local badge = '[' .. (status == 'NONE' and ' -- ' or badges[status] or status) .. '] '
        local line = prefix .. badge .. clean(item.name)
        local saved = state.get(ctx.root).tests[state.key(item)]
        if not branch and saved and saved.elapsed_ms then line = line .. string.format('  %.3fs', saved.elapsed_ms / 1000) end
        lines[#lines + 1], rows[#lines + 1] = line, item
        colors[#colors + 1] = { #lines - 1, #prefix, #prefix + #badge, highlights[status] or 'Comment' }
        if current and id(current) == id(item) then target = #lines end
        if branch and not collapsed[id(item)] then visit(item.children or {}, depth + 1) end
      end
    end
  end
  visit(items, 0)
  if #items == 0 and not loading and not error_message then lines[#lines + 1] = 'No tests discovered for these paths/profiles.' end
  vim.list_extend(lines, { '', 'Enter fold / source · o source · p result', 'r run · d debug · R run all', 'gR refresh · q close' })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, 'Title', 0, 0, -1)
  for _, color in ipairs(colors) do vim.api.nvim_buf_add_highlight(buf, ns, color[4], color[1], color[2], color[3]) end
  if M.is_open() then
    if not target then for line in ipairs(lines) do if rows[line] then target = line; break end end end
    if target then vim.api.nvim_win_set_cursor(win, { target, 0 }) end
  end
end

local function robot_buffers()
  local ticks = {}
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(other) and project.contains(ctx.root, vim.api.nvim_buf_get_name(other)) then
      local ft = vim.bo[other].filetype
      if ft == 'robot' or ft == 'robotframework' then
        if vim.bo[other].modified then return nil end
        ticks[other] = vim.api.nvim_buf_get_changedtick(other)
      end
    end
  end
  return ticks
end

function M.refresh(callback)
  if loading then notify('Test discovery is already in progress.'); return end
  local ticks
  if callback then
    if vim.api.nvim_buf_is_valid(ctx.bufnr) and vim.bo[ctx.bufnr].modified and config.save_before_run then
      local ok, err = pcall(vim.api.nvim_buf_call, ctx.bufnr, function() vim.cmd('update') end)
      if not ok then notify(tostring(err)); return end
    end
    ticks = robot_buffers()
    if not ticks then notify('Save modified Robot Framework buffers in this project before running tests.'); return end
  end
  loading, error_message = true, nil
  generation = generation + 1
  local token, root = generation, ctx.root
  M.render()
  local ok, err = pcall(vim.system, project.discover(ctx, config), {
    cwd = root, env = config.env, text = true, timeout = config.discovery_timeout,
  }, function(result)
    vim.schedule(function()
      if token ~= generation then return end
      loading = false
      if result.code ~= 0 then
        error_message = 'Discovery failed (' .. result.code .. '): ' .. vim.trim(result.stderr or '')
      else
        local decoded, data = pcall(vim.json.decode, result.stdout)
        if not decoded or type(data) ~= 'table' or type(data.items) ~= 'table' then
          error_message = 'Discovery did not return RobotCode JSON test items.'
        else
          items = data.items
        end
      end
      M.render()
      if error_message then notify(error_message); return end
      if callback then
        local now = robot_buffers()
        if not now or not vim.deep_equal(ticks, now) then notify('Buffers changed during discovery; try again.'); return end
        callback()
      end
    end)
  end)
  if not ok then loading, error_message = false, tostring(err); M.render(); notify(error_message) end
end

function M.run(mode, all)
  local item = all and { type = 'workspace', name = 'All tests', children = items } or selected()
  if not item then return end
  local wanted = id(item)
  M.refresh(function()
    local found
    local names = {}
    local function visit(nodes)
      for _, node in ipairs(nodes) do
        if node.type ~= 'workspace' then names[node.longname] = (names[node.longname] or 0) + 1 end
        if id(node) == wanted then found = node end
        visit(node.children or {})
      end
    end
    visit(items)
    if all then found = { type = 'workspace', name = 'All tests', children = items } end
    if not found then notify('Selected test or suite changed; select it again.'); return end
    local tests = state.tests(found)
    if #tests == 0 then notify('No tests in this selection.'); return end
    if found.type ~= 'workspace' and names[found.longname] ~= 1 then
      notify('Duplicate full names; cannot select a single test or suite.'); return
    end
    for _, test in ipairs(tests) do
      if names[test.longname] ~= 1 then notify('Tests have duplicate full names; rename them before running.'); return end
      if state.running(ctx.root, test) then notify('Selected tests are already running.'); return end
    end
    execute(ctx, found, mode or 'run')
  end)
end

function M.source()
  local item = selected()
  if not item or not item.source or vim.fn.filereadable(item.source) ~= 1 then return end
  if source_win and vim.api.nvim_win_is_valid(source_win) and source_win ~= win then
    vim.api.nvim_set_current_win(source_win)
  else
    vim.cmd('rightbelow vnew')
    source_win = vim.api.nvim_get_current_win()
  end
  vim.cmd.edit(vim.fn.fnameescape(item.source))
  vim.api.nvim_win_set_cursor(0, { math.max(1, item.lineno or 1), 0 })
end

function M.toggle()
  local item = selected()
  if not item then return end
  if item.type ~= 'suite' then M.source(); return end
  collapsed[id(item)] = not collapsed[id(item)]
  M.render()
end

function M.result()
  local item = selected()
  if not item then return end
  local saved = state.get(ctx.root)
  if item.type == 'test' or item.type == 'task' then
    local result = saved.tests[state.key(item)]
    if not result then notify('No result for this test yet.'); return end
    return results.show(result, config.result_popup)
  end
  local lines = {}
  for _, test in ipairs(state.tests(item)) do
    local result = saved.tests[state.key(test)]
    lines[#lines + 1] = test.name .. ' [' .. (result and result.status or 'NOT RUN') .. ']'
    if result and result.message ~= '' then lines[#lines + 1] = result.message end
  end
  results.show({ name = item.name, status = M.status(item), message = table.concat(lines, '\n\n') }, config.result_popup)
end

function M.open(context, options, action)
  generation, loading = generation + 1, false
  local changed = not ctx or not project.contains(ctx.root, context.root) or not project.contains(context.root, ctx.root)
  if changed then
    items, collapsed, error_message = {}, {}, nil
  end
  ctx, config, execute = context, options, action
  if vim.api.nvim_get_current_win() ~= win then source_win = vim.api.nvim_get_current_win() end
  if not M.is_open() then
    vim.cmd('topleft vnew')
    win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
    vim.bo[buf].filetype, vim.bo[buf].buflisted = 'robotcode_explorer', false
    vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].wrap = false, false, false
    vim.wo[win].signcolumn, vim.wo[win].foldcolumn, vim.wo[win].winfixwidth = 'no', '0', true
    vim.api.nvim_win_set_width(win, math.max(20, (options.explorer or {}).width or 48))
    for key, callback in pairs({
      ['<CR>'] = M.toggle, o = M.source, p = M.result, q = M.close,
      r = function() M.run('run') end, d = function() M.run('debug') end,
      R = function() M.run('run', true) end, gR = function() M.refresh() end,
    }) do
      vim.keymap.set('n', key, callback, { buffer = buf, silent = true, nowait = true, desc = 'RobotCode explorer: ' .. key })
    end
    local group = vim.api.nvim_create_augroup('RobotCodeExplorer', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group, pattern = { 'RobotCodeTestStarted', 'RobotCodeTestFinished' },
      callback = function(event)
        local root = event.data and event.data.root
        if ctx and root and project.contains(root, ctx.root) and project.contains(ctx.root, root) then M.render() end
      end,
    })
  else
    vim.api.nvim_set_current_win(win)
  end
  M.render()
  M.refresh()
end

return M
