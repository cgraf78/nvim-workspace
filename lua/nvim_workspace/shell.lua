local M = {}
local uv = require("nvim_workspace.core.uv")

local default_shell_glob = "*@(.sh|.inc|.bash|.zsh|.command)"

local defaults = {
  shell_glob = default_shell_glob,
  recursive_glob = "**/" .. default_shell_glob,
  file_globs = { "*.sh", "*.inc", "*.bash", "*.zsh", "*.command" },
  home_files = {
    ".bashrc",
    ".bash_profile",
    ".profile",
    ".zshenv",
    ".zprofile",
    ".zshrc",
  },
  home_globs = {},
  home_dirs = {},
  overlay = {
    enabled = false,
    root_prefix = nil,
    home_dir = "home",
  },
}

-- Root callbacks can run for every shell buffer and fallback navigation lookup.
-- Cache the derived policy until setup() replaces the raw config table.
local shell_config_source = nil
local shell_config_cache = nil

local function workspace()
  return require("nvim_workspace.core.workspace")
end

local function normalize(path)
  return workspace().absolute_path(path)
end

local function canonical_path(path)
  local normalized = normalize(path)
  return uv.fs_realpath(normalized) or normalized
end

local function home()
  return workspace().default_root()
end

local function copy_list(value)
  return vim.deepcopy(type(value) == "table" and value or {})
end

local function shell_config()
  local raw = require("nvim_workspace.config").get().shell or {}
  if shell_config_cache and raw == shell_config_source then
    return shell_config_cache
  end

  local shell_glob = raw.shell_glob or defaults.shell_glob
  local overlay = vim.tbl_deep_extend("force", vim.deepcopy(defaults.overlay), raw.overlay or {})
  local config = {
    shell_glob = shell_glob,
    recursive_glob = raw.recursive_glob or ("**/" .. shell_glob),
    file_globs = copy_list(raw.file_globs or defaults.file_globs),
    home_files = copy_list(raw.home_files or defaults.home_files),
    home_globs = copy_list(raw.home_globs or defaults.home_globs),
    home_dirs = copy_list(raw.home_dirs or defaults.home_dirs),
    overlay = overlay,
    home_file_lookup = {},
  }
  for _, path in ipairs(config.home_files) do
    config.home_file_lookup[path] = true
  end

  shell_config_source = raw
  shell_config_cache = config
  return config
end

local function home_roots()
  local roots = { home() }
  local real = canonical_path(home())
  if real ~= roots[1] then
    roots[#roots + 1] = real
  end
  return roots
end

local function relative_to_home(path)
  return workspace().visible_relative_path(home(), path)
end

local function path_matches_prefix(relative, item)
  if type(item) ~= "table" or type(item.prefix) ~= "string" or item.prefix == "" then
    return false
  end

  local prefix = item.prefix
  if relative:sub(1, #prefix) ~= prefix then
    return false
  end

  if item.direct then
    local rest = relative:sub(#prefix + 1)
    return rest ~= "" and not rest:find("/", 1, true)
  end
  return true
end

local function path_matches_glob(relative, pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return false
  end

  local ok, regex = pcall(vim.fn.glob2regpat, pattern)
  return ok and vim.fn.match(relative, regex) == 0
end

local function glob_patterns(config)
  local patterns = {}
  for _, path in ipairs(config.home_files) do
    patterns[#patterns + 1] = path
  end
  for _, pattern in ipairs(config.home_globs) do
    patterns[#patterns + 1] = pattern
  end
  for _, item in ipairs(config.home_dirs) do
    if type(item) == "table" and type(item.glob) == "string" and item.glob ~= "" then
      patterns[#patterns + 1] = item.glob
    end
  end
  return patterns
end

local function braced(patterns)
  if #patterns == 0 then
    return nil
  end
  if #patterns == 1 then
    return patterns[1]
  end
  return "{" .. table.concat(patterns, ",") .. "}"
end

local function prefixed(patterns, prefix)
  local result = {}
  for _, pattern in ipairs(patterns) do
    result[#result + 1] = prefix .. pattern
  end
  return result
end

local function is_home_relative(relative, config)
  if not relative then
    return false
  end
  if config.home_file_lookup[relative] then
    return true
  end
  for _, pattern in ipairs(config.home_globs) do
    if path_matches_glob(relative, pattern) then
      return true
    end
  end
  for _, item in ipairs(config.home_dirs) do
    if path_matches_prefix(relative, item) then
      return true
    end
  end
  return false
end

local function overlay_context(path, config)
  if
    not config.overlay.enabled
    or type(config.overlay.root_prefix) ~= "string"
    or config.overlay.root_prefix == ""
  then
    return nil, nil
  end

  for _, candidate in ipairs({ normalize(path), canonical_path(path) }) do
    for _, root_prefix in ipairs(home_roots()) do
      local prefix = root_prefix .. "/" .. config.overlay.root_prefix
      if candidate:sub(1, #prefix) == prefix then
        local marker = candidate:find("/" .. config.overlay.home_dir .. "/", #prefix + 1, true)
        if marker then
          local root = candidate:sub(1, marker - 1)
          if vim.fn.isdirectory(root .. "/" .. config.overlay.home_dir) == 1 then
            return canonical_path(root), candidate:sub(marker + #config.overlay.home_dir + 2)
          end
        end
      end
    end
  end

  return nil, nil
end

local function is_overlay_root(root, config)
  if
    not config.overlay.enabled
    or type(config.overlay.root_prefix) ~= "string"
    or config.overlay.root_prefix == ""
  then
    return false
  end

  for _, candidate in ipairs({ normalize(root), canonical_path(root) }) do
    for _, root_prefix in ipairs(home_roots()) do
      local prefix = root_prefix .. "/" .. config.overlay.root_prefix
      if
        candidate:sub(1, #prefix) == prefix
        and vim.fn.isdirectory(candidate .. "/" .. config.overlay.home_dir) == 1
      then
        return true
      end
    end
  end
  return false
end

function M.is_home_shell_path(path)
  local config = shell_config()
  if is_home_relative(relative_to_home(path), config) then
    return true
  end

  local _, overlay_relative = overlay_context(path, config)
  return is_home_relative(overlay_relative, config)
end

local function home_shell_root(path, config)
  local overlay_root, overlay_relative = overlay_context(path, config)
  if overlay_root and is_home_relative(overlay_relative, config) then
    return overlay_root
  end

  if not is_home_relative(relative_to_home(path), config) then
    return nil
  end

  -- Bounded HOME paths should either share the explicit HOME workspace or stay
  -- local. Ask about HOME itself so subdirectory VCS probes do not decide this.
  local root = workspace().find_home_repo_root()
  if root == home() then
    return root
  end
  return nil
end

function M.root_for(path)
  local config = shell_config()
  local normalized = normalize(path)
  local stat = uv.fs_stat(normalized)
  local start = stat and stat.type == "directory" and normalized or vim.fs.dirname(normalized)

  local vcs_root = workspace().find_vcs_root(start)
  if vcs_root then
    if is_overlay_root(vcs_root, config) then
      return canonical_path(vcs_root)
    end
    return normalize(vcs_root)
  end

  return home_shell_root(normalized, config) or start
end

function M.root_dir(bufnr, on_dir)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%w[%w+.-]*://") then
    return
  end
  on_dir(M.root_for(name))
end

function M.glob_for(root)
  local config = shell_config()
  local patterns = glob_patterns(config)
  if root and normalize(root) == home() then
    return braced(patterns) or config.recursive_glob
  end
  if root and is_overlay_root(root, config) then
    return braced(prefixed(patterns, config.overlay.home_dir .. "/")) or config.recursive_glob
  end
  return config.recursive_glob
end

local function shell_file_globs()
  return shell_config().file_globs
end

local function append_glob(paths, pattern)
  local ok, matches = pcall(vim.fn.glob, pattern, false, true)
  if not ok or type(matches) ~= "table" then
    return
  end

  table.sort(matches)
  for _, path in ipairs(matches) do
    if vim.fn.filereadable(path) == 1 then
      paths[#paths + 1] = path
    end
  end
end

local function home_search_paths(root, path_prefix)
  local config = shell_config()
  root = normalize(root or home())
  path_prefix = path_prefix or ""
  local paths = {}

  for _, path in ipairs(config.home_files) do
    local full = root .. "/" .. path_prefix .. path
    if vim.fn.filereadable(full) == 1 then
      paths[#paths + 1] = full
    end
  end

  for _, pattern in ipairs(config.home_globs) do
    append_glob(paths, root .. "/" .. path_prefix .. pattern)
  end

  for _, item in ipairs(config.home_dirs) do
    if type(item) == "table" and type(item.glob) == "string" and item.glob ~= "" then
      local prefix = type(item.prefix) == "string" and item.prefix or item.glob:gsub("%*.*$", "")
      local full = root .. "/" .. path_prefix .. prefix:gsub("/$", "")
      if vim.fn.isdirectory(full) == 1 then
        paths[#paths + 1] = full
      end
    end
  end

  return paths
end

function M.search_paths_for(path)
  local config = shell_config()
  local root = M.root_for(path)
  if normalize(root) == home() then
    return home_search_paths(root), nil, root
  end
  if is_overlay_root(root, config) then
    return home_search_paths(root, config.overlay.home_dir .. "/"), nil, root
  end

  return { root }, shell_file_globs(), root
end

function M.before_init(_, config)
  config.settings = config.settings or {}
  config.settings.bashIde = config.settings.bashIde or {}

  -- Keep bashls and local fallback navigation on the same bounded workspace:
  -- all indexed shell symbols are useful, but HOME-scale recursive scans are not.
  config.settings.bashIde.includeAllWorkspaceSymbols = true
  config.settings.bashIde.globPattern = M.glob_for(config.root_dir)
end

return M
