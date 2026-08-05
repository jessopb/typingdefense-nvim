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
    energy = "String", -- the filled portion of the energy bar (defense and boss modes)
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
    -- curriculum stages (1..typing.curriculum.stage_count()) after which a
    -- boss fight kicks in, using that stage's keys as the fight's word
    -- pool; boss_stages[i] pairs with typing.ships.CAMPAIGN[i], so bosses
    -- show up small first and get progressively bigger/badder -- default is
    -- one boss per level for the first 4 levels, then every 2 levels after
    -- that. Set to {} to disable boss interludes entirely.
    boss_stages = { 1, 2, 3, 4, 6, 8, 10, 12, 14, 16 },
  },

  defense = {
    lives = 3,
    fall_interval_ms = 1000, -- how often the falling word drops one row, tuned for speed_reference_height
    -- (half speed of the original 500ms default -- doubling the interval halves the fall rate)
    speed_reference_height = 20, -- sky_height fall_interval_ms is tuned for; taller/shorter play areas
    -- scale the fall speed to compensate, so a word takes roughly the same
    -- real time to cross the screen regardless of terminal height
    laser_ms = 90, -- how long the turret beam stays on screen when a word is destroyed
    shot_ms = 70, -- how long a per-keystroke shot stays on screen (hit-aimed or miss-random);
    -- unlike laser_ms this never freezes play, so it can afford to be a touch snappier
    explosion_frames = 5, -- how many animation steps the ember spray plays for
    explosion_frame_ms = 45, -- delay between ember animation steps
    energy_max = 20, -- width (in bars) of the energy meter; +1.1 bars/hit, -1 bar/keypress
    -- (net +0.1/hit, -1/miss), floor-rounded for display, starts at 0
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
    shot_ms = 70, -- how long a per-keystroke shot stays on screen; see defense.shot_ms
    explosion_frames = 5,
    explosion_frame_ms = 45,
    energy_max = 20, -- see defense.energy_max
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
