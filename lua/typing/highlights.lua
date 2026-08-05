local config = require("typing.config")

local M = {}

--- Remembers exactly what M.setup() itself last applied to each group, so a
--- later setup() call (e.g. a second require("typing").setup() with
--- different highlight options) can tell "still what I set last time" --
--- safe to redefine -- apart from "the user (or their colorscheme)
--- customized this since" -- leave it alone. Without this, `default = true`
--- alone means the group stays defined from the *first* setup() call
--- forever: it won't clobber a user override, but it also won't pick up the
--- plugin's own later config changes.
local applied = {}

local function set(group, def)
  local before = vim.api.nvim_get_hl(0, { name = group })
  if applied[group] ~= nil and vim.deep_equal(before, applied[group]) then
    -- still exactly what we set last time -- safe to redefine outright.
    -- `default = true` would refuse to touch a group that already has *any*
    -- definition, so a plain, unconditional set is the only way our own
    -- later setup() call can actually pick up new config here.
    vim.api.nvim_set_hl(0, group, def)
  else
    -- first call (nothing has defined this group yet, so `default = true`
    -- only takes if a colorscheme or the user's own config got there
    -- first), or the user/colorscheme changed it since we last set it --
    -- either way, leave any existing definition alone.
    vim.api.nvim_set_hl(0, group, vim.tbl_extend("force", { default = true }, def))
  end
  applied[group] = vim.api.nvim_get_hl(0, { name = group })
end

--- Link every highlight group the plugin uses to its configured target.
--- Safe to call repeatedly, including across setup() calls with different
--- highlight options -- see `applied`/`set` above. TypingKeyHint is the
--- exception: `hl.key_hint` is a literal hex color, not a link target, so
--- it's applied as an explicit fg instead (kept vivid regardless of
--- colorscheme; ctermfg covers terminals without termguicolors).
function M.setup()
  local hl = config.get().highlights
  set("TypingPending", { link = hl.pending })
  set("TypingCorrect", { link = hl.correct })
  set("TypingIncorrect", { link = hl.incorrect })
  set("TypingCursor", { link = hl.cursor })
  set("TypingKeyHint", { fg = hl.key_hint, ctermfg = "Yellow", bold = true })
  set("TypingLaser", { link = hl.laser })
  set("TypingExplosion", { link = hl.explosion })
  set("TypingBossActive", { link = hl.boss_active })
  set("TypingBossInactive", { link = hl.boss_inactive })
  set("TypingEnergy", { link = hl.energy })
end

return M
