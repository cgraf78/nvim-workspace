# Lua Modules

This directory owns the runtime implementation for the `nvim-workspace` plugin.
`init.lua` is the public Lua entrypoint; other modules are internal unless the
root README documents them as supported integration points.

## Areas

- `config.lua` normalizes user options.
- `core/` owns workspace detection, list/recent state, LSP integration, and
  libuv wrappers.
- `picker/` owns picker-agnostic file, grep, and scope behavior.
- `navigation.lua`, `session.lua`, `shell.lua`, `lazygit.lua`, and
  `neo_tree.lua` provide focused integrations over the core workspace model.

Keep durable workspace semantics in `core/` and let integrations compose those
helpers. Avoid making picker, file-browser, or shell integrations rediscover
workspace roots independently.
