local config = require("typing.config")

local M = {}

--- Link every highlight group the plugin uses to its configured target.
--- Safe to call repeatedly; `default = true` means it won't clobber a group
--- the user (or their colorscheme) already set themselves. TypingKeyHint is
--- the exception: `hl.key_hint` is a literal hex color, not a link target,
--- so it's applied as an explicit fg instead (kept vivid regardless of
--- colorscheme; ctermfg covers terminals without termguicolors).
function M.setup()
  local hl = config.get().highlights
  vim.api.nvim_set_hl(0, "TypingPending", { link = hl.pending, default = true })
  vim.api.nvim_set_hl(0, "TypingCorrect", { link = hl.correct, default = true })
  vim.api.nvim_set_hl(0, "TypingIncorrect", { link = hl.incorrect, default = true })
  vim.api.nvim_set_hl(0, "TypingCursor", { link = hl.cursor, default = true })
  vim.api.nvim_set_hl(0, "TypingKeyHint", { fg = hl.key_hint, ctermfg = "Yellow", bold = true, default = true })
  vim.api.nvim_set_hl(0, "TypingLaser", { link = hl.laser, default = true })
  vim.api.nvim_set_hl(0, "TypingExplosion", { link = hl.explosion, default = true })
  vim.api.nvim_set_hl(0, "TypingBossActive", { link = hl.boss_active, default = true })
  vim.api.nvim_set_hl(0, "TypingBossInactive", { link = hl.boss_inactive, default = true })
  vim.api.nvim_set_hl(0, "TypingEnergy", { link = hl.energy, default = true })
end

return M
