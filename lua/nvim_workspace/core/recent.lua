-- MRU file list: session-visited files first (current session), then oldfiles
-- (cross-session via shada). Oldfiles are capped during merge, while the
-- session list has a separate larger bound so active work is not dropped just
-- because shada has many stale entries.
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
local max_session_files = 200
local group = vim.api.nvim_create_augroup("nvim_workspace_recent", { clear = true })

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
  end,
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

  cache, cache_set = M.merge(session_files, vim.v.oldfiles, function(f)
    return uv.fs_stat(f) ~= nil
  end)
  dirty = false
  return cache, cache_set
end

return M
