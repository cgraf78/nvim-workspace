# nvim-workspace

Workspace-aware navigation, search, explorer, and session policy for Neovim.

`nvim-workspace` provides a VS Code-like workspace navigation model while
staying Neovim-native: recent-first file search, workspace-wide grep, explicit
root switching, HOME/symlink-aware path display, optional Neo-tree integration,
session aliases for project roots, and safe behavior for large workspace roots.

## Features

- file picker that shows recent files immediately, then progressively merges
  live `fd` results
- grep picker that searches recent files first, then broader workspace roots
  with bounded `rg` arguments
- visible HOME alias handling, so symlinked project roots keep the spelling the
  user opened
- large-root policy hook for callers that need to suppress expensive scans
- extension sources for adding external file and grep backends
- optional Neo-tree helpers for matching picker root controls and visible
  symlink reveal behavior
- optional persistence.nvim helpers that keep launch-cwd and file-root sessions
  in sync
- optional LazyGit helpers that let host configs supply special-repo launch
  options while leaving normal repos on their own root
- optional shell-language workspace policy that keeps bashls and fallback
  shell navigation scoped away from broad HOME scans
- optional definition/navigation fallback that combines LSP, literal file
  references, shell symbols, and mouse routing behind one command surface

## Requirements

- Neovim 0.10+
- Telescope
- `fd` or `fdfind`
- `rg`

## Setup

```lua
require("nvim_workspace").setup({
  large_root_detector = function(root, opts)
    return false
  end,
  workspace = {
    repo_root_detector = function(start, opts)
      return nil
    end,
    home_workspace_detector = function(start, opts)
      return nil
    end,
  },
  lazygit = {
    opts_for_path = function(path, ctx)
      return nil
    end,
  },
  session = {
    save_debounce_ms = 500,
  },
})

vim.keymap.set("n", "<C-p>", function()
  require("nvim_workspace").files()
end)

vim.keymap.set("n", "<C-S-f>", function()
  require("nvim_workspace").grep()
end)
```

The plugin also registers:

```vim
:WorkspaceFiles [dir]
:WorkspaceGrep [dir]
```

## Public API

Public integrations should use only the top-level module:

- `setup(opts)` configures plugin behavior.
- `files(opts)` opens the file picker.
- `grep(opts)` opens the content picker.
- `register_file_source(source, opts)` adds a file picker backend.
- `register_grep_source(source, opts)` adds a grep picker backend.
- `default_root()`, `normalize(path)`, `canonical(path)`, `relative_path(root,
  path)`, `current_file_dir()`, and `current_buffer_dir()` expose workspace
  context without requiring internal modules.
- `current_file_repo_root()` returns the current file buffer's detected repo
  root, or nil for special buffers and files without a detected root.
- `repo_root(start)` returns a usable workspace root, falling back to the
  normalized start directory when no repo is detected.
- `path_query_terms(prompt)` and `unordered_path_regex(prompt)` expose the same
  query parsing the built-in file picker uses for extension sources.

Optional integration modules are public:

- `require("nvim_workspace.neo_tree")` for Neo-tree root/reveal policy.
- `require("nvim_workspace.session")` for persistence.nvim session policy.
- `require("nvim_workspace.lazygit")` for LazyGit cwd/argument policy.
- `require("nvim_workspace.shell")` for shell language-server root policy.
- `require("nvim_workspace.navigation")` for definition/follow fallback policy.

Modules under `nvim_workspace.core` and `nvim_workspace.picker` are internal
implementation modules. They are tested directly, but host configs should not
depend on them.

This README documents the common integration surface. For the complete public
API reference, use `:help nvim-workspace-api`.

## Neo-tree

```lua
local tree = require("nvim_workspace.neo_tree")

tree.setup_manager_patch()

require("neo-tree").setup({
  filesystem = {
    follow_current_file = { enabled = true },
    filtered_items = tree.filesystem_policy().filtered_items,
    window = {
      mappings = tree.filesystem_mappings(),
    },
  },
})
```

Use `tree.open(nil, { toggle = true })` for a broad HOME explorer and
`tree.open(tree.context_root(), { action = "focus" })` for a workspace-root
explorer.

## Sessions

```lua
local session = require("nvim_workspace.session")

session.setup({
  save_debounce_ms = 500,
})
```

When using persistence.nvim, call `persistence.stop()` after setup if you want
`nvim-workspace` to own quit-time saves and write file-root aliases together
with the launch-cwd session.

## LazyGit

```lua
local lazygit = require("nvim_workspace.lazygit")

vim.keymap.set("n", "<leader>gg", function()
  lazygit.open_with_snacks()
end)
```

Use `lazygit.opts()` when integrating with a different launcher. Dot-tracked
or bare-repo behavior is not built in; provide `setup({ lazygit = {
opts_for_path = ... } })` when a host config needs special launcher arguments.
The callback receives `(path, ctx)`, where `ctx.default_root` is the broad
workspace root and `ctx.relative_to_default_root(path)` returns the path spelling
relative to that root. Other files use their normal VCS root or local editing
context.

## Shell Workspaces

```lua
local shell = require("nvim_workspace.shell")

require("lspconfig").bashls.setup({
  before_init = shell.before_init,
  root_dir = shell.root_dir,
  root_markers = nil,
})
```

Use `setup({ shell = ... })` to add HOME-scoped shell paths without turning all
of HOME into a language-server workspace:

```lua
require("nvim_workspace").setup({
  shell = {
    home_globs = { ".local/bin/agent-hook-*" },
    home_dirs = {
      { prefix = ".config/shell/", glob = ".config/shell/**/*@(.sh|.bash)" },
      { prefix = ".local/bin/", direct = true },
    },
    overlay = { enabled = true, root_prefix = ".workspace-" },
  },
})
```

## Navigation

```lua
local navigation = require("nvim_workspace.navigation")

vim.keymap.set("n", "gd", navigation.follow)
vim.keymap.set("n", "<C-LeftMouse>", navigation.goto_mouse)
```

`navigation.follow()` is an alias for `navigation["goto"]()` and asks LSP for a
definition first, then falls back to literal file references and shell-symbol
lookup when useful. Shell-like filetypes check literal paths before LSP because
quoted paths are common and shell LSP coverage is uneven.

Use `setup({ navigation = ... })` to adjust the generic policy:

```lua
require("nvim_workspace").setup({
  navigation = {
    path_first_filetypes = { "bash", "sh", "zsh" },
    shell_filetypes = { "bash", "sh", "zsh" },
    shell_module = "nvim_workspace.shell",
    prefer_shell_for_home_paths = true,
  },
})
```

## Extension Sources

Additional sources can stream results into the built-in pickers:

```lua
require("nvim_workspace").register_file_source(function(prompt, done, root, ctx)
  ctx.status("Index search: running")
  done({ root .. "/README.md" })
end, { name = "Index search" })
```

Grep sources receive the same callback shape, but should return ripgrep
`--vimgrep` style lines. Sources may call `done(results, { partial = true })`
for streaming chunks and must eventually call `done(results)` once. Returning a
function or handle with `cancel()`/`kill()` lets the picker stop stale work when
the prompt changes or closes.

## Tests

```bash
tests/run
```

`make test` is also available as a local convenience wrapper.

The test suite is intentionally derived from the original dotfiles Neovim tests
so behavior stays stable across the extraction.
