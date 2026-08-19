if vim.g.loaded_pi_nvim == 1 then
  return
end
vim.g.loaded_pi_nvim = 1

require("pi-nvim").setup()
