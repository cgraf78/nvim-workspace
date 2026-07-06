local M = {}

local defaults = {
  -- Host configs know which roots are too expensive to scan locally. The plugin
  -- keeps that decision injectable so it can stay generic while still avoiding
  -- accidental HOME- or monorepo-scale fd/rg walks.
  large_root_detector = nil,
  workspace = {
    -- Optional host callback for repo detection. Return a root string or nil.
    -- The generic fallback only checks VCS marker directories.
    repo_root_detector = nil,
    -- Marker roots are cheap and deterministic, so prefer them by default.
    -- Hosts that need to override nested marker roots can set this false.
    prefer_marker_roots = true,
    -- Optional marker roots to ignore before detector dispatch, useful for
    -- broad placeholder repos such as HOME.
    ignored_marker_roots = {},
    -- Optional host callback for HOME-shaped workspaces such as bare repos.
    -- Return a root string when the path belongs to that workspace.
    home_workspace_detector = nil,
  },
  lazygit = {
    -- Optional host callback for special repositories that need launcher args
    -- beyond a cwd, such as a bare repo with a separate work tree.
    opts_for_path = nil,
  },
  shell = {},
  navigation = {},
}

local values = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
end

function M.get()
  return values
end

return M
