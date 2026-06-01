if vim.g.loaded_nvim_workspace == 1 then
  return
end
vim.g.loaded_nvim_workspace = 1

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
