-- Load actual dependencies without a plugin manager or the user's configuration.
for _, key in ipairs({ "NEOTREE", "NUI", "PLENARY", "DEVICONS" }) do
  vim.opt.runtimepath:append(vim.env["NVIM_WORKSPACE_TEST_" .. key .. "_DIR"])
end
vim.opt.runtimepath:prepend(vim.env.NVIM_WORKSPACE_TEST_ROOT)
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"
vim.opt.lines = 40
vim.opt.columns = 140
vim.fn.mkdir(vim.fn.stdpath("data"), "p")

local api = vim.api
local tmp = vim.env.NVIM_WORKSPACE_TEST_TMP
local home = vim.env.HOME
local outside = tmp .. "/outside"
local repo = tmp .. "/repo"
local paths = require("nvim_workspace.neo_tree")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")
local command = require("neo-tree.command")

local function write(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "fixture" }, path)
  return path
end

local home_file = write(home .. "/notes/home.txt")
local external_file = write(outside .. "/standalone.txt")
local repo_file = write(repo .. "/src/code.lua")
vim.fn.mkdir(repo .. "/.git", "p")
local missing_file = outside .. "/new.txt"
local linked_file = write(tmp .. "/linked-project/src/linked.txt")
assert((vim.uv or vim.loop).fs_symlink(tmp .. "/linked-project", home .. "/linked-project"))

paths.setup_manager_patch()
local neotree_opts = {
  enable_git_status = false,
  enable_diagnostics = false,
  filesystem = {
    -- LazyVim's imported extra disables cwd binding in the actual consumer.
    bind_to_cwd = false,
    -- One follower owns selection and rerooting; native follow races reopening.
    follow_current_file = { enabled = false },
    use_libuv_file_watcher = false,
    async_directory_scan = "always",
    filtered_items = { visible = true },
  },
}
local overlay_spec
if vim.env.NVIM_WORKSPACE_TEST_OVERLAY then
  -- Load just the declarative consumer integration, without LazyVim, persistence,
  -- or any installed user config. Its opts resolve against this provider worktree.
  local specs =
    _G.dofile(vim.env.NVIM_WORKSPACE_TEST_OVERLAY .. "/home/.config/nvim/lua/plugins/workspace.lua")
  for _, spec in ipairs(specs) do
    if spec[1] == "nvim-neo-tree/neo-tree.nvim" then
      overlay_spec = spec
    end
  end
  assert(overlay_spec, "overlay has no Neo-tree specification")
  neotree_opts = vim.tbl_deep_extend("force", neotree_opts, overlay_spec.opts())
  assert(neotree_opts.filesystem.bind_to_cwd == false, "overlay must disable cwd binding")
  assert(neotree_opts.filesystem.follow_current_file.enabled == false, "overlay must own following")
  assert(neotree_opts.filesystem.filtered_items.visible == true, "overlay must show hidden items")
end
require("neo-tree").setup(neotree_opts)

-- Neo-tree catches deferred callback failures and only logs them. Surface those
-- failures as test failures even when a later navigation eventually succeeds.
local errors = {}
local log = require("neo-tree.log")
local original_error = log.error
log.error = function(...)
  local parts = {}
  for _, part in ipairs({ ... }) do
    parts[#parts + 1] = tostring(part)
  end
  errors[#errors + 1] = table.concat(parts, " ")
  original_error(...)
end

local function equal(actual, expected, label)
  assert(
    actual == expected,
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function state()
  return manager.get_state("filesystem")
end

local function wait_for(label, predicate)
  assert(vim.wait(4000, predicate, 10), label .. ": " .. vim.inspect({
    path = state().path,
    winid = state().winid,
    current_win = api.nvim_get_current_win(),
    current_buf = api.nvim_buf_get_name(0),
  }))
end

local function selected()
  local tree = state().tree
  -- A reopened sidebar has a window before Nui has attached its replacement tree.
  local ok, node = pcall(function()
    return tree and tree:get_node()
  end)
  if not ok then
    return nil
  end
  return node and node:get_id()
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local function expect_tree(root, file)
  wait_for("tree rooted at " .. root .. " revealing " .. tostring(file), function()
    return renderer.window_exists(state())
      and state().path == root
      and (not file or selected() == file)
  end)
end

local function close_tree()
  command.execute({ source = "filesystem", action = "close" })
  wait_for("tree closed", function()
    return not renderer.window_exists(state())
  end)
end

-- Absence assertions must outlive both the workspace and native follow timers.
-- A sentinel observes the full event-loop interval instead of blocking with sleep.
local function drain()
  local done = false
  vim.defer_fn(function()
    done = true
  end, 450)
  wait_for("follow timers drained", function()
    return done
  end)
end

local function check(label, callback)
  callback()
  assert(#errors == 0, "Neo-tree runtime error: " .. table.concat(errors, "\n"))
  api.nvim_out_write("ok: neo-tree integration: " .. label .. "\n")
end

local function run()
  local editor = api.nvim_get_current_win()
  local cwd = vim.fn.getcwd()

  check("initial external standalone root", function()
    edit(external_file)
    paths.open(nil, { action = "show" })
    expect_tree(outside, external_file)
    equal(api.nvim_get_current_win(), editor, "initial open preserves focus")
    equal(vim.fn.getcwd(), cwd, "initial open preserves cwd")
    close_tree()
  end)

  check("initial external VCS root", function()
    edit(repo_file)
    paths.open(nil, { action = "show" })
    expect_tree(repo, repo_file)
    close_tree()
  end)

  check("canonical files under HOME aliases retain visible paths", function()
    edit(linked_file)
    paths.open(nil, { action = "show" })
    expect_tree(home, home .. "/linked-project/src/linked.txt")
    close_tree()
  end)

  check("HOME to external and back with workspace-owned following", function()
    edit(home_file)
    paths.open(nil, { action = "show" })
    expect_tree(home, home_file)
    edit(external_file)
    expect_tree(outside, external_file)
    edit(home_file)
    expect_tree(home, home_file)
    equal(api.nvim_get_current_win(), editor, "following preserves focus")
    equal(vim.fn.getcwd(), cwd, "following preserves cwd")
  end)

  check("in-root activation follows and preserves the selected root", function()
    local sibling = write(home .. "/notes/sibling.txt")
    edit(sibling)
    expect_tree(home, sibling)
    edit(home_file)
    expect_tree(home, home_file)
    equal(api.nvim_get_current_win(), editor, "in-root follow preserves focus")
  end)

  check("rapid file changes follow the final active buffer", function()
    edit(external_file)
    edit(repo_file)
    edit(home_file)
    expect_tree(home, home_file)
    drain()
    equal(state().path, home, "rapid switching final root")
    equal(selected(), home_file, "rapid switching final selection")
  end)

  check("explicit HOME root is honored for outside active file", function()
    edit(external_file)
    expect_tree(outside, external_file)
    paths.open(home, { action = "show" })
    expect_tree(home)
    drain()
    equal(state().path, home, "explicit root survives pending follow")
  end)

  check("new unwritten named file follows without attempting reveal", function()
    edit(missing_file)
    expect_tree(outside)
    equal(vim.fn.filereadable(missing_file), 0, "missing file remains unwritten")
    equal(api.nvim_get_current_win(), editor, "missing file preserves focus")
  end)

  check("help, terminal and tree browsing preserve the selected root", function()
    edit(home_file)
    expect_tree(home, home_file)
    api.nvim_set_current_win(state().winid)
    drain()
    equal(state().path, home, "tree browsing root")
    api.nvim_set_current_win(editor)
    api.nvim_set_current_buf(api.nvim_create_buf(false, true))
    vim.bo.buftype = "nofile"
    vim.bo.filetype = "TelescopePrompt"
    drain()
    equal(state().path, home, "picker root")
    api.nvim_set_current_buf(api.nvim_create_buf(false, true))
    vim.bo.buftype = "help"
    drain()
    equal(state().path, home, "help root")
    api.nvim_set_current_buf(api.nvim_create_buf(false, true))
    vim.fn.termopen({ "sh", "-c", "exit 0" })
    drain()
    equal(state().path, home, "terminal root")
    edit(home_file)
  end)

  check("split activation follows the active editor window", function()
    vim.cmd("vsplit")
    local split = api.nvim_get_current_win()
    edit(repo_file)
    expect_tree(repo, repo_file)
    equal(api.nvim_get_current_win(), split, "split follow preserves focus")
    api.nvim_set_current_win(editor)
    expect_tree(home, home_file)
    api.nvim_win_close(split, true)
  end)

  check("tab switching keeps filesystem states independent", function()
    local first_tab = api.nvim_get_current_tabpage()
    local first_state = state()
    vim.cmd("tabnew")
    local second_editor = api.nvim_get_current_win()
    edit(repo_file)
    paths.open(nil, { action = "show" })
    expect_tree(repo, repo_file)
    equal(api.nvim_get_current_win(), second_editor, "second tab focus")
    equal(first_state.path, home, "first tab root while inactive")
    api.nvim_set_current_tabpage(first_tab)
    expect_tree(home, home_file)
    equal(vim.fn.getcwd(), cwd, "tab follow preserves cwd")
  end)

  check("closed tree stays closed after file activation", function()
    close_tree()
    edit(external_file)
    drain()
    equal(renderer.window_exists(state()), false, "closed tree is not reopened")
    paths.open(nil, { action = "show" })
    expect_tree(outside, external_file)
    close_tree()
  end)

  check("closing a tree cancels pending follow effects", function()
    edit(home_file)
    paths.open(nil, { action = "show" })
    expect_tree(home, home_file)
    edit(external_file)
    close_tree()
    drain()
    equal(renderer.window_exists(state()), false, "pending follow does not reopen closed tree")
  end)

  check("repeated reopening has no stale-tree callback failures", function()
    for _, file in ipairs({ repo_file, home_file, external_file, repo_file }) do
      edit(file)
      paths.open(nil, { action = "show" })
      local root = file == repo_file and repo or file == home_file and home or outside
      expect_tree(root, file)
      drain()
      close_tree()
    end
    equal(api.nvim_get_current_win(), editor, "reopening preserves focus")
    equal(vim.fn.getcwd(), cwd, "reopening preserves cwd")
  end)

  if overlay_spec then
    check("actual overlay shortcuts compose with the provider", function()
      local shortcuts = {}
      for _, binding in ipairs(overlay_spec.keys) do
        shortcuts[binding[1]] = binding[2]
      end
      edit(external_file)
      shortcuts["<leader>fe"]()
      expect_tree(outside, external_file)
      shortcuts["<leader>fe"]()
      wait_for("overlay toggle closes tree", function()
        return not renderer.window_exists(state())
      end)
      api.nvim_set_current_win(editor)
      edit(repo_file)
      shortcuts["<leader>fE"]()
      expect_tree(repo, repo_file)
      api.nvim_set_current_win(editor)
      equal(vim.fn.getcwd(), cwd, "overlay shortcuts preserve cwd")
      close_tree()
    end)
  end
end

local ok, err = pcall(run)
if not ok then
  api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
