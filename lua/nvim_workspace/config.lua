local M = {}

local defaults = {
  -- Host configs know which roots are too expensive to scan locally. The plugin
  -- keeps that decision injectable so it can stay generic while still avoiding
  -- accidental HOME- or monorepo-scale fd/rg walks.
  large_root_detector = nil,
  shell = {},
  navigation = {},
}

local values = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
end

function M.get()
  return values
end

return M
