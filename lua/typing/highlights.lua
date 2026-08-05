local config = require("typing.config")

local M = {}

--- Link every highlight group the plugin uses to its configured target.
--- Safe to call repeatedly; `default = true` means it won't clobber a group
--- the user (or their colorscheme) already set themselves.
function M.setup()
  local hl = config.get().highlights
  vim.api.nvim_set_hl(0, "TypingPending", { link = hl.pending, default = true })
  vim.api.nvim_set_hl(0, "TypingCorrect", { link = hl.correct, default = true })
  vim.api.nvim_set_hl(0, "TypingIncorrect", { link = hl.incorrect, default = true })
  vim.api.nvim_set_hl(0, "TypingCursor", { link = hl.cursor, default = true })
  vim.api.nvim_set_hl(0, "TypingKeyHint", { link = hl.key_hint, default = true })
  vim.api.nvim_set_hl(0, "TypingLaser", { link = hl.laser, default = true })
end

return M
