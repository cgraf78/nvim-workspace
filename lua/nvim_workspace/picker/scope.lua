-- Search-picker helpers built on the shared workspace policy.
--
-- Root detection and HOME/symlink normalization live in core.workspace.
-- This module adds search-specific filtering, vimgrep path parsing, and
-- Telescope root-switching mappings for the custom file/search pickers.
--
-- Internal module: file and grep pickers share these helpers, but external
-- callers should register sources or open pickers through nvim_workspace.

local M = {}
local workspace = require("nvim_workspace.core.workspace")

local vcs_metadata_dir_names = { ".git", ".hg", ".jj", ".sl", ".svn" }
local vcs_metadata_dirs = {}
for _, name in ipairs(vcs_metadata_dir_names) do
  vcs_metadata_dirs[name] = true
end

local path_query_regex_chars = [[\.^$*+?()[]{}|]]
-- Indexed sources may support unordered path matching, but factorial regexes
-- become UI-thread work. Five terms covers normal path queries while keeping
-- pasted prose on the cheap fallback path.
local max_unordered_regex_terms = 5

local function regex_escape(text)
  return vim.fn.escape(text, path_query_regex_chars)
end

function M.is_searchable_path(path)
  local normalized_path = workspace.absolute_path(path)
  for part in normalized_path:gmatch("[^/]+") do
    if vcs_metadata_dirs[part] then
      return false
    end
  end
  return true
end

function M.is_large_search_root(root)
  -- Reuse the existing large-repo classifier instead of introducing a second
  -- policy surface. The option tells overlays this is a selected search root,
  -- so they can block only root-wide scans while still allowing subdir scopes.
  return workspace.is_large_repo(root, { search_root = true })
end

function M.resolve_root(opts)
  opts = opts or {}
  local context_root = workspace.normalize(opts.context_root or workspace.current_buffer_dir())
  local root = workspace.normalize(opts.root or workspace.default_root())
  return root, context_root
end

function M.cancel_handle(handle)
  -- Extension sources can return different cancellation shapes depending on
  -- whether they wrap vim.system, libuv, or a composite backend. Normalize that
  -- contract here so file and grep pickers do not need parallel cleanup logic.
  if type(handle) == "function" then
    pcall(handle)
    return
  end

  if type(handle) ~= "table" then
    return
  end

  if type(handle.cancel) == "function" then
    pcall(handle.cancel, handle)
    return
  end

  if type(handle.kill) == "function" then
    pcall(handle.kill, handle, 9)
    return
  end

  for _, child in ipairs(handle) do
    M.cancel_handle(child)
  end
end

function M.add_active_handle(active, handle)
  if not handle then
    return
  end

  if
    type(handle) == "table"
    and type(handle.cancel) ~= "function"
    and type(handle.kill) ~= "function"
  then
    for _, child in ipairs(handle) do
      M.add_active_handle(active, child)
    end
    return
  end

  active[#active + 1] = handle
end

-- Keep source metadata in the shared scope module so file-name and content
-- pickers expose the same extension contract without duplicating policy.
function M.register_source(sources, source, opts)
  opts = opts or {}
  local spec = {}
  if type(source) == "table" then
    spec.run = source.run or source[1]
    spec.name = source.name or source.label or opts.name or opts.label
  else
    spec.run = source
    spec.name = opts.name or opts.label
  end
  spec.name = spec.name or "Extension"
  sources[#sources + 1] = spec
  return spec
end

function M.source_name(source, index, total)
  local name = source and source.name
  if type(name) == "string" and name ~= "" then
    return name
  end
  if total == 1 then
    return "Extension"
  end
  return ("Extension %d"):format(index)
end

function M.status(opts)
  opts = opts or {}
  -- The status buffer sits inside a bordered Telescope popup; a small inset
  -- keeps the text from visually colliding with the border.
  local inset = math.max(0, tonumber(opts.inset) or 2)
  local state = {
    bufnr = nil,
    closed = false,
    line = opts.line or "idle",
    title_text = opts.title or "Status",
    winid = nil,
  }

  function state:title()
    return self.title_text
  end

  function state:render()
    return { self.line }
  end

  local function fit(text, width)
    text = tostring(text or "")
    if #text <= width then
      return text
    end
    if width <= 3 then
      return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
  end

  function state:box_lines()
    local width = opts.width or 60
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
      width = math.min(width, math.max(24, vim.api.nvim_win_get_width(self.winid) - 2))
    end
    local prefix = string.rep(" ", math.min(inset, math.max(0, width)))
    return { prefix .. fit(self.line, math.max(0, width - #prefix)) }
  end

  function state:flush()
    if self.closed or not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
      return
    end
    local lines = self:box_lines()
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = self.bufnr })
    pcall(vim.api.nvim_buf_set_lines, self.bufnr, 0, -1, false, lines)
    pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = self.bufnr })
  end

  function state:attach_window(bufnr, winid)
    if self.closed then
      return
    end
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    self.bufnr = bufnr
    self.winid = winid
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    if winid and vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].wrap = false
      vim.wo[winid].cursorline = false
      vim.wo[winid].number = false
      vim.wo[winid].relativenumber = false
    end
    self:flush()
  end

  function state:set(line, maybe_line)
    if self.closed then
      return
    end
    self.line = tostring(maybe_line or line or "")
    self:flush()
  end

  function state:close()
    self.closed = true
  end

  return state
end

function M.operation_status(status_state, opts)
  -- Multiple backends can be active for one query. Show the most recent active
  -- event instead of letting a completed backend overwrite the status while
  -- slower work is still running.
  opts = opts or {}
  local idle = opts.idle or "idle"
  local active = {}
  local active_count = 0
  local next_order = 0
  status_state:set(idle)

  local tracker = {}

  local function active_message()
    local newest
    for _, state in pairs(active) do
      if not newest or state.order > newest.order then
        newest = state
      end
    end
    return newest and newest.message or idle
  end

  local function activate(key, message)
    if active[key] then
      active[key].message = message or active[key].message
      return
    end
    next_order = next_order + 1
    active[key] = {
      message = message or (tostring(key) .. ": running"),
      order = next_order,
    }
    active_count = active_count + 1
  end

  function tracker:start(key, message)
    activate(key, message)
    status_state:set(active[key].message)
  end

  function tracker:event(key, message)
    if key and active[key] then
      -- Events from active backends are what the user is waiting on; completed
      -- source summaries are handled by finish() so they cannot hide work that
      -- is still running in the background.
      active[key].message = message or active[key].message
      next_order = next_order + 1
      active[key].order = next_order
      status_state:set(active[key].message)
    elseif message then
      status_state:set(message)
    end
  end

  function tracker:finish(key, _message)
    if key and active[key] then
      active[key] = nil
      active_count = math.max(0, active_count - 1)
    end
    if active_count == 0 then
      status_state:set(idle)
    else
      status_state:set(active_message())
    end
  end

  function tracker:reset()
    active = {}
    active_count = 0
    next_order = 0
    status_state:set(idle)
  end

  return tracker
end

function M.status_layout(status_state, opts)
  opts = opts or {}
  local status_height = opts.height or 1

  return function(picker)
    local Layout = require("telescope.pickers.layout")
    local popup = require("plenary.popup")
    local utils = require("telescope.utils")
    local api = vim.api

    local function make_border(border)
      -- Telescope's layout object expects winid, while plenary.popup returns
      -- win_id. Adapting in one place keeps the custom status row compatible
      -- with Telescope's normal mount/unmount flow.
      if not border then
        return nil
      end
      border.winid = border.win_id
      return border
    end

    local function prepare_window_options(popup_opts)
      popup_opts.results.focusable = true
      popup_opts.results.minheight = popup_opts.results.height
      popup_opts.results.highlight = "TelescopeResultsNormal"
      popup_opts.results.borderhighlight = "TelescopeResultsBorder"
      popup_opts.results.titlehighlight = "TelescopeResultsTitle"
      popup_opts.prompt.minheight = popup_opts.prompt.height
      popup_opts.prompt.highlight = "TelescopePromptNormal"
      popup_opts.prompt.borderhighlight = "TelescopePromptBorder"
      popup_opts.prompt.titlehighlight = "TelescopePromptTitle"

      if popup_opts.preview then
        popup_opts.preview.focusable = true
        popup_opts.preview.minheight = popup_opts.preview.height
        popup_opts.preview.highlight = "TelescopePreviewNormal"
        popup_opts.preview.borderhighlight = "TelescopePreviewBorder"
        popup_opts.preview.titlehighlight = "TelescopePreviewTitle"
      end
    end

    local function add_status_options(popup_opts)
      local gap = 2
      local height = math.min(status_height, math.max(1, popup_opts.results.height - gap - 1))
      if popup_opts.results.height <= height + gap + 1 then
        return
      end

      -- Carve the status row out of the results pane instead of adding another
      -- floating layer. That keeps Telescope's prompt/results/preview geometry
      -- stable across small terminals and dynamic layout updates.
      local status_opts = vim.deepcopy(popup_opts.results)
      status_opts.enter = false
      status_opts.focusable = false
      status_opts.height = height
      status_opts.minheight = height
      status_opts.title = opts.title or status_state:title()
      status_opts.zindex = (status_opts.zindex or 50) + 10
      status_opts.highlight = "TelescopeResultsNormal"
      status_opts.borderhighlight = "TelescopeResultsBorder"
      status_opts.titlehighlight = "TelescopeResultsTitle"

      if popup_opts.prompt.line < popup_opts.results.line then
        status_opts.line = popup_opts.results.line
        popup_opts.results.line = status_opts.line + status_opts.height + gap
        popup_opts.results.height = popup_opts.results.height - status_opts.height - gap
      else
        status_opts.line = popup_opts.prompt.line - status_opts.height - gap
        popup_opts.results.height = popup_opts.results.height - status_opts.height - gap
      end

      popup_opts.results.minheight = popup_opts.results.height
      popup_opts.status = status_opts
    end

    local function get_options()
      local line_count = vim.o.lines - vim.o.cmdheight
      if vim.o.laststatus ~= 0 then
        line_count = line_count - 1
      end

      local popup_opts = picker:get_window_options(vim.o.columns, line_count)
      prepare_window_options(popup_opts)
      add_status_options(popup_opts)
      return popup_opts
    end

    local function create_status_window(self, status_opts)
      local status_win, status_window_opts = picker:_create_window("", status_opts)
      local status_bufnr = api.nvim_win_get_buf(status_win)
      self.status = Layout.Window({
        winid = status_win,
        bufnr = status_bufnr,
        border = make_border(status_window_opts.border),
      })
      status_state:attach_window(status_bufnr, status_win)
    end

    return Layout({
      picker = picker,
      mount = function(self)
        local popup_opts = get_options()

        local results_win, results_opts = picker:_create_window("", popup_opts.results)
        local results_bufnr = api.nvim_win_get_buf(results_win)
        self.results = Layout.Window({
          winid = results_win,
          bufnr = results_bufnr,
          border = make_border(results_opts.border),
        })

        if popup_opts.status then
          create_status_window(self, popup_opts.status)
        end

        if popup_opts.preview then
          local preview_win, preview_opts = picker:_create_window("", popup_opts.preview)
          local preview_bufnr = api.nvim_win_get_buf(preview_win)
          self.preview = Layout.Window({
            winid = preview_win,
            bufnr = preview_bufnr,
            border = make_border(preview_opts.border),
          })
        end

        local prompt_win, prompt_opts = picker:_create_window("", popup_opts.prompt)
        local prompt_bufnr = api.nvim_win_get_buf(prompt_win)
        self.prompt = Layout.Window({
          winid = prompt_win,
          bufnr = prompt_bufnr,
          border = make_border(prompt_opts.border),
        })
      end,
      unmount = function(self)
        utils.win_delete("results_win", self.results.winid, true, true)
        if self.status then
          utils.win_delete("status_win", self.status.winid, true, true)
          utils.win_delete("status_border_win", self.status.border.winid, true, true)
        end
        if self.preview then
          utils.win_delete("preview_win", self.preview.winid, true, true)
          utils.win_delete("preview_border_win", self.preview.border.winid, true, true)
        end
        utils.win_delete("prompt_border_win", self.prompt.border.winid, true, true)
        utils.win_delete("results_border_win", self.results.border.winid, true, true)
        if api.nvim_win_is_valid(self.prompt.winid) then
          api.nvim_win_close(self.prompt.winid, true)
        end
        vim.schedule(function()
          utils.buf_delete(self.prompt.bufnr)
        end)
      end,
      update = function(self)
        local popup_opts = get_options()
        popup.move(self.prompt.winid, popup_opts.prompt)
        popup.move(self.results.winid, popup_opts.results)
        if self.preview and popup_opts.preview then
          popup.move(self.preview.winid, popup_opts.preview)
        end
        if self.status and popup_opts.status then
          popup.move(self.status.winid, popup_opts.status)
          status_state:attach_window(self.status.bufnr, self.status.winid)
        elseif self.status then
          utils.win_delete("status_win", self.status.winid, true, true)
          utils.win_delete("status_border_win", self.status.border.winid, true, true)
          self.status = nil
        elseif popup_opts.status then
          create_status_window(self, popup_opts.status)
        end
      end,
    })
  end
end

function M.path_query_terms(prompt)
  local terms = {}
  for term in tostring(prompt or ""):gmatch("%S+") do
    terms[#terms + 1] = term
  end
  return terms
end

function M.fd_query_args(prompt)
  local terms = M.path_query_terms(prompt)
  if #terms == 0 then
    return {}
  end

  local args = {}
  for i = 2, #terms do
    -- fd treats --and terms as additional regex filters. This gives path search
    -- a simple "all words somewhere in the path" behavior without shelling out
    -- to a custom fuzzy matcher.
    args[#args + 1] = "--and"
    args[#args + 1] = regex_escape(terms[i])
  end
  args[#args + 1] = "--"
  args[#args + 1] = regex_escape(terms[1])
  return args
end

function M.unordered_path_regex(prompt)
  local terms = M.path_query_terms(prompt)
  if #terms == 0 then
    return ""
  end
  if #terms == 1 then
    return regex_escape(terms[1])
  end

  local escaped = {}
  for i = 1, #terms do
    escaped[i] = regex_escape(terms[i])
  end

  -- Some indexed path backends accept one regex query string. For normal short
  -- path queries, enumerate term orders so "foo bar" can match either
  -- "foo/.../bar" or "bar/.../foo". Keep a cap so a pasted sentence does not
  -- build a factorial sized regex on the UI thread.
  if #escaped > max_unordered_regex_terms then
    return table.concat(escaped, ".*")
  end

  local alternatives = {}
  local seen = {}
  local used = {}
  local current = {}

  local function permute()
    if #current == #escaped then
      local alternative = table.concat(current, ".*")
      if not seen[alternative] then
        seen[alternative] = true
        alternatives[#alternatives + 1] = alternative
      end
      return
    end

    for i = 1, #escaped do
      if not used[i] then
        used[i] = true
        current[#current + 1] = escaped[i]
        permute()
        current[#current] = nil
        used[i] = nil
      end
    end
  end

  permute()
  return table.concat(alternatives, "|")
end

function M.vcs_exclude_args()
  local args = {}
  for _, name in ipairs(vcs_metadata_dir_names) do
    args[#args + 1] = "--exclude"
    args[#args + 1] = name
  end
  return args
end

function M.filter_paths(paths, root)
  local filtered = {}
  local seen = {}
  local normalized_root = workspace.normalize(root)

  for _, path in ipairs(paths or {}) do
    local visible = path ~= "" and workspace.visible_path(normalized_root, path) or nil
    if visible and M.is_searchable_path(visible) and not seen[visible] then
      filtered[#filtered + 1] = visible
      seen[visible] = true
    end
  end

  return filtered, seen
end

function M.add_paths(results, root, paths, seen)
  if not paths then
    return 0
  end

  local added = 0
  local normalized_root = workspace.normalize(root)
  for i = 1, #paths do
    local visible = paths[i] ~= "" and workspace.visible_path(normalized_root, paths[i]) or nil
    if visible and M.is_searchable_path(visible) and not (seen and seen[visible]) then
      results[#results + 1] = visible
      if seen then
        seen[visible] = true
      end
      added = added + 1
    end
  end
  return added
end

function M.title(kind, root)
  return kind .. ": " .. workspace.display(root)
end

function M.vimgrep_path(line)
  if type(line) ~= "string" then
    return nil
  end
  return line:match("^(.-):%d+:%d+:") or line:match("^(.-):%d+:")
end

function M.visible_vimgrep_line(root, line)
  if type(line) ~= "string" then
    return nil
  end

  -- Extension sources and rg both speak vimgrep lines. Rewrite only the path
  -- prefix so line/column/message text stays byte-for-byte compatible with
  -- Telescope's vimgrep entry maker.
  local path, suffix = line:match("^(.-)(:%d+:%d+:.*)$")
  if not path then
    path, suffix = line:match("^(.-)(:%d+:.*)$")
  end
  if not path then
    return line
  end

  local visible = workspace.visible_path(root, path)
  if not visible then
    return nil
  end
  return visible .. suffix
end

function M.add_vimgrep_lines(results, root, lines, seen)
  if not lines then
    return 0
  end

  local added = 0
  for i = 1, #lines do
    local line = lines[i]
    if line ~= "" then
      local visible_line = M.visible_vimgrep_line(root, line)
      if visible_line then
        local path = M.vimgrep_path(visible_line)
        local key = visible_line:match("^(.-:%d+:)") or visible_line
        if path and M.is_searchable_path(path) and not (seen and seen[key]) then
          results[#results + 1] = visible_line
          if seen then
            seen[key] = true
          end
          added = added + 1
        end
      end
    end
  end
  return added
end

function M.prompt_for_root(default_root, callback)
  workspace.prompt_for_dir(default_root, callback, { prompt = "Search root: " })
end

function M.current_picker(prompt_bufnr)
  local ok, action_state = pcall(require, "telescope.actions.state")
  if not ok then
    return nil
  end
  local ok_picker, picker = pcall(action_state.get_current_picker, prompt_bufnr)
  return ok_picker and picker or nil
end

local function picker_results_win(picker)
  if not picker or type(picker.results_win) ~= "number" then
    return nil
  end
  if not vim.api.nvim_win_is_valid(picker.results_win) then
    return nil
  end
  local ok_buf, win_bufnr = pcall(vim.api.nvim_win_get_buf, picker.results_win)
  if not ok_buf then
    return nil
  end
  if
    type(picker.results_bufnr) == "number"
    and vim.api.nvim_buf_is_valid(picker.results_bufnr)
    and win_bufnr ~= picker.results_bufnr
  then
    return nil
  end
  return picker.results_win
end

function M.telescope_flash(prompt_bufnr)
  if not vim.api.nvim_buf_is_valid(prompt_bufnr) then
    return false
  end

  local picker = M.current_picker(prompt_bufnr)
  local results_win = picker_results_win(picker)
  if not results_win then
    return false
  end

  local ok_flash, flash = pcall(require, "flash")
  if not ok_flash then
    return false
  end

  local function valid_results_window(win)
    return win == results_win
      and picker_results_win(picker) == win
      and vim.api.nvim_buf_is_valid(prompt_bufnr)
  end

  return pcall(flash.jump, {
    pattern = "^",
    label = { after = { 0, 0 } },
    search = {
      mode = "search",
      exclude = {
        function(win)
          return not valid_results_window(win)
        end,
      },
    },
    action = function(match)
      if not (match and type(match.pos) == "table" and valid_results_window(match.win)) then
        return
      end
      pcall(picker.set_selection, picker, match.pos[1] - 1)
    end,
  })
end

function M.attach_picker_mappings(prompt_bufnr, map, opts)
  opts = opts or {}
  local actions = require("telescope.actions")
  local context_root = workspace.normalize(opts.context_root or workspace.current_buffer_dir())

  local function open(new_root)
    if opts.open then
      opts.open(workspace.normalize(new_root))
    end
  end

  local function reopen(new_root)
    -- Close before reopening so Telescope releases the old prompt buffer and
    -- any active backend handles owned by its cleanup autocmds.
    actions.close(prompt_bufnr)
    vim.schedule(function()
      open(new_root)
    end)
  end

  local function map_both(lhs, rhs)
    map("i", lhs, rhs)
    map("n", lhs, rhs)
  end

  -- LazyVim's default Telescope Flash mapping can outlive picker windows if the
  -- picker is closed while Flash is reading a label. Bind a picker-local variant
  -- first so Telescope will skip the default mapping for these keys.
  map("i", "<C-s>", M.telescope_flash)
  map("n", "s", M.telescope_flash)

  map_both("<C-r>", function()
    reopen(workspace.default_root())
  end)

  map_both("<C-w>", function()
    reopen(workspace.repo_root(context_root))
  end)

  map_both("<C-d>", function()
    actions.close(prompt_bufnr)
    vim.schedule(function()
      M.prompt_for_root(context_root, open)
    end)
  end)
end

return M
