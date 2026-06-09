-- MRU file list: session-visited files first, then plugin-persisted recent
-- files from previous sessions, then oldfiles (cross-session via shada).
-- ShaDa does not keep buffers deleted before exit in v:oldfiles, so the
-- plugin-owned list preserves the "I opened this file recently" signal across
-- normal buffer-closing workflows.
--
-- Internal module: picker modules consume this directly; host configs should
-- interact with recent files through the public pickers.

local M = {}
local uv = require("nvim_workspace.core.uv")

-- Session-visited files always outrank oldfiles (cross-session) so the picker
-- prioritizes what you're actively working on over yesterday's context.
local session_files = {}
local session_set = {}
local cache = nil
local cache_set = nil
local dirty = true
local persisted_files = nil
local persisted_set = nil
local persist_dirty = false
local max_session_files = 200
local group = vim.api.nvim_create_augroup("nvim_workspace_recent", { clear = true })

local function store_path()
  if
    type(vim.env.NVIM_WORKSPACE_RECENT_FILE) == "string"
    and vim.env.NVIM_WORKSPACE_RECENT_FILE ~= ""
  then
    return vim.env.NVIM_WORKSPACE_RECENT_FILE
  end
  -- Tests and one-off headless probes often use -i NONE to disable editor
  -- state. Respect that boundary so they do not read the user's real MRU file.
  if vim.o.shadafile == "NONE" then
    return nil
  end
  return vim.fn.stdpath("state") .. "/nvim-workspace/recent.json"
end

local function add_file(files, seen, name, require_existing)
  if type(name) ~= "string" or name == "" or seen[name] then
    return false
  end
  if require_existing and not uv.fs_stat(name) then
    return false
  end
  seen[name] = true
  files[#files + 1] = name
  return true
end

local function load_persisted()
  if persisted_files then
    return persisted_files, persisted_set
  end

  persisted_files = {}
  persisted_set = {}

  local path = store_path()
  if not path then
    return persisted_files, persisted_set
  end

  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read or type(lines) ~= "table" then
    return persisted_files, persisted_set
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  local files = ok and type(decoded) == "table" and decoded.files or nil
  if type(files) ~= "table" then
    return persisted_files, persisted_set
  end

  for _, name in ipairs(files) do
    if #persisted_files >= max_session_files then
      break
    end
    add_file(persisted_files, persisted_set, name, true)
  end

  return persisted_files, persisted_set
end

local function save_persisted()
  if not persist_dirty then
    return
  end

  local path = store_path()
  if not path then
    return
  end

  local previous = load_persisted()
  local files = {}
  local seen = {}
  for _, name in ipairs(session_files) do
    if #files >= max_session_files then
      break
    end
    add_file(files, seen, name, true)
  end
  for _, name in ipairs(previous) do
    if #files >= max_session_files then
      break
    end
    add_file(files, seen, name, true)
  end

  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end

  local ok_write, write_result =
    pcall(vim.fn.writefile, { vim.json.encode({ version = 1, files = files }) }, path)
  if not ok_write or write_result ~= 0 then
    return
  end

  persisted_files = files
  persisted_set = seen
  persist_dirty = false
end

local function session_priority_files()
  local previous = load_persisted()
  local files = {}
  local seen = {}

  for _, name in ipairs(session_files) do
    add_file(files, seen, name, false)
  end
  for _, name in ipairs(previous) do
    add_file(files, seen, name, true)
  end

  return files
end

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(args)
    -- Only real file buffers belong in the MRU list. Special buffers often have
    -- synthetic names that cannot be searched or previewed as files.
    if not vim.api.nvim_buf_is_valid(args.buf) or vim.bo[args.buf].buftype ~= "" then
      return
    end
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name == "" then
      return
    end
    if session_set[name] then
      for i, f in ipairs(session_files) do
        if f == name then
          table.remove(session_files, i)
          break
        end
      end
    end
    table.insert(session_files, 1, name)
    session_set[name] = true
    if #session_files > max_session_files then
      local dropped = table.remove(session_files)
      session_set[dropped] = nil
    end
    dirty = true
    persist_dirty = true
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = save_persisted,
})

function M.merge(session, oldfiles, exists_fn, cap)
  cap = cap or 100
  local results = {}
  local seen = {}
  local n = 0

  for _, f in ipairs(session) do
    if not seen[f] then
      seen[f] = true
      n = n + 1
      results[n] = f
    end
  end

  for _, f in ipairs(oldfiles) do
    if n >= cap then
      break
    end
    if not seen[f] and exists_fn(f) then
      seen[f] = true
      n = n + 1
      results[n] = f
    end
  end

  return results, seen
end

function M.get()
  -- vim.v.oldfiles can be large and filesystem probes are relatively expensive.
  -- Cache until a real file buffer enters, which is the only event that can
  -- change the session-priority portion of the list.
  if not dirty and cache then
    return cache, cache_set
  end

  cache, cache_set = M.merge(session_priority_files(), vim.v.oldfiles, function(f)
    return uv.fs_stat(f) ~= nil
  end)
  dirty = false
  return cache, cache_set
end

return M
