# nvim-workspace

Workspace-aware file and content search for Neovim.

`nvim-workspace` provides a VS Code-like workspace navigation model while
staying Neovim-native: recent-first file search, workspace-wide grep, explicit
root switching, HOME/symlink-aware path display, and safe behavior for large
workspace roots.

## Features

- file picker that shows recent files immediately, then progressively merges
  live `fd` results
- grep picker that searches recent files first, then broader workspace roots
  with bounded `rg` arguments
- visible HOME alias handling, so symlinked project roots keep the spelling the
  user opened
- large-root policy hook for callers that need to suppress expensive scans
- extension sources for adding external file and grep backends

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

## Extension Sources

Additional sources can stream results into the built-in pickers:

```lua
require("nvim_workspace").register_file_source(function(prompt, done, root, ctx)
  ctx.status("Index search: running")
  done({ root .. "/README.md" })
end, { name = "Index search" })
```

Grep sources receive the same callback shape, but should return ripgrep
`--vimgrep` style lines.

## Tests

```bash
make test
```

The test suite is intentionally derived from the original dotfiles Neovim tests
so behavior stays stable across the extraction.
