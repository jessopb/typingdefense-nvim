local M = {}

local defaults = {
  -- number of words for :TypingWords when no count is given
  word_count = 25,
  -- override the built-in word list, e.g. { "foo", "bar" }
  words = nil,

  -- highlight groups are linked (not overridden) to these targets at setup time,
  -- so users can `:hi TypingCorrect ...` themselves and it will stick. The
  -- lone exception is key_hint, a literal hex color rather than a link
  -- target -- it stays vivid regardless of colorscheme.
  highlights = {
    pending = "Comment",
    correct = "String",
    incorrect = "ErrorMsg",
    cursor = "CursorLine",
    key_hint = "#ffff00", -- the relocated finger-outline in the keyboard hint diagram (bright yellow)
    laser = "Special", -- the turret beam (defense and boss modes)
    explosion = "DiagnosticWarn", -- the word/zone-destroyed flash and embers
    boss_active = "Todo", -- the boss mode's currently-typeable ship zone
    boss_inactive = "Comment", -- boss mode zones that aren't active yet, or are destroyed
  },

  lesson = {
    -- default stage used by :TypingLesson when no stage number is given
    stage = 1,
    word_count = 30,
    word_length = { 2, 5 },
  },

  defense_learning = {
    -- default stage used by :TypingDefenseLearning when no stage number is given
    stage = 1,
    -- words cleared before auto-advancing to the next curriculum stage;
    -- stays on the last stage once reached
    words_per_stage = 40,
  },

  defense = {
    lives = 3,
    fall_interval_ms = 1000, -- how often the falling word drops one row, tuned for speed_reference_height
    -- (half speed of the original 500ms default -- doubling the interval halves the fall rate)
    speed_reference_height = 20, -- sky_height fall_interval_ms is tuned for; taller/shorter play areas
    -- scale the fall speed to compensate, so a word takes roughly the same
    -- real time to cross the screen regardless of terminal height
    laser_ms = 90, -- how long the turret beam stays on screen when a word is destroyed
    explosion_frames = 5, -- how many animation steps the ember spray plays for
    explosion_frame_ms = 45, -- delay between ember animation steps
    target = {
      -- the targeting-square corners fade from `gray` to `red` as the
      -- current word goes from untyped to fully typed
      gray = "#585858",
      red = "#ff3333",
    },
  },

  boss = {
    lives = 3,
    ship = "cruiser", -- which typing.ships registry entry :TypingBoss uses by default
    fall_interval_ms = 500, -- bomb fall speed, tuned for speed_reference_height (see defense above)
    speed_reference_height = 20,
    laser_ms = 90,
    explosion_frames = 5,
    explosion_frame_ms = 45,
    bomb_interval_ms = 9000, -- how often the ship launches a 2-bomb wave
  },
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return options
end

return M
