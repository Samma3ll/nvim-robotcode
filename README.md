# nvim-robotcode

Run or debug the Robot Framework test containing your cursor, from its title or
anywhere in its body. Uses your existing RobotCode LSP for test ranges,
RobotCode's CLI for discovery/execution, and `nvim-dap` for debugging.

Optional `▶ Run / Debug` markers appear next to test titles. These are Neovim
signs and virtual text: use the commands or mappings to activate them; they are
not clickable VS Code buttons.

## Requirements

- Neovim 0.10 or newer.
- A working **RobotCode** LSP attached to the buffer, named `robotcode` by default.
  This plugin adds test actions; it does not replace your LSP configuration.
- Robot Framework and RobotCode with the runner/debugger in your test project's
  Python environment:

  ```sh
  python -m pip install 'robotcode[runner,debugger,languageserver]' robotframework
  ```

- [mfussenegger/nvim-dap](https://github.com/mfussenegger/nvim-dap) for debugging.
  Choose a release compatible with your Neovim version. Running needs no DAP plugin.

## Install from GitHub

Repository: [Samma3ll/nvim-robotcode](https://github.com/Samma3ll/nvim-robotcode).

Install the Python requirements above in your Robot Framework environment, then
choose one of the following plugin installation methods. Keep your existing
RobotCode LSP configuration enabled.

### lazy.nvim

Add this spec to your `lazy.nvim` plugins:

```lua
{
  'Samma3ll/nvim-robotcode',
  ft = { 'robot', 'robotframework' },
  dependencies = { 'mfussenegger/nvim-dap' },
  opts = {},
  config = function(_, opts)
    require('robotcode').setup(opts)
  end,
}
```

Restart Neovim and run `:Lazy sync`. Open a `.robot` file, wait for RobotCode to
attach, then use `<leader>rr` to run the test under your cursor or `<leader>rd`
to debug it. If you only want running, you can omit the `nvim-dap` dependency.

### vim-plug

Add these entries between your existing `plug#begin()` and `plug#end()` calls:

```vim
Plug 'Samma3ll/nvim-robotcode'
Plug 'mfussenegger/nvim-dap'
```

Run `:PlugInstall`, then add this to your Lua configuration (or use a `lua` block
in `init.vim`):

```lua
require('robotcode').setup()
```

### Native Neovim packages

Clone the repository into your Neovim package directory. With the default data
directory on Linux/macOS:

```sh
git clone https://github.com/Samma3ll/nvim-robotcode.git ~/.local/share/nvim/site/pack/plugins/start/nvim-robotcode
```

With the default data directory on Windows (PowerShell):

```powershell
$pluginPath = Join-Path $env:LOCALAPPDATA 'nvim-data/site/pack/plugins/start/nvim-robotcode'
git clone https://github.com/Samma3ll/nvim-robotcode.git $pluginPath
```

For a custom data directory, use `:echo stdpath('data')` and clone into
`site/pack/plugins/start/nvim-robotcode` underneath it. Install `nvim-dap`
separately for debugging. Add `require('robotcode').setup()` to your Lua
configuration and restart Neovim.

### LSP setup

Keep your existing RobotCode LSP setup. If configuring the server manually,
Neovim's `robot` filetype must be sent to the server as `robotframework`:

```lua
-- Include this in your existing RobotCode LSP config:
get_language_id = function() return 'robotframework' end,
```

The [nvim-lspconfig RobotCode configuration](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/robotcode.lua)
already supplies that language ID.

## Use

Place the cursor on a test title or inside its body:

| Default mapping | Command | Action |
| --- | --- | --- |
| `<leader>rr` | `:RobotCodeRunTest` | Run this test in a terminal split |
| `<leader>rd` | `:RobotCodeDebugTest` | Debug this test with `nvim-dap` |
| `<leader>rt` | `:RobotCodeTest` | Choose Run or Debug |
| — | `:RobotCodeRefresh` | Refresh title markers |

Mappings are buffer-local. Keywords and settings sections do not select a test.
Tasks use the same actions.

For debugging, set a breakpoint before `:RobotCodeDebugTest`:

```lua
vim.keymap.set('n', '<leader>db', function() require('dap').toggle_breakpoint() end)
vim.keymap.set('n', '<F5>', function() require('dap').continue() end)
vim.keymap.set('n', '<F10>', function() require('dap').step_over() end)
vim.keymap.set('n', '<F11>', function() require('dap').step_into() end)
vim.keymap.set('n', '<leader>dq', function() require('dap').terminate() end)
vim.keymap.set('n', '<leader>dr', function() require('dap').repl.open() end)
```

Debug output goes to the DAP REPL by default. Existing `nvim-dap-ui` and DAP
breakpoint/stepping mappings work as usual. Robot keyword debugging is included;
stepping into Python libraries requires additional debugpy integration.

## Configuration

```lua
require('robotcode').setup({
  -- Default: .venv/venv Python in the project, otherwise robotcode on PATH.
  -- Use the Python environment containing your Robot libraries and RobotCode.
  -- cmd = { '/path/to/project/.venv/bin/python', '-m', 'robotcode.cli' },
  -- cmd = { 'C:/path/to/project/.venv/Scripts/python.exe', '-m', 'robotcode.cli' },
  -- A function(ctx) returning argv is also supported. ctx.root is the project.

  -- root_dir = '/path/to/project', -- or function(bufnr, client) return ... end
  client_name = 'robotcode',
  profiles = {},                      -- e.g. { 'dev' }
  robotcode_args = {},                -- global CLI options, e.g. { '--config', 'custom.toml' }
  args = {},                          -- Robot options, e.g. { '--variable', 'BROWSER:chromium' }
  paths = {},                         -- empty: robot.toml paths, otherwise fallback '.'
  env = nil,                          -- e.g. { ENVIRONMENT = 'local' }; inherits other vars
  save_before_run = true,
  discovery_timeout = 30000,          -- milliseconds
  markers = true,
  marker_text = '▶ Run / Debug',
  keys = { run = '<leader>rr', debug = '<leader>rd', test = '<leader>rt' },
  -- keys = false,                   -- use only commands / your own mappings
  dap = { console = 'internalConsole' }, -- e.g. also stopOnEntry = true
})
```

Root detection prefers the closest `robot.toml`, `.robot.toml` or `pyproject.toml`,
then the LSP root, Git root, or file directory. Override `root_dir` for unusual
layouts. `paths` overrides the input sources when explicitly provided; otherwise
RobotCode's configured paths are preserved. Put only options in `args`; put
source files/directories in `paths`.

Discovery, running and debugging share profiles, CLI options, Robot arguments,
paths and environment. Exact full-name selection avoids treating `*`, `?` and
brackets in test names as patterns. Running through the configured suite paths
also preserves parent `__init__.robot` setup. Duplicate full names or multiple
generated tests on the same line are rejected because they cannot identify a
single test reliably.

The current file is saved before selection by default. Other modified Robot
buffers in the same project must be saved before execution. Changes during discovery cancel the
action; run it again after editing. Markers reflect LSP symbols and disappear
while editing until refreshed. Discovery runs asynchronously and uses saved files.

Output/log/report paths follow your RobotCode configuration. Use `args` or
`robot.toml` to set a separate output directory if desired. The plugin adds no
suite/test arguments to your existing LSP and registers its own DAP adapter as
`nvim_robotcode`.

## Verification

Tested on Windows with Neovim 0.10.1, RobotCode 2.7.0, Robot Framework 7.5 and
`nvim-dap` 0.8.0. Real integration checks start the LSP, discover tests, run a
selected test in a Neovim terminal, stop at a breakpoint, step to the next keyword, and continue to a
passing DAP test result. They verify title/body boundaries, keyword rejection,
test markers, exact selection, a same-named test in another file, parent suite
setup, profiles and environment variables. Older `nvim-dap` on Windows may print
an adapter exit-code warning after a successful session when it stops the
launcher; the test's DAP exit status and Robot output still report the result.

To reproduce in a disposable local environment:

```sh
uv venv .venv
uv pip install --python .venv/Scripts/python.exe 'robotcode[runner,debugger,languageserver]==2.7.0' 'robotframework==7.5'
git clone --branch 0.8.0 --depth 1 https://github.com/mfussenegger/nvim-dap.git .deps/nvim-dap
nvim --headless -u NONE -i NONE -l tests/unit.lua
nvim --headless -u NONE -i NONE -l tests/integration.lua
```

Then enable the DAP integration check in PowerShell:

```powershell
$env:ROBOTCODE_TEST_DAP = '1'
nvim --headless -u NONE -i NONE -l tests/integration.lua
```

On Unix, use `.venv/bin/python` for installation and
`ROBOTCODE_TEST_DAP=1 nvim --headless -u NONE -i NONE -l tests/integration.lua`.
The test runner itself handles both Python paths. Linux/macOS have not been
verified in this workspace. Test output is written under `tests/.output/`.

Protocol references: [RobotCode](https://github.com/robotcodedev/robotcode),
[test symbols](https://github.com/robotcodedev/robotcode/blob/main/packages/language_server/src/robotcode/language_server/robotframework/parts/document_symbols.py),
[debug launcher](https://github.com/robotcodedev/robotcode/blob/main/packages/debugger/src/robotcode/debugger/launcher/server.py).
