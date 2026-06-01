if vim.g.loaded_nvim_workspace == 1 then
  return
end
vim.g.loaded_nvim_workspace = 1

-- Commands are intentionally tiny shims over the Lua API. Plugin managers can
-- still configure keys and opts through setup(), while ad-hoc command use gets
-- the same root normalization path as programmatic callers.
vim.api.nvim_create_user_command("WorkspaceFiles", function(opts)
  local root = opts.args ~= "" and opts.args or nil
  require("nvim_workspace").files({ root = root })
end, {
  nargs = "?",
  complete = "dir",
})

vim.api.nvim_create_user_command("WorkspaceGrep", function(opts)
  local root = opts.args ~= "" and opts.args or nil
  require("nvim_workspace").grep({ root = root })
end, {
  nargs = "?",
  complete = "dir",
})
