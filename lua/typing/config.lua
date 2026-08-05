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
    energy_max = 20, -- width (in bars) of the energy meter, and the full charge you start
    -- with; +1.1 bars/hit, -1 bar/keypress (net +0.1/hit, -1/miss), floor-rounded for
    -- display -- draining it to 0 ends the game, same as running out of lives
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

local function warn(fmt, ...)
  vim.notify(string.format("typing.nvim: " .. fmt, ...), vim.log.levels.WARN)
end

--- true for a nonempty, single-line, printable-ASCII (32-126) string -- the
--- only kind of word every mode's byte-oriented input/rendering can handle
--- (see the keyboard/game key mapping loops, which only bind those codes).
local function is_typable_word(w)
  if type(w) ~= "string" or #w == 0 then
    return false
  end
  for i = 1, #w do
    local b = w:byte(i)
    if b < 32 or b > 126 then
      return false
    end
  end
  return true
end

--- Filters a user-supplied word list down to typable strings, warning about
--- and dropping anything else. Falls back to the built-in list (returning
--- nil, same as "unset") if nothing usable survives.
local function sanitize_words(words)
  if words == nil then
    return nil
  end
  if type(words) ~= "table" or #words == 0 then
    warn("`words` must be a nonempty list of strings -- ignoring, using the built-in word list")
    return nil
  end
  local out, dropped = {}, 0
  for _, w in ipairs(words) do
    if is_typable_word(w) then
      out[#out + 1] = w
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    warn("`words` contained %d non-string, empty, multi-line, or non-ASCII entr%s -- dropped", dropped, dropped == 1 and "y" or "ies")
  end
  if #out == 0 then
    warn("`words` had no usable entries after validation -- using the built-in word list")
    return nil
  end
  return out
end

--- Clamps a config value to a positive integer >= `min`, warning and
--- falling back to `default` if it isn't a number at all.
local function positive_int(name, value, default, min)
  min = min or 1
  if type(value) ~= "number" then
    warn("`%s` must be a number -- using default %d", name, default)
    return default
  end
  local n = math.floor(value + 0.5)
  if n < min then
    warn("`%s` must be >= %d -- using default %d", name, min, default)
    return default
  end
  return n
end

local function valid_hex_color(s)
  return type(s) == "string" and s:match("^#%x%x%x%x%x%x$") ~= nil
end

local function checked_hex_color(name, value, default)
  if valid_hex_color(value) then
    return value
  end
  warn("`%s` must be a hex color like \"#rrggbb\" -- using default %s", name, default)
  return default
end

--- Validates and normalizes `options` in place: bad values are replaced
--- with their defaults (with a warning) rather than reaching Neovim/libuv
--- APIs or game-loop math unchecked. Configuration is normally local and
--- trusted, but a bad value here is a robustness/availability concern, not
--- just an inconvenience -- see the timer/energy/lives fields below, all of
--- which feed directly into libuv timers or math.random ranges.
local function validate(o, d)
  o.word_count = positive_int("word_count", o.word_count, d.word_count)
  o.words = sanitize_words(o.words)
  o.highlights.key_hint = checked_hex_color("highlights.key_hint", o.highlights.key_hint, d.highlights.key_hint)

  o.lesson.word_count = positive_int("lesson.word_count", o.lesson.word_count, d.lesson.word_count)
  local wl = o.lesson.word_length
  if type(wl) ~= "table" or type(wl[1]) ~= "number" or type(wl[2]) ~= "number" then
    warn("`lesson.word_length` must be { min, max } -- using default { %d, %d }", d.lesson.word_length[1], d.lesson.word_length[2])
    o.lesson.word_length = vim.deepcopy(d.lesson.word_length)
  else
    local lo = positive_int("lesson.word_length[1]", wl[1], d.lesson.word_length[1])
    local hi = positive_int("lesson.word_length[2]", wl[2], d.lesson.word_length[2])
    o.lesson.word_length = { lo, hi }
  end

  o.defense_learning.words_per_stage = positive_int("defense_learning.words_per_stage", o.defense_learning.words_per_stage, d.defense_learning.words_per_stage)
  local bs = o.defense_learning.boss_stages
  if type(bs) ~= "table" then
    warn("`defense_learning.boss_stages` must be a list of stage numbers -- using default")
    o.defense_learning.boss_stages = vim.deepcopy(d.defense_learning.boss_stages)
  else
    local out, dropped = {}, 0
    for _, s in ipairs(bs) do
      if type(s) == "number" and s >= 1 and s == math.floor(s) then
        out[#out + 1] = s
      else
        dropped = dropped + 1
      end
    end
    if dropped > 0 then
      warn("`defense_learning.boss_stages` contained %d invalid entr%s -- dropped", dropped, dropped == 1 and "y" or "ies")
    end
    o.defense_learning.boss_stages = out
  end

  for _, mode in ipairs({ "defense", "boss" }) do
    local c, dc = o[mode], d[mode]
    c.lives = positive_int(mode .. ".lives", c.lives, dc.lives)
    c.fall_interval_ms = positive_int(mode .. ".fall_interval_ms", c.fall_interval_ms, dc.fall_interval_ms, 10)
    c.speed_reference_height = positive_int(mode .. ".speed_reference_height", c.speed_reference_height, dc.speed_reference_height)
    c.laser_ms = positive_int(mode .. ".laser_ms", c.laser_ms, dc.laser_ms, 10)
    c.shot_ms = positive_int(mode .. ".shot_ms", c.shot_ms, dc.shot_ms, 10)
    c.explosion_frames = positive_int(mode .. ".explosion_frames", c.explosion_frames, dc.explosion_frames)
    c.explosion_frame_ms = positive_int(mode .. ".explosion_frame_ms", c.explosion_frame_ms, dc.explosion_frame_ms, 10)
    c.energy_max = positive_int(mode .. ".energy_max", c.energy_max, dc.energy_max)
  end
  o.boss.bomb_interval_ms = positive_int("boss.bomb_interval_ms", o.boss.bomb_interval_ms, d.boss.bomb_interval_ms, 10)

  o.defense.target.gray = checked_hex_color("defense.target.gray", o.defense.target.gray, d.defense.target.gray)
  o.defense.target.red = checked_hex_color("defense.target.red", o.defense.target.red, d.defense.target.red)
end

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  validate(options, defaults)
end

function M.get()
  return options
end

return M
