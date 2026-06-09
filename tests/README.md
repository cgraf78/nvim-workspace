# Tests

`tests/run` is the local and CI entrypoint. Each focused `*-test` file exercises
one plugin area with shell-driven Neovim/Lua fixtures.

## Suite Scope

- `api-test` covers the public Lua API.
- `workspace-test` and `recent-test` cover core workspace state.
- `picker-test`, `navigation-test`, `session-test`, `shell-test`,
  `lazygit-test`, and `neo-tree-test` cover integrations.

Keep tests independent of the developer's real Neovim config. Use explicit
runtime paths, temporary workspaces, and fixture repositories when a case needs
project state.
