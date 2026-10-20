local M = {}

-- RobotCode represents test cases/tasks as Class symbols; keywords are Function.
-- Discovery currently only returns title positions, so use LSP for body ranges.
function M.tests(symbols)
  local tests = {}
  local function visit(items)
    for _, item in ipairs(items or {}) do
      if item.kind == vim.lsp.protocol.SymbolKind.Class and item.range then
        tests[#tests + 1] = item
      else
        visit(item.children)
      end
    end
  end
  visit(symbols)
  table.sort(tests, function(a, b) return a.range.start.line < b.range.start.line end)
  return tests
end

function M.at_cursor(tests, line, character)
  for _, test in ipairs(tests) do
    local first, last = test.range.start, test.range['end']
    if (line > first.line or (line == first.line and character >= first.character))
      and (line < last.line or (line == last.line and character < last.character)) then
      return test
    end
  end
end

return M
