local M = {}
local uv = require("nvim_workspace.core.uv")
local reveal_scheduled = false
local last_file

local function workspace()
  return require("nvim_workspace.core.workspace")
end

local function current_file()
  if vim.bo.filetype == "neo-tree" or vim.bo.buftype ~= "" then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(0)
  if path == "" or path:match("^%w[%w+.-]*://") then
    return nil
  end

  local stat = uv.fs_stat(path)
  if not stat or stat.type == "directory" then
    return nil
  end

  return path
end

local function current_filesystem_root()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return nil
  end

  local state_ok, state = pcall(manager.get_state, "filesystem")
  if state_ok and type(state) == "table" and type(state.path) == "string" and state.path ~= "" then
    return state.path
  end

  return nil
end

local function in_large_root(root)
  -- Plugin setup has no selected tree root yet. Avoid falling back to cwd or
  -- current-buffer state here; explicit roots should be the only large-repo
  -- signal Neo-tree uses.
  return workspace().is_large_repo(root, { canonical = false })
end

local function is_home_browser_root(root)
  if type(root) ~= "string" or root == "" then
    return false
  end

  local ws = workspace()
  local default_root = ws.default_root()
  if not ws.contains(default_root, root) then
    return false
  end

  -- Normal repos under HOME should keep project-style Git status. Only broad
  -- HOME/browser roots get quiet explorer behavior.
  return ws.find_vcs_root(root) == nil
end

function M.filesystem_policy(root)
  local large = in_large_root(root)
  local home_browser_root = is_home_browser_root(root)
  local hide_ignored = home_browser_root or not large
  local ws = workspace()
  local is_default_root = type(root) == "string"
    and root ~= ""
    and ws.normalize(root) == ws.default_root()
  local ignore_files = hide_ignored and { ".neotreeignore", ".ignore" } or {}
  if home_browser_root and is_default_root then
    -- ~/.ignore is usually tuned for fd/ripgrep and may hide entire repos by
    -- name. Neo-tree expands interactively, so broad HOME views use the
    -- tree-specific ignore file instead.
    ignore_files = { ".neotreeignore" }
  end

  return {
    enable_git_status = not large and not home_browser_root,
    filtered_items = {
      hide_dotfiles = true,
      hide_gitignored = hide_ignored,
      hide_ignored = hide_ignored,
      ignore_files = ignore_files,
    },
  }
end

function M.apply_filesystem_policy(policy)
  if type(policy) ~= "table" then
    return
  end

  local ok, neotree = pcall(require, "neo-tree")
  if ok and type(neotree.config) == "table" then
    -- Neo-tree still consults this global during navigation even when the
    -- filesystem state carries per-root filter overrides.
    neotree.config.enable_git_status = policy.enable_git_status
  end
end

local function apply_filesystem_state_policy(state, root)
  if type(state) ~= "table" or state.name ~= "filesystem" then
    return
  end
  if type(root) ~= "string" or root == "" then
    return
  end

  local policy = M.filesystem_policy(root)
  M.apply_filesystem_policy(policy)
  state.enable_git_status = policy.enable_git_status
  state.filtered_items =
    vim.tbl_deep_extend("force", state.filtered_items or {}, policy.filtered_items or {})
end

local function visible_file(root, path)
  if type(root) ~= "string" or root == "" or type(path) ~= "string" or path == "" then
    return nil
  end

  local ok, visible = pcall(function()
    return workspace().visible_path(root, path)
  end)
  return ok and visible or nil
end

function M.root_dir()
  if vim.bo.filetype == "neo-tree" then
    local root = current_filesystem_root()
    if root then
      return root
    end
  end

  return workspace().default_root()
end

function M.context_root()
  local ws = workspace()
  return ws.canonical(ws.repo_root(ws.current_buffer_dir()))
end

function M.reveal_file(root, path)
  path = path or M.remember_current_file() or last_file
  if type(path) ~= "string" or path == "" then
    return nil
  end

  root = root or current_filesystem_root()
  local visible = visible_file(root, path)
  if visible then
    return visible
  end

  return path
end

function M.open(root, opts)
  opts = opts or {}
  root = workspace().normalize(root or M.root_dir())
  local policy = M.filesystem_policy(root)
  M.apply_filesystem_policy(policy)

  require("neo-tree.command").execute({
    action = opts.action,
    toggle = opts.toggle,
    reveal_file = opts.reveal == false and nil or M.reveal_file(root),
    dir = root,
  }, policy)
end

function M.prompt_for_root(default_root)
  workspace().prompt_for_dir(default_root or M.context_root(), function(root)
    M.open(root, { action = "focus" })
  end, { prompt = "Explorer root: " })
end

function M.filesystem_mappings()
  return {
    -- Match the picker scope controls: broad HOME, workspace root, or an
    -- explicitly prompted directory.
    ["<C-r>"] = function()
      M.open(workspace().default_root(), { action = "focus" })
    end,
    ["<C-w>"] = function()
      M.open(M.context_root(), { action = "focus" })
    end,
    ["<C-d>"] = function()
      M.prompt_for_root(M.context_root())
    end,
  }
end

function M.remember_current_file()
  local path = current_file()
  if path then
    last_file = path
  end
  return path
end

function M.reveal_open_tree()
  reveal_scheduled = false

  local path = M.remember_current_file()
  if not path then
    return
  end

  local ok_manager, manager = pcall(require, "neo-tree.sources.manager")
  local ok_renderer, renderer = pcall(require, "neo-tree.ui.renderer")
  local ok_command, command = pcall(require, "neo-tree.command")
  if not ok_manager or not ok_renderer or not ok_command then
    return
  end

  local ok_state, state = pcall(manager.get_state, "filesystem")
  if not ok_state or type(state) ~= "table" or type(state.path) ~= "string" or state.path == "" then
    return
  end
  if not renderer.window_exists(state) then
    return
  end

  local visible = visible_file(state.path, path)
  if not visible then
    return
  end

  local node = state.tree and state.tree:get_node()
  if node and node:get_id() == visible then
    return
  end

  command.execute({ action = "show", reveal_file = visible, dir = state.path })
end

function M.schedule_reveal_open_tree()
  if reveal_scheduled then
    return
  end

  reveal_scheduled = true
  vim.defer_fn(M.reveal_open_tree, 150)
end

function M.setup_follow_autocmd()
  if vim.g.nvim_workspace_neotree_follow_autocmd then
    return
  end
  vim.g.nvim_workspace_neotree_follow_autocmd = true

  local group = vim.api.nvim_create_augroup("nvim_workspace_neotree_follow", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      M.remember_current_file()
      M.schedule_reveal_open_tree()
    end,
  })
end

function M.setup_manager_patch()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    M.setup_follow_autocmd()
    return
  end

  if not manager._nvim_workspace_symlink_reveal_patched then
    local original = manager.get_path_to_reveal
    if type(original) == "function" then
      -- Neo-tree compares paths as strings when following buffers, so map the
      -- current buffer into the tree's visible root before those prefix checks.
      manager.get_path_to_reveal = function(include_terminals)
        local path = original(include_terminals)
        if not path then
          return nil
        end
        return M.reveal_file(current_filesystem_root(), path)
      end
      manager._nvim_workspace_symlink_reveal_patched = true
    end
  end

  if type(manager.navigate) == "function" and not manager._nvim_workspace_policy_patched then
    local original_navigate = manager.navigate
    -- Commands, keymaps, and refreshes all flow through manager.navigate().
    -- Patch that boundary so the large-root policy cannot be bypassed by an
    -- alternate Neo-tree entry point.
    manager.navigate = function(state_or_source_name, path, path_to_reveal, callback, async)
      local state = type(state_or_source_name) == "table" and state_or_source_name or nil
      if state == nil and state_or_source_name == "filesystem" then
        local ok_state, current_state = pcall(manager.get_state, "filesystem")
        if ok_state then
          state = current_state
        end
      end

      apply_filesystem_state_policy(state, path or (state and state.path))
      return original_navigate(state_or_source_name, path, path_to_reveal, callback, async)
    end
    manager._nvim_workspace_policy_patched = true
  end

  M.setup_follow_autocmd()
end

return M
