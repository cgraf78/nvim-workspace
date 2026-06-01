local M = {}

-- Public facade. Prefer this module in host configs so internal module names
-- can evolve without leaking plugin structure into user-facing integrations.
function M.setup(opts)
  require("nvim_workspace.config").setup(opts)
end

-- Open the workspace file picker. opts.root narrows the search root; without it
-- the picker uses the broad default root and lets users re-scope interactively.
function M.files(opts)
  return require("nvim_workspace.picker.files").find(opts)
end

-- Open the workspace content picker with the same root contract as files().
function M.grep(opts)
  return require("nvim_workspace.picker.grep").find(opts)
end

-- Register extension backends through the facade so source metadata and
-- cancellation semantics stay owned by the picker implementation.
function M.register_file_source(source, opts)
  return require("nvim_workspace.picker.files").add_source(source, opts)
end

function M.register_grep_source(source, opts)
  return require("nvim_workspace.picker.grep").add_source(source, opts)
end

-- Narrow path helpers that host configs commonly need. Keep these as explicit
-- forwards instead of exposing the whole workspace module as public API.
function M.default_root()
  return require("nvim_workspace.core.workspace").default_root()
end

function M.current_buffer_dir()
  return require("nvim_workspace.core.workspace").current_buffer_dir()
end

function M.current_file_dir()
  return require("nvim_workspace.core.workspace").current_file_dir()
end

function M.repo_root(start)
  return require("nvim_workspace.core.workspace").repo_root(start)
end

return M
