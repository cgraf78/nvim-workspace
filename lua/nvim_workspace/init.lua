local M = {}

function M.setup(opts)
  require("nvim_workspace.config").setup(opts)
end

function M.workspace()
  return require("nvim_workspace.core.workspace")
end

function M.files(opts)
  return require("nvim_workspace.picker.files").find(opts)
end

function M.grep(opts)
  return require("nvim_workspace.picker.grep").find(opts)
end

function M.register_file_source(source, opts)
  return require("nvim_workspace.picker.files").add_source(source, opts)
end

function M.register_grep_source(source, opts)
  return require("nvim_workspace.picker.grep").add_source(source, opts)
end

function M.default_root()
  return M.workspace().default_root()
end

function M.current_buffer_dir()
  return M.workspace().current_buffer_dir()
end

function M.current_file_dir()
  return M.workspace().current_file_dir()
end

function M.repo_root(start)
  return M.workspace().repo_root(start)
end

return M
