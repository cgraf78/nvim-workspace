-- Shared workspace/path helpers for Neovim integrations.
--
-- This module owns root detection and path normalization across custom nvim
-- features. Tool-specific modules should build on this instead of rediscovering
-- repos or reimplementing HOME symlink handling.

local M = {}

local function strip_trailing_slash(path)
  if path == "/" then
    return path
  end
  return (path:gsub("/+$", ""))
end

local home = strip_trailing_slash(vim.fn.fnamemodify(vim.env.HOME or "~", ":p"))
local home_aliases

-- Expand user/env syntax and produce an absolute path without resolving
-- symlinks. Use canonical() when realpath comparison is needed instead.
function M.absolute_path(path)
  return strip_trailing_slash(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function path_contains(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function current_file_name()
  if vim.bo.filetype == "neo-tree" or vim.bo.buftype ~= "" then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%w[%w+.-]*://") then
    return nil
  end
  return name
end

-- Cache top-level HOME symlinks so integrations can prefer the path the user
-- opened, such as ~/repo, over less readable canonical mount paths.
local function load_home_aliases()
  if home_aliases then
    return home_aliases
  end

  home_aliases = {}
  local scan = vim.uv.fs_scandir(home)
  if not scan then
    return home_aliases
  end

  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then
      break
    end
    local visible = home .. "/" .. name
    local real = vim.uv.fs_realpath(visible)
    if real then
      real = strip_trailing_slash(real)
      -- Prefer user-facing symlinks such as ~/repo over canonical mount paths,
      -- but only when the HOME entry actually resolves somewhere else.
      if real ~= visible then
        home_aliases[#home_aliases + 1] = { visible = visible, canonical = real }
      end
    end
  end

  table.sort(home_aliases, function(a, b)
    return #a.canonical > #b.canonical
  end)
  return home_aliases
end

-- Map canonical paths back through visible HOME aliases when possible. This
-- keeps picker and Neo-tree paths on the same user-facing root. Terminal click
-- handling intentionally lives outside workspace root policy.
local function home_visible_path(path)
  local normalized = M.absolute_path(path)
  if path_contains(home, normalized) then
    return normalized
  end

  local canonical = strip_trailing_slash(vim.uv.fs_realpath(normalized) or normalized)
  for _, alias in ipairs(load_home_aliases()) do
    if path_contains(alias.canonical, canonical) then
      return alias.visible .. canonical:sub(#alias.canonical + 1)
    end
  end
  return normalized
end

-- The broadest intentional workspace root. Picker commands use this for
-- explicit "search everything under HOME" actions.
function M.default_root()
  return home
end

-- Convert a path-like input to the directory integrations should operate on.
-- Existing files become their parent directories; directories stay directories.
function M.normalize(path)
  if not path or path == "" then
    return home
  end

  local expanded = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(expanded)
  if stat and stat.type ~= "directory" then
    expanded = vim.fs.dirname(expanded)
  end

  return M.absolute_path(expanded)
end

-- Resolve a normalized directory to its real filesystem location when possible.
-- This is for equality/prefix comparisons, not display.
function M.canonical(path)
  local normalized = M.normalize(path)
  -- Compare real paths when possible so symlinked roots match repo roots
  -- returned by sley, while preserving normalized paths for missing dirs.
  return strip_trailing_slash(vim.uv.fs_realpath(normalized) or normalized)
end

-- Return the active file's directory while preserving visible HOME aliases.
-- Missing files are handled as new buffers rooted at their existing parent.
local function file_dir(name)
  local visible = home_visible_path(name)
  local stat = vim.uv.fs_stat(vim.fn.expand(visible))
  if stat and stat.type == "directory" then
    return M.normalize(visible)
  end
  if stat then
    return M.normalize(vim.fs.dirname(visible))
  end

  -- New, not-yet-written buffers have no filesystem metadata. Resolve the
  -- parent separately so symlinked HOME aliases still win when the directory
  -- exists but the file does not.
  return M.normalize(home_visible_path(vim.fs.dirname(name)))
end

-- Directory of the current real file buffer. Special buffers deliberately
-- return nil so commands do not accidentally operate from nvim's cwd.
function M.current_file_dir()
  local name = current_file_name()
  if name then
    return file_dir(name)
  end
  -- Callers that run external tools should use this instead of
  -- current_buffer_dir() when falling back to process cwd would be surprising.
  return nil
end

-- Best-effort current workspace directory. Falls back to nvim's cwd for UI
-- contexts such as pickers where a non-file buffer still needs a default.
function M.current_buffer_dir()
  local dir = M.current_file_dir()
  if dir then
    return dir
  end
  return M.normalize(home_visible_path(vim.uv.cwd() or home))
end

-- True when path is under root, accepting either visible or canonical forms.
function M.contains(root, path)
  local normalized_root = M.normalize(root)
  local normalized_path = M.normalize(path)
  if path_contains(normalized_root, normalized_path) then
    return true
  end

  local canonical_root = M.canonical(root)
  local canonical_path = M.canonical(path)
  return path_contains(canonical_root, canonical_path)
end

-- Return path rewritten under root's visible spelling, or nil if it is outside
-- root. Use this before showing filesystem results from canonical backends.
function M.visible_path(root, path)
  local normalized_root = M.normalize(root)
  local normalized_path = home_visible_path(path)
  if path_contains(normalized_root, normalized_path) then
    return normalized_path
  end

  local canonical_root = M.canonical(root)
  local canonical_path =
    strip_trailing_slash(vim.uv.fs_realpath(M.absolute_path(path)) or M.absolute_path(path))
  if path_contains(canonical_root, canonical_path) then
    return normalized_root .. canonical_path:sub(#canonical_root + 1)
  end
  return nil
end

-- Return a canonical path relative to root, or nil when the path is outside
-- root. Callers use this for repo-relative labels and filtering.
function M.relative_path(root, path)
  local canonical_root = M.canonical(root)
  local normalized_path = M.absolute_path(path)
  local canonical_path =
    strip_trailing_slash(vim.uv.fs_realpath(normalized_path) or normalized_path)
  if canonical_path == canonical_root then
    return ""
  end
  if canonical_path:sub(1, #canonical_root + 1) ~= canonical_root .. "/" then
    return nil
  end
  return canonical_path:sub(#canonical_root + 2)
end

-- Return a root-relative path while preserving the visible path spelling.
-- Git worktrees need this for tracked symlinks: the index stores the link path
-- under the work tree, not the realpath of the link target.
function M.visible_relative_path(root, path)
  local normalized_root = M.normalize(root)
  local visible = M.visible_path(normalized_root, path)
  if not visible then
    return nil
  end
  if visible == normalized_root then
    return ""
  end
  if visible:sub(1, #normalized_root + 1) ~= normalized_root .. "/" then
    return nil
  end
  return visible:sub(#normalized_root + 2)
end

-- Compact a root for prompts, titles, and notifications.
function M.display(root)
  local normalized = M.normalize(root)
  if normalized == home then
    return "~"
  end
  if normalized:sub(1, #home + 1) == home .. "/" then
    return "~" .. normalized:sub(#home + 1)
  end
  return normalized
end

-- Shared directory prompt for UI surfaces that let the user re-scope a tool.
-- Keep the normalize/schedule behavior here so pickers, Neo-tree, and future
-- root-aware widgets do not each rediscover the same input teardown details.
function M.prompt_for_dir(default_root, callback, opts)
  opts = opts or {}
  vim.ui.input({
    prompt = opts.prompt or "Directory: ",
    default = M.display(default_root or M.current_buffer_dir()),
    completion = "dir",
  }, function(input)
    if not input or input == "" then
      return
    end
    vim.schedule(function()
      callback(M.normalize(input))
    end)
  end)
end

-- Delegate large-repo decisions to host/work overlays while centralizing the
-- defensive wrapper. Most callers should use canonical paths so symlinks share
-- policy; pass { canonical = false } only when the caller has an explicit root
-- whose spelling must be preserved, such as an already-open Neo-tree root.
function M.is_large_repo(root, opts)
  if type(root) ~= "string" or root == "" then
    return false
  end

  local config = require("nvim_workspace.config").get()
  local detector = config.large_root_detector or rawget(_G, "in_large_repo")
  if type(detector) ~= "function" then
    return false
  end

  local detector_opts = opts or {}
  local detector_root = detector_opts.canonical == false and root or M.canonical(root)
  local forwarded_opts = vim.deepcopy(detector_opts)
  forwarded_opts.canonical = nil
  if next(forwarded_opts) == nil then
    forwarded_opts = nil
  end

  -- Work overlays own the actual classifier. Keep the call boundary here so
  -- integrations share nil/error handling without learning this private option.
  local ok, result = pcall(detector, detector_root, forwarded_opts)
  return ok and result == true
end

-- Run a root-detection command that emits sley-compatible JSON. Fail closed so
-- editor features can fall back to smaller local roots instead of guessing.
local function status_root(cmd, cwd, opts)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end

  local system_opts = { cwd = cwd, text = true }
  if opts and opts.env then
    system_opts.env = opts.env
  end

  local ok_system, result = pcall(function()
    return vim.system(cmd, system_opts):wait()
  end)
  if not ok_system then
    return nil
  end
  if result.code ~= 0 or result.stdout == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.root) ~= "string" then
    return nil
  end
  return home_visible_path(decoded.root)
end

-- Detect the base bare dotfiles repo. This is intentionally separate from
-- find_vcs_root() so callers can opt out of treating all of HOME as a repo.
local function dotfiles_repo_root(cwd)
  if not M.contains(home, cwd) then
    return nil
  end

  local dotfiles_dir = home .. "/.dotfiles"
  local stat = vim.uv.fs_stat(dotfiles_dir)
  if not stat or stat.type ~= "directory" then
    return nil
  end

  -- Dotfiles opts into Sley's generic bare-repo fallback here instead of making
  -- the Sley launcher know about the local ~/.dotfiles convention.
  return status_root({ "sley", "status", "--json" }, cwd, {
    env = {
      -- The PATH-visible git launcher treats HOME as the bare dotfiles repo,
      -- which makes generic status probes walk HOME-scale untracked files before
      -- Sley's bare-repo fast path can disable them. Root detection needs real
      -- Git semantics here; the explicit SLEY_BARE_REPO_* env below still tells
      -- Sley when to opt into the dotfiles worktree.
      DOT_GIT_REAL = "1",
      SLEY_BARE_REPO_GIT_DIR = dotfiles_dir,
      SLEY_BARE_REPO_WORK_TREE = home,
    },
  })
end

-- Detect a normal VCS workspace through the PATH-visible sley entry point. This
-- excludes Sley's optional bare-repo fallback and is the right API for language
-- servers with expensive scans.
function M.find_vcs_root(start)
  local cwd = M.normalize(start or M.current_buffer_dir())
  -- sley owns VCS repo detection; nvim only consumes the stable JSON contract.
  -- Ask sley to skip any inherited bare-repo fallback so this remains a normal
  -- repo probe while still using the same PATH-visible front door as terminals.
  return status_root({ "sley", "status", "--json" }, cwd, {
    env = {
      -- See dotfiles_repo_root(): workspace probes need real Git semantics,
      -- not the dotfiles-aware git launcher that rewrites HOME to ~/.dotfiles.
      DOT_GIT_REAL = "1",
      SLEY_SKIP_BARE_REPO_FALLBACK = "1",
    },
  })
end

-- Detect the full user workspace root, including the bare dotfiles repo when
-- no normal VCS root owns the path.
function M.find_repo_root(start)
  local cwd = M.normalize(start or M.current_buffer_dir())
  return M.find_vcs_root(cwd) or dotfiles_repo_root(cwd)
end

-- Return a usable workspace root. If repo detection fails, use the normalized
-- starting directory so commands stay scoped to the current local context.
function M.repo_root(start)
  local cwd = M.normalize(start or M.current_buffer_dir())
  return M.find_repo_root(cwd) or cwd
end

return M
