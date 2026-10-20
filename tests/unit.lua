local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local symbols = require('robotcode.symbols')
local project = require('robotcode.project')
local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), 'Expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end
local function symbol(name, kind, first, last, children)
  return { name = name, kind = kind, range = {
    start = { line = first, character = 0 }, ['end'] = { line = last, character = 0 },
  }, children = children }
end
local tests = symbols.tests({
  symbol('Tests', 2, 0, 10, { symbol('A', 5, 1, 4), symbol('B', 5, 4, 8) }),
  symbol('Keywords', 2, 10, 20, { symbol('Helper', 12, 11, 15) }),
})
equal(2, #tests)
equal('A', symbols.at_cursor(tests, 1, 0).name)
equal('A', symbols.at_cursor(tests, 3, 4).name)
equal('B', symbols.at_cursor(tests, 4, 0).name)
equal(nil, symbols.at_cursor(tests, 8, 0))
equal(nil, symbols.at_cursor(tests, 11, 0))
equal(nil, symbols.at_cursor(tests, 0, 0))

local file = vim.fs.joinpath(root, 'tests', 'fixtures', 'project', 'suites', 'cursor.robot')
local selected = { type = 'test', name = 'Literal [x] * ? test', longname = 'Suites.Cursor.Literal [x] * ? test', source = file, lineno = 12 }
local items = { { type = 'suite', children = { selected } } }
equal(selected, project.find_test(items, file, 12))
equal(nil, project.find_test(items, file, 13))
items[1].children[2] = vim.tbl_extend('force', selected, { lineno = 20 })
local _, reason = project.find_test(items, file, 12)
assert(reason:find('duplicate full names'))
items[1].children[2] = { type = 'suite', longname = selected.longname, children = {} }
local _, suite_reason = project.find_test(items, file, 12)
assert(suite_reason:find('duplicate full names'), 'A colliding suite would also be selected by ByLongName')
local config = { cmd = { 'python path', '-m', 'robotcode.cli' }, robotcode_args = {}, profiles = { 'dev' }, args = { '--variable', 'X:value with spaces' }, paths = {} }
local ctx = { root = root }
assert(project.contains(root, file))
assert(not project.contains(root, root .. '-other/file.robot'))
local args = project.run(ctx, selected, config)
equal({ 'python path', '-m', 'robotcode.cli', '-dp', '.', '--profile', 'dev', 'robot', '--by-longname', selected.longname, '--variable', 'X:value with spaces' }, args)
print('Unit checks passed: symbol boundaries, keyword rejection, duplicate refusal and literal argv.')
vim.cmd('qa!')
