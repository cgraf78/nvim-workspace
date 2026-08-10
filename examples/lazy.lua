-- Complete lazy.nvim plugin specification using only nvim-workspace's public API.
return {
  "cgraf78/nvim-workspace",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    local workspace = require("nvim_workspace")

    workspace.setup({
      session = {
        save_debounce_ms = 500,
      },
    })

    vim.keymap.set("n", "<C-p>", workspace.files, {
      desc = "Workspace files",
    })
    vim.keymap.set("n", "<C-S-f>", workspace.grep, {
      desc = "Workspace grep",
    })
  end,
}
