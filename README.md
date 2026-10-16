# nvim-workspace

![Tests](https://github.com/cgraf78/nvim-workspace/actions/workflows/test.yml/badge.svg?branch=main)

Workspace-aware navigation, search, explorer, and session policy for Neovim.

`nvim-workspace` provides a VS Code-like workspace navigation model while
staying Neovim-native: recent-first file search, workspace-wide grep, explicit
root switching, HOME/symlink-aware path display, optional Neo-tree integration,
session aliases for project roots, and safe behavior for large workspace roots.

It is built on Telescope. Its recent list is ordered by recency (files
visited this session, then its own list from earlier sessions, then Neovim's
`v:oldfiles`), not by a frecency score like telescope-frecency's. Unlike
project.nvim, it does not move your working directory to a detected project
root; you switch picker roots explicitly instead. If your config already
standardizes on snacks.picker or fzf-lua, this adds a second picker stack.

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
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) and
  [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `fd` or `fdfind` for the file picker
- `rg` for the grep picker and shell-symbol navigation

## Setup

With [lazy.nvim](https://github.com/folke/lazy.nvim), add this spec to your
plugins directory. It is [`examples/lazy.lua`](examples/lazy.lua), which the
test suite loads:

```lua
return {
  "cgraf78/nvim-workspace",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    local workspace = require("nvim_workspace")

    workspace.setup({
      session = {
        save_debounce_ms = 500,
      },
    })

    vim.keymap.set("n", "<C-p>", workspace.files, {
      desc = "Workspace files",
    })
    vim.keymap.set("n", "<C-S-f>", workspace.grep, {
      desc = "Workspace grep",
    })
  end,
}
```

The plugin also registers:

```vim
:WorkspaceFiles [dir]
:WorkspaceGrep [dir]
```

### Configuration hooks

Every `setup()` option is optional. Host configs inject policy through
callbacks; this block shows each hook's signature with a no-op return value:

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
    bind_to_cwd = false,
    -- The workspace helper owns following, including root transitions.
    follow_current_file = { enabled = false },
    filtered_items = tree.filesystem_policy().filtered_items,
    window = {
      mappings = tree.filesystem_mappings(),
    },
  },
})
```

Use `tree.open(nil, { toggle = true })` for an explorer that follows the active
file without narrowing an existing containing root. It starts at HOME for files
in HOME's visible tree, a VCS root for external projects, or the parent directory
for standalone external files. A visible sidebar switches scope only when a real
file outside its root becomes active; special buffers and tree browsing preserve
its context. Each tab keeps its own context, and a closed sidebar stays closed.

Use `tree.open(tree.context_root(), { action = "focus" })` for a workspace-root
explorer, or pass an explicit directory such as `vim.env.HOME`. Explicit roots
are honored immediately and remain until an outside file becomes active.
`{ reveal = false }` suppresses revealing the current file. Named new files select
a root from their existing parent but are revealed only after they exist.
Keep `filesystem.bind_to_cwd = false` so following never changes the editor's
working directory.

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

[`examples/file-source.lua`](examples/file-source.lua) is a tested, host-neutral
implementation showing partial results, final completion, status reporting, and
cancellation together.

## Tests

```bash
tests/run
```

`make test` is also available as a local convenience wrapper.

nvim-workspace is used in
[dotfiles-nvim](https://github.com/cgraf78/dotfiles-nvim).
