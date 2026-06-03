-- Async file picker: shows recent files instantly, then progressively merges
-- live fd results as you type. Extensible via add_source() so overlay configs
-- can plug in additional search backends without touching this file.
--
-- By default, Ctrl-P searches from HOME so it can find files across the local
-- workspace instead of stopping at the current buffer's repo. `find({ root =
-- ... })` scopes both recent-file results and live fd searches when callers
-- need a narrower picker.
-- Picker mappings restart with a different explicit root instead of changing
-- nvim's cwd, which avoids surprising other editor features.
-- Scope controls: C-r home, C-w repo/workspace root, C-d prompt for directory.
--
-- Internal module: use require("nvim_workspace").files() and
-- require("nvim_workspace").register_file_source() from host configs.

local M = {}
local uv = require("nvim_workspace.core.uv")

M.sources = {}

function M.merge_results(recent, recent_set, extra)
  if not extra or #extra == 0 then
    return recent
  end
  -- Recent files stay pinned first even as live sources arrive. The separate
  -- recent_set prevents a backend result from repeating a recent path that was
  -- filtered out of this root's visible list.
  local all = {}
  local seen = {}
  local n = 0
  for i = 1, #recent do
    n = n + 1
    all[n] = recent[i]
    seen[recent[i]] = true
  end
  for i = 1, #extra do
    local f = extra[i]
    if not seen[f] and not recent_set[f] then
      seen[f] = true
      n = n + 1
      all[n] = f
    end
  end
  return all
end

local fd_cmd
local recent_files = require("nvim_workspace.core.recent")
local scope = require("nvim_workspace.picker.scope")

--- Register a file picker source. The source function receives
--- (prompt, done, root, ctx), where done(paths) completes the source with a
--- list of file paths. Sources can stream earlier chunks via done(paths, {
--- partial = true }) and must eventually call done(paths) once. Sources may
--- call done synchronously or asynchronously, and may return a cancellable
--- handle/function. ctx.status(message) updates the shared picker status panel.
function M.add_source(source, opts)
  if type(scope.register_source) == "function" then
    return scope.register_source(M.sources, source, opts)
  end
  -- Some tests and ad-hoc plugin harnesses stub only the scope helpers
  -- they exercise. Keep registration self-contained in that environment.
  opts = opts or {}
  local spec = {
    run = type(source) == "table" and (source.run or source[1]) or source,
    name = type(source) == "table" and (source.name or source.label) or nil,
  }
  spec.name = spec.name or opts.name or opts.label or "Extension"
  M.sources[#M.sources + 1] = spec
  return spec
end

function M.add_results(extra, root, paths, seen)
  return scope.add_paths(extra, root, paths, seen)
end

function M.resolve_root(opts)
  return scope.resolve_root(opts)
end

function M.find(opts)
  opts = opts or {}
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local make_entry = require("telescope.make_entry")
  local root, context_root = M.resolve_root(opts)
  -- Large roots still get recent-file and extension results, but local fd is a
  -- recursive filesystem walk. Host policy decides when that tradeoff is bad.
  local use_fd = not scope.is_large_search_root(root)

  if not fd_cmd then
    fd_cmd = vim.fn.executable("fd") == 1 and "fd" or "fdfind"
  end

  local recent, recent_set = scope.filter_paths(recent_files.get(), root)
  local entry_maker = make_entry.gen_from_file({})

  local function make_finder(extra)
    -- Telescope table finders are immutable snapshots. Each async batch creates
    -- a fresh finder so the prompt remains stable while results update.
    local results = M.merge_results(recent, recent_set, extra)
    return finders.new_table({ results = results, entry_maker = entry_maker })
  end

  local function source_label(source, index)
    if type(scope.source_name) == "function" then
      return scope.source_name(source, index, #M.sources)
    end
    -- Mirrors the add_source() fallback above when scope is stubbed.
    return source.name or "Extension"
  end

  local function source_run(source)
    return type(source) == "function" and source or source.run
  end

  -- Debounce typing so we don't fork fd on every keystroke.
  -- query_gen monotonically increments; stale callbacks discard their results.
  local debounce_timer = assert(uv.new_timer())
  local last_query = ""
  local active_procs = {}
  local query_gen = 0
  local cleaned = false
  local status = scope.status()
  local ops = scope.operation_status(status)

  local function kill_active()
    for i = 1, #active_procs do
      scope.cancel_handle(active_procs[i])
    end
    active_procs = {}
  end

  local function cleanup()
    if cleaned then
      return
    end
    cleaned = true
    debounce_timer:stop()
    if not debounce_timer:is_closing() then
      debounce_timer:close()
    end
    kill_active()
    ops:reset()
    status:close()
  end

  local picker = pickers.new({}, {
    prompt_title = scope.title("Files", root),
    initial_mode = "insert",
    finder = make_finder(),
    sorter = conf.file_sorter({}),
    previewer = conf.file_previewer({}),
    create_layout = scope.status_layout(status),
    attach_mappings = function(prompt_bufnr, map)
      vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
        buffer = prompt_bufnr,
        once = true,
        callback = cleanup,
      })
      local prompt_win = vim.fn.bufwinid(prompt_bufnr)
      if prompt_win ~= -1 then
        vim.api.nvim_create_autocmd("WinClosed", {
          pattern = tostring(prompt_win),
          once = true,
          callback = cleanup,
        })
      end
      vim.api.nvim_buf_attach(prompt_bufnr, false, {
        on_lines = function()
          if cleaned or debounce_timer:is_closing() then
            return
          end
          debounce_timer:stop()
          debounce_timer:start(
            150,
            0,
            vim.schedule_wrap(function()
              if cleaned or not vim.api.nvim_buf_is_valid(prompt_bufnr) then
                return
              end
              local current = scope.current_picker(prompt_bufnr)
              if not current then
                return
              end
              local prompt = current:_get_prompt()
              if not prompt or #prompt < 2 or prompt == last_query then
                return
              end
              last_query = prompt

              kill_active()
              ops:reset()

              query_gen = query_gen + 1
              local my_gen = query_gen
              local extra = {}
              local extra_seen = {}

              local n_sources = (use_fd and 1 or 0) + #M.sources
              if n_sources == 0 then
                return
              end
              local refresh_scheduled = false

              local function refresh_results()
                refresh_scheduled = false
                if cleaned or my_gen ~= query_gen then
                  return
                end
                if not vim.api.nvim_buf_is_valid(prompt_bufnr) then
                  return
                end
                local p = scope.current_picker(prompt_bufnr)
                if p then
                  p:refresh(make_finder(extra), { reset_prompt = false })
                  status:flush()
                end
              end

              local function schedule_refresh()
                -- Coalesce same-tick backend chunks into one Telescope refresh.
                -- Some sources stream quickly, and refreshing for every small
                -- partial result makes insert-mode typing noticeably worse.
                if refresh_scheduled then
                  return
                end
                refresh_scheduled = true
                vim.schedule(refresh_results)
              end

              local function source_done(paths, _done_opts)
                -- Query generations guard every delayed callback. A cancelled
                -- fd process or extension source may still deliver output after
                -- the user has typed a new prompt or closed the picker.
                if my_gen ~= query_gen then
                  return 0
                end
                local added = M.add_results(extra, root, paths, extra_seen)
                if added > 0 then
                  schedule_refresh()
                end
                return added
              end

              -- Local fd is useful for normal roots, but root-scoped traversal
              -- is too expensive in very large repos. Overlay/indexed sources
              -- still run below and receive the same root constraint.
              if use_fd then
                ops:start("local-fd", "Local files...")
                local fd_query_args = scope.fd_query_args(prompt)
                if #fd_query_args == 0 then
                  ops:finish("local-fd")
                  return
                end
                local fd_args = {
                  fd_cmd,
                  "--type",
                  "f",
                  "--hidden",
                  "--follow",
                  "--full-path",
                  "--max-results",
                  "50",
                }
                vim.list_extend(fd_args, scope.vcs_exclude_args())
                vim.list_extend(fd_args, fd_query_args)
                fd_args[#fd_args + 1] = root
                local proc = vim.system(fd_args, { text = true }, function(result)
                  local stdout = result.stdout or ""
                  vim.schedule(function()
                    if
                      cleaned
                      or my_gen ~= query_gen
                      or not vim.api.nvim_buf_is_valid(prompt_bufnr)
                    then
                      return
                    end
                    local parsed = {}
                    if stdout ~= "" then
                      for f in stdout:gmatch("[^\n]+") do
                        parsed[#parsed + 1] = f
                      end
                    end
                    source_done(parsed)
                    ops:finish("local-fd", ("Local files: %d found"):format(#parsed))
                  end)
                end)
                scope.add_active_handle(active_procs, proc)
              end

              -- Registered sources. Passing root keeps overlay
              -- backends aligned with the same scope as fd/recent files.
              for source_index, source in ipairs(M.sources) do
                local name = source_label(source, source_index)
                local source_key = "extension-" .. source_index
                local completed = false
                ops:start(source_key, name .. " search...")
                local function set_source_status(message)
                  vim.schedule(function()
                    if
                      cleaned
                      or my_gen ~= query_gen
                      or not vim.api.nvim_buf_is_valid(prompt_bufnr)
                    then
                      return
                    end
                    ops:event(source_key, tostring(message or ""))
                  end)
                end
                local ctx = {
                  status = set_source_status,
                }
                local function safe_done(paths, done_opts)
                  if completed then
                    return
                  end
                  if not (done_opts and done_opts.partial) then
                    completed = true
                  end
                  -- Source callbacks often come from vim.system/libuv fast
                  -- events. Normalize them onto the main loop before path
                  -- filtering, which uses vim.fn-backed scope helpers.
                  vim.schedule(function()
                    if
                      cleaned
                      or my_gen ~= query_gen
                      or not vim.api.nvim_buf_is_valid(prompt_bufnr)
                    then
                      return
                    end
                    source_done(paths, done_opts)
                    if completed then
                      ops:finish(source_key, name .. " search complete")
                    end
                  end)
                end
                local ok, handle = pcall(source_run(source), prompt, safe_done, root, ctx)
                if not ok then
                  completed = true
                  ops:finish(source_key, name .. " search unavailable")
                else
                  scope.add_active_handle(active_procs, handle)
                end
              end
            end)
          )
        end,
      })
      scope.attach_picker_mappings(prompt_bufnr, map, {
        context_root = context_root,
        open = function(new_root)
          M.find({ root = new_root, context_root = context_root })
        end,
      })
      return true
    end,
  })

  picker:find()
end

return M
