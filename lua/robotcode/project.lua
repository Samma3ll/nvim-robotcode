local M = {}

function M.root(bufnr, client, option)
  if type(option) == 'function' then
    return option(bufnr, client)
  elseif type(option) == 'string' then
    return option
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  -- Prefer RobotCode configuration over a potentially broader Git/LSP root.
  return vim.fs.root(file, { 'robot.toml', '.robot.toml', 'pyproject.toml' })
    or (client and client.config.root_dir)
    or vim.fs.root(file, '.git')
    or vim.fs.dirname(file)
end

function M.command(ctx, option)
  if type(option) == 'function' then
    option = option(ctx)
  end
  if option then
    return vim.deepcopy(option)
  end
  for _, name in ipairs({ '.venv', 'venv' }) do
    for _, suffix in ipairs({ 'Scripts/python.exe', 'bin/python' }) do
      local python = vim.fs.joinpath(ctx.root, name, suffix)
      if vim.fn.executable(python) == 1 then
        return { python, '-m', 'robotcode.cli' }
      end
    end
  end
  return { 'robotcode' }
end

function M.global_args(config)
  local args = { '-dp', '.' } -- Fallback only: robot.toml paths take precedence.
  vim.list_extend(args, config.robotcode_args)
  for _, profile in ipairs(config.profiles) do
    vim.list_extend(args, { '--profile', profile })
  end
  return args
end

function M.discover(ctx, config)
  local args = M.command(ctx, config.cmd)
  vim.list_extend(args, M.global_args(config))
  vim.list_extend(args, { '--format', 'json', 'discover', 'all' })
  vim.list_extend(args, config.args)
  vim.list_extend(args, config.paths)
  return args
end

function M.test_args(test, config)
  local args = { '--by-longname', test.longname }
  vim.list_extend(args, config.args)
  vim.list_extend(args, config.paths)
  return args
end

function M.run(ctx, test, config)
  local args = M.command(ctx, config.cmd)
  vim.list_extend(args, M.global_args(config))
  args[#args + 1] = 'robot'
  vim.list_extend(args, M.test_args(test, config))
  return args
end

local function normalize(path)
  path = vim.fs.normalize(path)
  if vim.fn.has('win32') == 1 then
    path = path:lower()
  end
  return path
end

function M.contains(root, file)
  root = normalize(root):gsub('/+$', '')
  file = normalize(file)
  return file == root or file:sub(1, #root + 1) == root .. '/'
end

function M.find_test(items, file, line)
  local matches = {}
  local function visit(nodes)
    for _, item in ipairs(nodes or {}) do
      if (item.type == 'test' or item.type == 'task') and item.source
        and normalize(item.source) == normalize(file) and item.lineno == line then
        matches[#matches + 1] = item
      end
      visit(item.children)
    end
  end
  visit(items)
  if #matches ~= 1 then
    return nil, #matches == 0
      and 'Test was not discovered. Check paths, profiles, tag filters and saved files.'
      or 'Several discovered tests share this source line; cannot select a single test.'
  end
  local selected = matches[1]
  -- ByLongName cannot distinguish duplicate names. Refuse instead of running extras.
  local count = 0
  local function count_names(nodes)
    for _, item in ipairs(nodes or {}) do
      if item.type ~= 'workspace' and item.longname == selected.longname then
        count = count + 1
      end
      count_names(item.children)
    end
  end
  count_names(items)
  if count > 1 then
    return nil, 'Tests have duplicate full names; rename them before running a single test.'
  end
  return selected
end

return M
