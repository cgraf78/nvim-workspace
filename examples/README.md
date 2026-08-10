# Examples

The examples are loaded in headless Neovim by `tests/examples-test`; they are
copyable public contracts rather than unverified snippets.

- `lazy.lua` is a complete lazy.nvim specification with required dependencies,
  setup, and file/grep mappings.
- `file-source.lua` demonstrates the extension-source lifecycle: query parsing,
  status updates, partial results, mandatory completion, and cancellation.

The file source intentionally uses a caller-supplied in-memory path list so it
has no private index or repository dependency. An integration can replace that
list with an asynchronous index query while preserving the callback contract.

```lua
local source = dofile("/path/to/nvim-workspace/examples/file-source.lua")
source.register({
  name = "Generated files",
  paths = {
    "build/api.lua",
    "build/schema.lua",
  },
})
```

Host-specific root policy, special repositories, and index commands belong in
the consuming Neovim configuration rather than this reusable plugin.
