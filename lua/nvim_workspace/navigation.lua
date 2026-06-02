local M = {}

local definition_method = "textDocument/definition"

local default_shell_filetypes = {
  bash = true,
  sh = true,
  zsh = true,
}

local default_config = {
  notify_title = "navigation",
  path_first_filetypes = default_shell_filetypes,
  shell_filetypes = default_shell_filetypes,
  shell_module = "nvim_workspace.shell",
  prefer_shell_for_home_paths = true,
}

local function copy_set(value, fallback)
  local source = type(value) == "table" and value or fallback
  local result = {}
  for key, item in pairs(source or {}) do
    if type(key) == "number" then
      result[item] = true
    elseif item then
      result[key] = true
    end
  end
  return result
end

local function config()
  local raw = require("nvim_workspace.config").get().navigation or {}
  return {
    notify_title = raw.notify_title or default_config.notify_title,
    path_first_filetypes = copy_set(raw.path_first_filetypes, default_config.path_first_filetypes),
    shell_filetypes = copy_set(raw.shell_filetypes, default_config.shell_filetypes),
    shell_module = raw.shell_module or default_config.shell_module,
    prefer_shell_for_home_paths = raw.prefer_shell_for_home_paths ~= false,
  }
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = config().notify_title })
end

local function supports_method(client, bufnr, method)
  if type(client.supports_method) == "function" then
    local ok, supported = pcall(client.supports_method, client, method, bufnr)
    if ok and supported then
      return true
    end
  end

  return client.server_capabilities and client.server_capabilities.definitionProvider == true
end

function M.has_lsp_definition(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if supports_method(client, bufnr, definition_method) then
      return true
    end
  end
  return false
end

local function shell_identifier(symbol)
  return type(symbol) == "string" and symbol:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function regex_escape(value)
  return (value:gsub("([^%w_])", "\\%1"))
end

local function join(dir, path)
  return (dir:gsub("/$", "")) .. "/" .. path
end

local function absolute(path)
  return path:match("^/") or path:match("^%a:[/\\]")
end

local function exists(path)
  return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

local function normalize_existing_path(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/+$", ""))
end

local function expand_home_ref(path)
  local home = vim.env.HOME
  if type(home) ~= "string" or home == "" then
    return path
  end

  if path == "~" or path == "$HOME" or path == "${HOME}" then
    return home
  end

  local suffix = path:match("^~/(.+)$")
  if suffix then
    return join(home, suffix)
  end

  suffix = path:match("^%$HOME/(.+)$")
  if suffix then
    return join(home, suffix)
  end

  suffix = path:match("^%${HOME}/(.+)$")
  if suffix then
    return join(home, suffix)
  end

  return path
end

local function path_like(path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  return absolute(path)
    or path:match("^~/?")
    or path:match("^%$HOME/?")
    or path:match("^%${HOME}/?")
    or path:match("^%.%.?/")
    or path:find("/", 1, true) ~= nil
    or path:find("\\", 1, true) ~= nil
    or path:match("^%.[%w_-]")
    or path:match("%.[%w_+-]+$")
end

local function path_variants(path)
  local variants = { { path = path, line = 1, col = 0 } }
  local base, line, col = path:match("^(.+):(%d+):(%d+)$")
  if base then
    variants[#variants + 1] = { path = base, line = tonumber(line) or 1, col = tonumber(col) or 0 }
  end

  base, line = path:match("^(.+):(%d+)$")
  if base then
    variants[#variants + 1] = { path = base, line = tonumber(line) or 1, col = 0 }
  end

  return variants
end

local function cursor_token(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  if line == "" then
    return nil
  end

  local col = math.min(cursor[2] + 1, #line)
  local start = col
  while start > 1 and not line:sub(start - 1, start - 1):match("%s") do
    start = start - 1
  end

  local finish = col
  while finish <= #line and not line:sub(finish, finish):match("%s") do
    finish = finish + 1
  end

  local token = line:sub(start, finish - 1)
  token = token:gsub("^[\"'`]+", ""):gsub("[,\"'`;]+$", "")
  return token ~= "" and token or nil
end

local function resolve_existing(path, bufnr)
  path = expand_home_ref(path)
  if absolute(path) then
    return exists(path) and normalize_existing_path(path) or nil
  end

  local candidates = {}
  local current = vim.api.nvim_buf_get_name(bufnr)
  if current ~= "" then
    candidates[#candidates + 1] = join(vim.fn.fnamemodify(current, ":h"), path)
  end
  candidates[#candidates + 1] = join(vim.fn.getcwd(), path)

  for _, candidate in ipairs(candidates) do
    if exists(candidate) then
      return normalize_existing_path(candidate)
    end
  end

  return nil
end

function M.file_location_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local seen = {}
  for _, raw in ipairs({ cursor_token(bufnr), vim.fn.expand("<cfile>") }) do
    if type(raw) == "string" and raw ~= "" and not seen[raw] then
      seen[raw] = true
      for _, variant in ipairs(path_variants(raw)) do
        if path_like(variant.path) then
          local path = resolve_existing(variant.path, bufnr)
          if path then
            return {
              path = path,
              line = math.max(variant.line or 1, 1),
              col = math.max(variant.col or 0, 0),
            }
          end
        end
      end
    end
  end

  return nil
end

local function edit_location(location)
  if vim.fn.isdirectory(location.path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(location.path))
    return true
  end

  vim.cmd("edit +" .. location.line .. " " .. vim.fn.fnameescape(location.path))
  if location.col > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { location.line, location.col - 1 })
  end
  return true
end

function M.goto_file_at_cursor(bufnr)
  local location = M.file_location_at_cursor(bufnr)
  if not location then
    return false
  end

  return edit_location(location)
end

local function shell_definition_pattern(symbol)
  return "^[[:space:]]*(function[[:space:]]+)?"
    .. regex_escape(symbol)
    .. "([[:space:]]*\\(\\))?[[:space:]]*\\{"
end

local function rg_matches(args)
  local lines = vim.fn.systemlist(args)
  if vim.v.shell_error > 1 then
    return {}
  end

  local matches = {}
  for _, line in ipairs(lines) do
    local ok, item = pcall(vim.json.decode, line)
    if ok and item.type == "match" and item.data then
      local path = item.data.path and item.data.path.text
      local submatch = item.data.submatches and item.data.submatches[1]
      if path and submatch then
        matches[#matches + 1] = {
          path = path,
          line = item.data.line_number or 1,
          col = (submatch.start or 0) + 1,
        }
      end
    end
  end
  return matches
end

local function shell_policy()
  local module = config().shell_module
  if type(module) ~= "string" or module == "" then
    return nil
  end

  local ok, policy = pcall(require, module)
  if ok and type(policy) == "table" then
    return policy
  end
  return nil
end

function M.shell_locations(symbol, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not shell_identifier(symbol) or vim.fn.executable("rg") ~= 1 then
    return {}
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return {}
  end

  local policy = shell_policy()
  if not policy or type(policy.search_paths_for) ~= "function" then
    return {}
  end

  local search_paths, globs = policy.search_paths_for(path)
  if type(search_paths) ~= "table" or #search_paths == 0 then
    return {}
  end

  -- Shell fallback must use the exact bounded workspace handed to bashls.
  -- Otherwise "go to definition" can accidentally scan all of HOME while the
  -- language server is intentionally limited to a small shell-owned subset.
  local args = {
    "rg",
    "--json",
    "--hidden",
    "--regexp",
    shell_definition_pattern(symbol),
  }
  for _, glob in ipairs(globs or {}) do
    args[#args + 1] = "--glob"
    args[#args + 1] = glob
  end
  vim.list_extend(args, search_paths)

  return rg_matches(args)
end

function M.shell_location(symbol, bufnr)
  local locations = M.shell_locations(symbol, bufnr)
  if #locations == 1 then
    return locations[1]
  end
  if #locations > 1 then
    local current = vim.api.nvim_buf_get_name(bufnr or 0)
    local current_matches = vim.tbl_filter(function(location)
      return location.path == current
    end, locations)
    if #current_matches == 1 then
      return current_matches[1]
    end

    -- Prefer non-test paths when fixtures duplicate real shell functions.
    -- This keeps fallback navigation useful in source trees with test copies
    -- while still returning "multiple" for genuinely ambiguous production code.
    local non_test_matches = vim.tbl_filter(function(location)
      return not location.path:match("/tests?/")
    end, locations)
    if #non_test_matches == 1 then
      return non_test_matches[1]
    end
  end
  if #locations > 1 then
    return nil, "multiple"
  end
  return nil, "missing"
end

local function shell_filetype(bufnr)
  return config().shell_filetypes[vim.bo[bufnr].filetype] == true
end

function M.goto_shell_definition(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not shell_filetype(bufnr) then
    return false
  end

  local symbol = vim.fn.expand("<cword>")
  local location, reason = M.shell_location(symbol, bufnr)
  if not location then
    if reason == "multiple" then
      notify("multiple shell definitions found for " .. symbol)
    end
    return false
  end

  return edit_location(location)
end

local function prefer_shell_definition(bufnr)
  if not shell_filetype(bufnr) or not config().prefer_shell_for_home_paths then
    return false
  end

  local policy = shell_policy()
  if type(policy) ~= "table" or type(policy.is_home_shell_path) ~= "function" then
    return false
  end

  local ok, result = pcall(policy.is_home_shell_path, vim.api.nvim_buf_get_name(bufnr))
  return ok and result == true
end

local function result_locations(result)
  if not result then
    return {}
  end

  -- LSP definition responses are either one Location/LocationLink or a list.
  -- Normalize here so the dispatcher can distinguish "empty result" from
  -- "server found something" without using vim.lsp.buf.definition()'s terminal
  -- notification path.
  if vim.islist(result) then
    return result
  end

  return { result }
end

local function lsp_items(results)
  local items = {}
  for client_id, response in pairs(results or {}) do
    local client = vim.lsp.get_client_by_id(client_id)
    local encoding = client and client.offset_encoding or "utf-16"
    local ok, converted = pcall(
      vim.lsp.util.locations_to_items,
      result_locations(response and response.result),
      encoding
    )
    if ok then
      vim.list_extend(items, converted)
    end
  end
  return items
end

local function jump_to_lsp_items(items, win, tagname, from)
  if #items == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  -- Preserve the default Neovim ergonomics even though the module cannot call
  -- vim.lsp.buf.definition() directly: single locations jump immediately,
  -- multiple locations open quickfix, and tag/jump state remains useful.
  if #items == 1 then
    local item = items[1]
    local target = item.bufnr or vim.fn.bufadd(item.filename)

    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! m'")
      vim.fn.settagstack(
        vim.fn.win_getid(win),
        { items = { { tagname = tagname, from = from } } },
        "t"
      )
      vim.bo[target].buflisted = true
      vim.api.nvim_win_set_buf(win, target)
      vim.api.nvim_win_set_cursor(win, { item.lnum, math.max((item.col or 1) - 1, 0) })
      pcall(vim.cmd, "normal! zv")
    end)
    return true
  end

  vim.api.nvim_win_call(win, function()
    vim.fn.setqflist({}, " ", { title = "LSP locations", items = items })
    vim.cmd("botright copen")
  end)
  return true
end

local function request_lsp_definition(bufnr, on_empty)
  local clients = vim.tbl_filter(function(client)
    return supports_method(client, bufnr, definition_method)
  end, vim.lsp.get_clients({ bufnr = bufnr }))
  if #clients == 0 then
    return false
  end

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local tagname = vim.fn.expand("<cword>")
  local from = vim.fn.getpos(".")
  from[1] = bufnr

  -- Query LSP directly instead of calling vim.lsp.buf.definition(). The built-in
  -- helper notifies and stops on empty results, while this dispatcher can still
  -- try path and shell-symbol fallbacks for valid but server-missed symbols.
  vim.lsp.buf_request_all(bufnr, definition_method, function(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding)
  end, function(results)
    -- Any asynchronous LSP response can outlive its original buffer/window.
    -- Revalidate every handle before touching state so Ctrl-click/gd cannot
    -- mutate a newly focused window after the user moved on.
    if
      not vim.api.nvim_buf_is_valid(bufnr)
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= bufnr
    then
      return
    end

    if jump_to_lsp_items(lsp_items(results), win, tagname, from) then
      return
    end

    vim.api.nvim_win_call(win, function()
      -- Fallback uses <cword>/<cfile>, so restore the original cursor before
      -- trying literal paths or shell-symbol lookup after an async response.
      pcall(vim.api.nvim_win_set_cursor, win, cursor)
      on_empty()
    end)
  end)
  return true
end

-- `goto` is a Lua keyword in newer parsers. Keep the public key stable while
-- using bracket syntax so the module works across Neovim/Lua builds.
M["goto"] = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local filetype = vim.bo[bufnr].filetype
  local path_first = config().path_first_filetypes[filetype] == true
  local shell_definition_first = prefer_shell_definition(bufnr)

  local function fallback(lsp_empty)
    if not path_first and M.goto_file_at_cursor(bufnr) then
      return
    end

    if M.goto_shell_definition(bufnr) then
      return
    end

    if lsp_empty then
      notify("No locations found", vim.log.levels.INFO)
    else
      notify(
        'method "textDocument/definition" is not supported by any server activated for this buffer'
      )
    end
  end

  -- Shell-like files often contain quoted real paths while shell LSP coverage is
  -- uneven. Other source buffers should let LSP own ambiguous tokens first,
  -- because language servers understand generated files and include paths.
  if path_first and M.goto_file_at_cursor(bufnr) then
    return
  end

  -- Configured HOME shell paths use a bounded local index that is often faster
  -- and more complete than waiting for bashls on helper functions.
  if shell_definition_first and M.goto_shell_definition(bufnr) then
    return
  end

  if request_lsp_definition(bufnr, function()
    fallback(true)
  end) then
    return
  end

  fallback(false)
end

-- Prefer this alias in host configs. It avoids Lua keyword syntax friction while
-- preserving the original `goto` key for callers that already use bracket form.
M.follow = M["goto"]

local function move_to_mouse(pos)
  pos = pos or vim.fn.getmousepos()
  local winid = tonumber(pos.winid) or 0
  local line = tonumber(pos.line) or 0
  local column = tonumber(pos.column) or 0

  if winid == 0 or line <= 0 or column <= 0 then
    return false
  end

  local win = winid
  if not vim.api.nvim_win_is_valid(win) then
    local winnr = vim.fn.win_id2win(winid)
    if winnr == 0 then
      return false
    end
    win = vim.api.nvim_tabpage_list_wins(0)[winnr]
    if not win or not vim.api.nvim_win_is_valid(win) then
      return false
    end
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  if line > vim.api.nvim_buf_line_count(bufnr) then
    return false
  end

  -- Mouse APIs report a Vim window ID. API calls use window handles. Prefer the
  -- Vim ID for focus because it follows Neovim's own mouse-position contract,
  -- then fall back to the normalized API handle for synthetic test positions.
  if vim.fn.win_gotoid(winid) ~= 1 then
    local ok = pcall(vim.api.nvim_set_current_win, win)
    if not ok then
      return false
    end
  end

  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local col = math.min(math.max(column - 1, 0), #text)
  local ok = pcall(vim.api.nvim_win_set_cursor, win, { line, col })
  return ok
end

function M.goto_mouse(pos)
  -- Lua mouse mappings do not run the built-in cursor placement first. Move to
  -- the clicked buffer position explicitly so Ctrl-click follows what was
  -- clicked, not whatever happened to be under the previous cursor.
  if not move_to_mouse(pos) then
    return false
  end

  M.follow()
  return true
end

return M
