local M = {}

local function workspace()
  return require("nvim_workspace.core.workspace")
end

local function current_file()
  if vim.bo.buftype ~= "" then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%w[%w+.-]*://") then
    return nil
  end
  return name
end

local function dotfiles_git_dir()
  return workspace().default_root() .. "/.dotfiles"
end

local function relative_to_home(path)
  local rel = workspace().visible_relative_path(workspace().default_root(), path)
  if not rel or rel == "" then
    return nil
  end
  return rel
end

local function is_dot_tracked(path)
  local rel = relative_to_home(path)
  if not rel then
    return false
  end

  local git_dir = dotfiles_git_dir()
  local stat = vim.uv.fs_stat(git_dir)
  if not stat or stat.type ~= "directory" then
    return false
  end

  vim.fn.system({
    "git",
    "--git-dir",
    git_dir,
    "--work-tree",
    workspace().default_root(),
    "ls-files",
    "--error-unmatch",
    "--",
    rel,
  })
  return vim.v.shell_error == 0
end

function M.opts_for_path(path)
  if not path or not is_dot_tracked(path) then
    return nil
  end

  return {
    cwd = workspace().default_root(),
    args = {
      "--work-tree",
      workspace().default_root(),
      "--git-dir",
      dotfiles_git_dir(),
    },
  }
end

function M.cwd_for_context()
  local ws = workspace()
  local dir = ws.current_file_dir() or ws.current_buffer_dir()
  -- Only dot-tracked files should launch LazyGit against the broad bare HOME
  -- repo. Other buffers use a normal VCS root or the local editing context.
  return ws.find_vcs_root(dir) or dir
end

function M.opts()
  return M.opts_for_path(current_file()) or { cwd = M.cwd_for_context() }
end

local function snacks_lazygit(snacks)
  if type(snacks) == "table" and type(snacks.lazygit) == "function" then
    return snacks.lazygit
  end
  return nil
end

function M.open_with_snacks(snacks)
  local target = snacks or rawget(_G, "Snacks")
  if not target then
    local ok, loaded = pcall(require, "snacks")
    if ok then
      target = loaded
    end
  end

  local open = snacks_lazygit(target)
  if not open then
    vim.notify("nvim_workspace.lazygit requires Snacks.lazygit", vim.log.levels.ERROR)
    return nil
  end
  return open(M.opts())
end

return M
