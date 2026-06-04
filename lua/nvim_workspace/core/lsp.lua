local M = {}

function M.get_clients(opts)
  if vim.lsp and type(vim.lsp.get_clients) == "function" then
    return vim.lsp.get_clients(opts)
  end

  if vim.lsp and type(vim.lsp.get_active_clients) == "function" then
    return vim.lsp.get_active_clients(opts)
  end

  return {}
end

return M
