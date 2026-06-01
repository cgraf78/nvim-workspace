local M = {}

local defaults = {
  large_root_detector = nil,
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
