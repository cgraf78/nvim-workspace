-- Async content search picker: ripgreps recent files first (fast, relevant hits),
-- then searches from the active root as a broader fallback. Extensible via
-- add_source() for overlay-provided search backends.
--
-- By default, Ctrl-Shift-F searches from HOME so content search follows the
-- same path policy as Ctrl-P. `find({ root = ... })` scopes both recent-file
-- results and live rg searches when callers need a narrower picker.
-- Picker mappings restart with a different explicit root instead of changing
-- nvim's cwd, which avoids surprising other editor features.
-- Scope controls: C-r home, C-w repo/workspace root, C-d prompt for directory.
--
-- Internal module: use require("nvim_workspace").grep() and
-- require("nvim_workspace").register_grep_source() from host configs.

local M = {}

M.sources = {}

function M.dedup_lines(lines)
  local results = {}
  local seen = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      -- Treat path+line as the identity so recent-file and root searches do not
      -- show duplicate hits while still preserving distinct backend locations.
      local key = line:match("^(.-:%d+:)") or line
      if not seen[key] then
        seen[key] = true
        results[#results + 1] = line
      end
    end
  end
  return results
end

local recent_files = require("nvim_workspace.core.recent")
local scope = require("nvim_workspace.picker.scope")

--- Register a search source. The source function receives (prompt, done, root,
--- ctx), where done(lines) completes the source with vimgrep-format lines.
--- Sources can stream earlier chunks via done(lines, { partial = true }) and
--- must eventually call done(lines) once. Sources may call done synchronously
--- or asynchronously, and may return a cancellable handle/function.
--- ctx.status(message) updates the shared picker status panel.
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

function M.resolve_root(opts)
  return scope.resolve_root(opts)
end

function M.add_lines(results, root, lines, seen)
  return scope.add_vimgrep_lines(results, root, lines, seen)
end

function M.find(opts)
  opts = opts or {}
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local make_entry = require("telescope.make_entry")
  local root, context_root = M.resolve_root(opts)
  -- Large roots still get recent-file and extension results, but root ripgrep
  -- is a recursive content scan. Host policy decides when that is too costly.
  local use_root_rg = not scope.is_large_search_root(root)

  local entry_maker = make_entry.gen_from_vimgrep({})

  local function make_finder(results)
    -- Telescope table finders are immutable snapshots. Each async batch creates
    -- a fresh finder so the prompt remains stable while results update.
    return finders.new_table({
      results = results or {},
      entry_maker = entry_maker,
    })
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

  local debounce_timer = assert(vim.uv.new_timer())
  local last_query = ""
  local active_procs = {}
  local query_gen = 0
  local cleaned = false
  local recent = scope.filter_paths(recent_files.get(), root)
  local status = scope.status()
  local ops = scope.operation_status(status)

  local function kill_active()
    for i = 1, #active_procs do
      scope.cancel_handle(active_procs[i])
    end
    active_procs = {}
  end

  local tmpfile
  if #recent > 0 then
    -- rg --files-from avoids command-line length limits and keeps paths exact,
    -- which matters for spaces and symlink spellings in recent-file entries.
    tmpfile = vim.fn.tempname()
    vim.fn.writefile(recent, tmpfile)
  end

  -- --fixed-strings: treat query as literal (no regex surprises from user input).
  -- --max-filesize 1M: skip large binaries/generated files.
  local rg_base = { "rg", "--vimgrep", "--fixed-strings", "--smart-case", "--max-filesize", "1M" }

  -- Search recent files first with --max-count 3 per file to avoid one large
  -- file flooding the results before the broader root search completes.
  local rg_recent_prefix
  if tmpfile then
    rg_recent_prefix = { unpack(rg_base) }
    local n = #rg_recent_prefix
    rg_recent_prefix[n + 1] = "--max-count"
    rg_recent_prefix[n + 2] = "3"
    rg_recent_prefix[n + 3] = "--files-from"
    rg_recent_prefix[n + 4] = tmpfile
    rg_recent_prefix[n + 5] = "--"
  end

  local rg_root_prefix = { unpack(rg_base) }
  local n = #rg_root_prefix
  rg_root_prefix[n + 1] = "--max-count"
  rg_root_prefix[n + 2] = "3"
  rg_root_prefix[n + 3] = "--max-depth"
  rg_root_prefix[n + 4] = "8"
  rg_root_prefix[n + 5] = "--max-columns"
  rg_root_prefix[n + 6] = "200"
  rg_root_prefix[n + 7] = "--max-columns-preview"
  rg_root_prefix[n + 8] = "--"

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
    if tmpfile then
      vim.fn.delete(tmpfile)
      tmpfile = nil
    end
    status:close()
  end

  local picker = pickers.new({}, {
    prompt_title = scope.title("Search", root),
    initial_mode = "insert",
    finder = make_finder(),
    sorter = require("telescope.sorters").empty(),
    previewer = conf.grep_previewer({}),
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
            200,
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
              local results = {}
              local seen = {}

              local n_sources = (rg_recent_prefix and 1 or 0)
                + (use_root_rg and 1 or 0)
                + #M.sources
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
                  p:refresh(make_finder(results), { reset_prompt = false })
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

              local function source_done(lines, _done_opts)
                -- Query generations guard every delayed callback. A cancelled
                -- rg process or extension source may still deliver output after
                -- the user has typed a new prompt or closed the picker.
                if my_gen ~= query_gen then
                  return 0
                end
                local added = M.add_lines(results, root, lines, seen)
                if added > 0 then
                  schedule_refresh()
                end
                return added
              end

              -- Source 1: ripgrep on recent files
              if rg_recent_prefix then
                ops:start("recent-rg", "Recent files...")
                local cmd = { unpack(rg_recent_prefix) }
                cmd[#cmd + 1] = prompt
                local proc = vim.system(cmd, { text = true }, function(result)
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
                      for line in stdout:gmatch("[^\n]+") do
                        parsed[#parsed + 1] = line
                      end
                    end
                    source_done(parsed)
                    ops:finish("recent-rg", ("Recent files: %d matches"):format(#parsed))
                  end)
                end)
                scope.add_active_handle(active_procs, proc)
              end

              -- Root ripgrep is the broad fallback for normal roots. Large
              -- repo roots rely on recent-file exact searches plus indexed
              -- overlay sources instead of recursively walking the monorepo.
              if use_root_rg then
                ops:start("root-rg", "Local content...")
                local cmd2 = { unpack(rg_root_prefix) }
                cmd2[#cmd2 + 1] = prompt
                cmd2[#cmd2 + 1] = root
                local proc2 = vim.system(cmd2, { text = true }, function(result)
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
                      local count = 0
                      for line in stdout:gmatch("[^\n]+") do
                        parsed[#parsed + 1] = line
                        count = count + 1
                        if count >= 200 then
                          break
                        end
                      end
                    end
                    source_done(parsed)
                    ops:finish("root-rg", ("Local content: %d matches"):format(#parsed))
                  end)
                end)
                scope.add_active_handle(active_procs, proc2)
              end

              -- Registered sources. Passing root keeps overlay backends aligned
              -- with the same scope as recent-file and root ripgrep searches.
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
                local function safe_done(lines, done_opts)
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
                    source_done(lines, done_opts)
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
