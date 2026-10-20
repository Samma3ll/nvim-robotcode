local M = {}
local projects, active = {}, {}

local function normalize(path)
  path = vim.fs.normalize(path)
  return vim.fn.has('win32') == 1 and path:lower() or path
end

function M.key(test)
  return normalize(test.source or '') .. '\n' .. (test.longname or '')
end

function M.tests(item)
  if item.type == 'test' or item.type == 'task' then return { item } end
  local tests = {}
  for _, child in ipairs(item.children or {}) do vim.list_extend(tests, M.tests(child)) end
  return tests
end

local function path(root)
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'robotcode', vim.fn.sha256(normalize(root)) .. '.json')
end

function M.get(root)
  root = normalize(root)
  if not projects[root] then
    local ok, lines = pcall(vim.fn.readfile, path(root))
    local decoded, data = false, nil
    if ok then decoded, data = pcall(vim.json.decode, table.concat(lines, '\n')) end
    projects[root] = decoded and type(data) == 'table' and type(data.tests) == 'table'
      and data or { tests = {} }
  end
  return projects[root]
end

function M.begin(run, root)
  run.root = root
  local tests = {}
  for _, test in ipairs(M.tests(run.test)) do tests[M.key(test)] = true end
  active[run.file] = { root = normalize(root), tests = tests }
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'RobotCodeTestStarted', modeline = false,
    data = { test = run.test, root = root, mode = run.mode },
  })
end

function M.running(root, item)
  root = normalize(root)
  local key = M.key(item)
  for _, run in pairs(active) do
    if run.root == root and run.tests[key] then return true end
  end
  return false
end

function M.finish(run, result)
  active[run.file] = nil
  if not run.root then return end
  local data = M.get(run.root)
  local completed = os.date('%Y-%m-%d %H:%M:%S')
  for _, test in ipairs(result.tests or { result }) do
    data.tests[M.key(test)] = vim.tbl_extend('force', {}, test, { completed_at = completed, mode = run.mode })
  end
  data.last = vim.tbl_extend('force', {}, result, { completed_at = completed })
  local file = path(run.root)
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(file), 'p')
    vim.fn.writefile({ vim.json.encode(data) }, file .. '.tmp')
    assert(vim.fn.rename(file .. '.tmp', file) == 0, 'Could not replace result file')
  end)
  if not ok then vim.notify('RobotCode: Could not save explorer results: ' .. tostring(err), vim.log.levels.WARN) end
end

return M
