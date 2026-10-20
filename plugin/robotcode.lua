if vim.g.loaded_nvim_robotcode then return end
vim.g.loaded_nvim_robotcode = true

for command, action in pairs({
  RobotCodeRunTest = 'run_test',
  RobotCodeDebugTest = 'debug_test',
  RobotCodeTest = 'test',
  RobotCodeRefresh = 'refresh',
  RobotCodeResult = 'show_result',
  RobotCodeExplorer = 'explorer',
}) do
  vim.api.nvim_create_user_command(command, function() require('robotcode')[action]() end, {})
end
