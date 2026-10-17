# AGENTS.md

## About

nvim-workspace is a standalone, Telescope-based Neovim plugin for workspace
navigation: recent-first file and grep pickers, root switching, Neo-tree,
session, LazyGit, shell-LSP, and navigation policy. It is host-neutral; the
consuming Neovim config supplies site-specific policy through `setup()`
callbacks.

## Layout

- `lua/nvim_workspace/init.lua`: the public top-level API.
- Public optional modules: `neo_tree`, `session`, `lazygit`, `shell`,
  `navigation` (all under `lua/nvim_workspace/`).
- `lua/nvim_workspace/core/` and `lua/nvim_workspace/picker/`: internal.
  Tests call them directly; host configs must not.
- `plugin/nvim-workspace.lua`: defines `:WorkspaceFiles` and `:WorkspaceGrep`.
- `doc/nvim-workspace.txt`: the `:help nvim-workspace-api` reference.
- `examples/`: copyable specs, executed by `tests/examples-test`.
- `tests/`: one `*-test` script per area, sharing `tests/helpers.sh`.

## Invariants

- A public API change updates `doc/nvim-workspace.txt` and the README's
  Public API list together.
- Stay host-neutral: no dot-, bare-repo-, or site-specific behavior built in.
  Add a callback hook instead (see `lua/nvim_workspace/config.lua`).
- The README's Setup snippet is `examples/lazy.lua` minus its header comment,
  and `tests/examples-test` asserts that file's dependencies, setup options,
  and mappings; change all three together.

## Testing

- `tests/run` is the local and CI entry point (`make test` is an alias).
- Requirements: `nvim` and `python3` (used by `helpers.sh` and several suites).
  The `rg` integration cases skip when `rg` is absent (no CI profile
  installs ripgrep, so most legs skip them), and the fd/rg runtime cases in
  `picker-test` skip under Neovim older than 0.10, which some distro legs
  ship. No suite needs `fd`.
- `tests/neo-tree-integration-test` runs only when neo-tree.nvim, nui.nvim,
  plenary.nvim, and nvim-web-devicons exist under
  `${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy` (or the
  `NVIM_WORKSPACE_TEST_PLUGIN_ROOT` and `NVIM_WORKSPACE_TEST_*_DIR`
  overrides). CI has none of them, so it skips there: run it locally after
  touching Neo-tree code.
- CI runs the shared shell matrix (macOS, CentOS Stream, Arch, Debian,
  Ubuntu, WSL, Fedora, Alpine) with profiles `base,lua,neovim,python`, and
  Termux with `base,neovim,python`. Termux has no standalone `lua` (lua54 and
  Neovim's lua51 conflict there), so tests must run Lua through `nvim`.
- `stylua --check lua plugin` and `selene lua` pass today but are not
  CI-gated; keep them clean.

## Test isolation

- `_nvim_lua` runs `nvim --headless --noplugin -u NONE -i NONE` with an
  explicit `package.path`; never load the developer's config or ShaDa.
- Scratch files go under `${TMPDIR:-/tmp}/nvim-workspace-tests`
  (`_tmpdir`). The Neo-tree integration test also points HOME and the XDG
  dirs at a temporary tree.

## CI and generated files

- CI's ShellCheck job fails on any shell program missing from
  `.github/shellcheck-files.txt` (untracked files included) and on stale
  rows; `tests/run` runs no ShellCheck. Before pushing, run
  `bash <actions checkout at $(cat .github/cgraf78-actions.lock)>/.github/actions/shellcheck-inventory/run.sh "$PWD" .github/shellcheck-files.txt`.
- `.github/cgraf78-actions.lock` and every `uses: cgraf78/actions/...@sha`
  move together, only via `consumer-ci/sync.sh <this checkout>` run from
  cgraf78/actions at the target SHA. The `cgraf78/actions sync` job checks
  them.
- `retry-infrastructure.yml` keys on the workflow name `Tests`; don't rename
  it.

## Release

None; users track `main`.
