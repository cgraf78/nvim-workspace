local M = {}

local vcs_markers = { ".git", ".hg", ".jj", ".svn" }
local group_name = "nvim_workspace_session"
local started_with_stdin = false
local save_timer = nil
local setup_generation = 0

local function enabled()
  return not started_with_stdin and not vim.g.disable_session_restore
end

local function plugin()
  if not enabled() then
    return nil
  end

  local ok, persistence_plugin = pcall(require, "persistence")
  if not ok then
    return nil
  end
  return persistence_plugin
end

-- Sessions can keep buffers for files that have since been deleted. Prune those
-- before the rest of startup code sees them so pickers, bufferline, and filetype
-- refreshes do not resurrect dead paths from an old mksession file.
function M.delete_missing_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and not vim.uv.fs_stat(name) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

-- Session sourcing restores the file window, cursor, folds, and topline before
-- LazyVim has finished its lazy filetype setup. Re-run detection without
-- re-reading the file: `:edit` would fire BufReadPost again, and LazyVim's
-- last-location autocmd would prefer the ShaDa '"' mark over the session cursor.
function M.refresh_current_filetype()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return
  end

  local win = vim.api.nvim_get_current_win()
  local view = vim.fn.winsaveview()
  local ok = pcall(vim.cmd, "filetype detect")
  if not ok and vim.filetype and type(vim.filetype.match) == "function" then
    -- Minimal/headless configs may not have created the filetypedetect group.
    -- Match directly instead of re-reading the file or depending on startup
    -- autocmds.
    local ft = vim.filetype.match({ buf = 0, filename = name })
    if type(ft) == "string" and ft ~= "" then
      vim.bo.filetype = ft
    end
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end
end

local function path_contains(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function has_nested_vcs_marker(dir, root)
  if not path_contains(root, dir) or dir == root then
    return false
  end

  local found = vim.fs.find(vcs_markers, { path = dir, upward = true, stop = root, limit = 1 })
  return #found > 0
end

local function workspace()
  return require("nvim_workspace.core.workspace")
end

-- Persistence names sessions by Neovim's launch cwd. Save aliases for file
-- roots too so launching from HOME, a project, or an explorer-focused exit all
-- restore the same current work.
local function file_session_roots()
  local ws = workspace()
  local cwd = ws.normalize(vim.fn.getcwd())
  local default_root = ws.default_root()
  local roots = {}
  local seen = {}
  local known_roots = { cwd }
  local known_seen = { [cwd] = true }

  local function add_known(root)
    if type(root) == "string" and root ~= "" and not known_seen[root] then
      known_seen[root] = true
      table.insert(known_roots, 1, root)
    end
  end

  local function add(root)
    if root ~= cwd and not seen[root] then
      seen[root] = true
      roots[#roots + 1] = root
    end
    add_known(root)
  end

  local function covered_root(dir)
    for _, root in ipairs(known_roots) do
      if path_contains(root, dir) and not has_nested_vcs_marker(dir, root) then
        return root
      end
    end
    return nil
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not name:match("^%w[%w+.-]*://") then
        local dir = ws.normalize(vim.fs.dirname(name))
        local root = covered_root(dir) or ws.find_repo_root(dir)
        if root then
          add(root)
        elseif cwd == default_root or not ws.contains(cwd, dir) then
          -- A project-launched editor saving src/file.lua should not mint a
          -- stale-prone src/ session, but a HOME-launched editor still benefits
          -- from a narrower alias for standalone work outside a VCS root.
          add(dir)
        end

        -- Keep the broad HOME session fresh for files under HOME, otherwise a
        -- later plain `nvim` from HOME can restore an older session.
        if path_contains(default_root, name) or ws.contains(default_root, name) then
          add(default_root)
        end
      end
    end
  end

  return roots
end

function M.save_alias_sessions(persistence_plugin)
  local roots = file_session_roots()
  if #roots == 0 then
    return
  end

  local cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    for _, root in ipairs(roots) do
      vim.cmd("cd " .. vim.fn.fnameescape(root))
      persistence_plugin.save()
    end
  end)
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  if not ok then
    assert(ok, err)
  end
end

function M.load()
  if vim.fn.argc() ~= 0 then
    return
  end

  local persistence_plugin = plugin()
  if persistence_plugin then
    M.load_current(persistence_plugin)
  end
end

function M.load_current(persistence_plugin)
  persistence_plugin.load()
  -- Nvim always persists the arglist in :mksession regardless of
  -- sessionoptions; clear it so closed files do not reappear.
  vim.cmd("%argdelete")

  vim.schedule(function()
    M.delete_missing_buffers()
    M.refresh_current_filetype()
  end)
end

function M.save()
  local persistence_plugin = plugin()
  if persistence_plugin then
    M.save_current(persistence_plugin)
  end
end

function M.save_current(persistence_plugin)
  persistence_plugin.save()
  M.save_alias_sessions(persistence_plugin)
end

function M.setup(opts)
  local config = opts or {}
  local save_debounce_ms = config.save_debounce_ms or 500
  if type(save_debounce_ms) ~= "number" or save_debounce_ms < 0 then
    save_debounce_ms = 500
  end
  started_with_stdin = false
  setup_generation = setup_generation + 1
  local generation = setup_generation

  local group = vim.api.nvim_create_augroup(group_name, { clear = true })

  if save_timer and not save_timer:is_closing() then
    save_timer:stop()
    save_timer:close()
  end
  save_timer = assert(vim.uv.new_timer())

  vim.api.nvim_create_autocmd("StdinReadPre", {
    group = group,
    callback = function()
      started_with_stdin = true
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    nested = true,
    callback = function()
      M.load()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete" }, {
    group = group,
    callback = function()
      if not save_timer or save_timer:is_closing() then
        return
      end
      save_timer:stop()
      save_timer:start(
        save_debounce_ms,
        0,
        vim.schedule_wrap(function()
          if generation ~= setup_generation then
            return
          end
          M.save()
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if save_timer and not save_timer:is_closing() then
        save_timer:stop()
        save_timer:close()
      end
      M.save()
    end,
  })
end

return M
