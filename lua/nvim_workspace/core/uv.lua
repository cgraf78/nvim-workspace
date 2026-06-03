-- Neovim renamed vim.loop to vim.uv in 0.10. Keep that version split behind
-- one module so workspace code can support the 0.9 package used by Ubuntu CI.
return vim.uv or vim.loop
