local M = {}

local function workspace()
  return require("nvim_workspace.core.workspace")
end

local function config()
  return require("nvim_workspace.config").get().lazygit or {}
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

local function callback_context()
  local ws = workspace()
  local default_root = ws.default_root()
  return {
    default_root = default_root,
    relative_to_default_root = function(path)
      local rel = ws.visible_relative_path(default_root, path)
      if rel == "" then
        return nil
      end
      return rel
    end,
  }
end

function M.opts_for_path(path)
  if not path then
    return nil
  end

  local opts_for_path = config().opts_for_path
  if type(opts_for_path) ~= "function" then
    return nil
  end

  -- Special repo handling is host policy. Keep failures local so LazyGit can
  -- still open in the normal repo/current-directory context.
  local ok, opts = pcall(opts_for_path, path, callback_context())
  if ok and type(opts) == "table" then
    return opts
  end
  return nil
end

function M.cwd_for_context()
  local ws = workspace()
  local dir = ws.current_file_dir() or ws.current_buffer_dir()
  -- Host-specific special repos are handled by opts_for_path(). The generic
  -- fallback should stay on a normal VCS root or the local editing context.
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
