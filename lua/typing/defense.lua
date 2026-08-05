local config = require("typing.config")
local words = require("typing.words")
local keyboard = require("typing.keyboard")
local highlights = require("typing.highlights")
local effects = require("typing.effects")

local M = {}

local ns = vim.api.nvim_create_namespace("typing.nvim.defense")

local state = {
  active = false,
  finished = false,
  session = 0, -- bumped every M.start(); lets a callback scheduled by an old
  -- session (e.g. fire_laser's uncancellable vim.defer_fn) detect that a
  -- new game has since started and no-op instead of acting on stale
  -- row/col data -- see fire_laser below
  bufnr = nil,
  winid = nil,
  prev_bufnr = nil,
  prev_winid = nil,
  timer = nil,

  word = "",
  typed_len = 0,
  row = 0, -- 0-indexed row within the sky, increments each tick
  col = 0,

  width = 80,
  sky_height = 10,
  keyboard_start = 0, -- 0-idx buffer line the keyboard diagram starts on

  base_col = 0, -- 0-idx column of the turret, centered on the skyline
  laser = nil, -- { row, col } target cell while the word-destroying "kill shot" beam is
  -- firing, else nil -- freezes tick()/handle_char() until it (and the explosion after
  -- it) resolves, same as before
  explosion = nil, -- { row, col, frame, max_frames } while the ember spray is animating
  explosion_timer = nil,
  shot = nil, -- { row, col } target cell for the lightweight per-keystroke beam fired on
  -- every hit (aimed at the word) or miss (aimed at effects.random_point) -- purely
  -- visual, never freezes play; see fire_shot()
  energy = 0, -- float energy level (see effects.energy_delta); floor-rounded for display;
  -- starts at energy_max (M.start resets it) and reaching 0 ends the game (handle_char)

  pool_override = nil, -- word list to fall back to instead of config.words/words.list
  label = nil, -- optional prefix shown in the status line (e.g. a learning-mode stage name)
  on_cleared = nil, -- optional fn(score) -> {word_pool=,label=,level=}|nil, called before each new word
  -- spawns; lets a caller swap the pool/label/level mid-game (e.g. learning mode
  -- advancing to the next curriculum stage every N words)

  score = 0,
  misses = 0,
  lives = 3,

  level = nil, -- current curriculum-stage number in leveled (learning) mode; nil elsewhere, which
  -- disables points tracking/display entirely
  level_correct = 0, -- correct keystrokes typed so far within the current level
  level_incorrect = 0, -- incorrect keystrokes typed so far within the current level
  points = 0, -- total points banked from levels completed (or ended) so far
}

--- Points banked for a level: a base value that scales with the level
--- number (so later, harder stages are worth more) scaled down by that
--- level's keystroke accuracy (so sloppy typing earns less). e.g. level 1
--- at 80% accuracy = 100 * 0.80 = 80 points; level 2 at 75% = 200 * 0.75 =
--- 150 points.
local function level_points(level, correct, incorrect)
  local total = correct + incorrect
  local accuracy = total > 0 and (correct / total) or 1
  return math.floor(level * 100 * accuracy + 0.5)
end

--- Banks the current level's points into state.points and resets the
--- per-level keystroke counters, ready for the next level (or for display
--- once the game ends).
local function bank_level_points()
  if not state.level then
    return
  end
  state.points = state.points + level_points(state.level, state.level_correct, state.level_incorrect)
  state.level_correct = 0
  state.level_incorrect = 0
end

local BASE_GLYPH = effects.BASE_GLYPH
local LASER_CHAR = effects.LASER_CHAR
local EMBER_CHAR = effects.EMBER_CHAR
local TARGET_CHAR = effects.TARGET_CHAR
local EMBERS = effects.EMBERS

--- Interpolated color for the targeting-square corners: `t` is how far
--- through the current word (0 = untouched, 1 = fully typed).
local function target_color(t)
  local cfg = config.get().defense.target
  return effects.lerp_color(cfg.gray, cfg.red, t)
end

local function word_pool()
  if state.pool_override then
    return state.pool_override
  end
  local cfg = config.get()
  return cfg.words or words.list
end

local function spawn_word()
  local pool = word_pool()
  state.word = pool[math.random(#pool)]
  state.typed_len = 0
  state.row = 0
  local max_col = math.max(state.width - #state.word, 0)
  state.col = math.random(0, max_col)
end

local build_skyline = effects.build_skyline
local set_col = effects.set_col
local laser_cells = effects.laser_cells

--- Cells for a beam from the turret to `target` {row,col}, clipped to the
--- sky and skipping the target's own row -- that row already shows the
--- word itself (typed/pending or, mid-explosion, TypingExplosion), so
--- drawing a beam glyph over it would clash. Shared by both the kill-shot
--- beam (`state.laser`) and the lightweight per-keystroke beam (`state.shot`).
local function beam_cells(target)
  local pts = {}
  for _, pt in ipairs(laser_cells(state.sky_height, state.base_col, target.row, target.col)) do
    if pt.row >= 0 and pt.row < state.sky_height and pt.row ~= target.row and pt.col >= 0 and pt.col < state.width then
      pts[#pts + 1] = pt
    end
  end
  return pts
end

--- The four corners of a bounding box just outside the current word, one
--- row above and one below. Skipped once the word is destroyed (`laser`/
--- `explosion` active) since there's nothing left to target.
local function target_corners()
  local row_above, row_below = state.row - 1, state.row + 1
  local col_left, col_right = state.col - 1, state.col + #state.word
  local pts = {}
  if row_above >= 0 then
    if col_left >= 0 then
      pts[#pts + 1] = { row = row_above, col = col_left }
    end
    if col_right < state.width then
      pts[#pts + 1] = { row = row_above, col = col_right }
    end
  end
  if row_below < state.sky_height then
    if col_left >= 0 then
      pts[#pts + 1] = { row = row_below, col = col_left }
    end
    if col_right < state.width then
      pts[#pts + 1] = { row = row_below, col = col_right }
    end
  end
  return pts
end

--- Current positions of the 5 embers for `state.explosion`'s frame.
local function explosion_points()
  local pts = {}
  for _, e in ipairs(EMBERS) do
    local row_offset, col_offset = effects.ember_offset(e.h, state.explosion.frame)
    local row = state.explosion.row + row_offset
    local col = state.explosion.col + col_offset
    if row >= 0 and row < state.sky_height and col >= 0 and col < state.width then
      pts[#pts + 1] = { row = row, col = col }
    end
  end
  return pts
end

local function status_line()
  local prefix = state.label and (state.label .. "   ") or ""
  -- live total: points already banked from completed levels, plus what the
  -- current in-progress level would bank right now at its accuracy so far
  -- -- keeps the bar moving every keystroke instead of sitting at the last
  -- banked value until the level actually completes.
  local points = state.level
      and string.format(
        "Points: %d   ",
        state.points + level_points(state.level, state.level_correct, state.level_incorrect)
      )
    or ""
  return string.format(
    "%s%sScore: %d   Lives: %s   Misses: %d   [type the falling word -- <Esc> to quit]",
    prefix,
    points,
    state.score,
    string.rep("#", math.max(state.lives, 0)),
    state.misses
  )
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function finish(reason)
  state.finished = true
  stop_timer()
  bank_level_points()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  vim.bo[state.bufnr].modifiable = true
  local lines = {
    "",
    "  " .. (reason or "The city has fallen!"),
    "",
    string.format("  Words cleared: %d", state.score),
    string.format("  Misses:        %d", state.misses),
  }
  if state.level then
    lines[#lines + 1] = string.format("  Points:        %d", state.points)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Press <CR>, q, or <Esc> to continue..."
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function()
    M.stop()
  end, opts)
  vim.keymap.set("n", "q", function()
    M.stop()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.stop()
  end, opts)
end

local function lose_life()
  state.lives = state.lives - 1
  if state.lives <= 0 then
    finish()
  else
    spawn_word()
  end
end

local function render()
  if not state.active or state.finished then
    return
  end
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local kb_hint = nil
  if state.typed_len < #state.word then
    kb_hint = { at = state.word:sub(state.typed_len + 1, state.typed_len + 1):upper() }
  end
  local kb_lines, kb_cells = keyboard.render({ hint = kb_hint, window_width = state.width })

  local lines = { status_line() }
  for row = 0, state.sky_height - 1 do
    if row == state.row then
      lines[#lines + 1] = string.rep(" ", state.col) .. state.word
    else
      lines[#lines + 1] = ""
    end
  end

  local corners = nil
  if not state.laser and not state.explosion then
    corners = target_corners()
    for _, c in ipairs(corners) do
      local idx = c.row + 2
      lines[idx] = set_col(lines[idx], c.col, TARGET_CHAR)
    end
  end

  if state.laser then
    for _, pt in ipairs(beam_cells(state.laser)) do
      local idx = pt.row + 2
      lines[idx] = set_col(lines[idx], pt.col, LASER_CHAR)
    end
  end
  if state.shot then
    for _, pt in ipairs(beam_cells(state.shot)) do
      local idx = pt.row + 2
      lines[idx] = set_col(lines[idx], pt.col, LASER_CHAR)
    end
  end

  local embers = nil
  if state.explosion then
    embers = explosion_points()
    for _, p in ipairs(embers) do
      local idx = p.row + 2
      lines[idx] = set_col(lines[idx], p.col, EMBER_CHAR)
    end
  end

  lines[#lines + 1] = set_col(build_skyline(state.width), math.max(state.base_col - 1, 0), BASE_GLYPH)
  local energy_line, energy_fill_start, energy_fill_end =
    effects.energy_bar(state.energy, config.get().defense.energy_max)
  lines[#lines + 1] = energy_line
  lines[#lines + 1] = ""
  for _, l in ipairs(kb_lines) do
    lines[#lines + 1] = l
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  local word_line = 1 + state.row
  if state.typed_len > 0 then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, word_line, state.col, {
      end_col = state.col + state.typed_len,
      hl_group = state.explosion and "TypingExplosion" or "TypingCorrect",
      priority = 200,
    })
  end
  if corners and #corners > 0 then
    local progress = #state.word > 0 and (state.typed_len / #state.word) or 0
    vim.api.nvim_set_hl(0, "TypingTarget", { fg = target_color(progress) })
    for _, c in ipairs(corners) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, c.row + 1, c.col, {
        end_col = c.col + 1,
        hl_group = "TypingTarget",
        priority = 220,
      })
    end
  end
  if embers then
    for _, p in ipairs(embers) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, p.row + 1, p.col, {
        end_col = p.col + 1,
        hl_group = "TypingExplosion",
        priority = 260,
      })
    end
  end
  if state.typed_len < #state.word then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, word_line, state.col + state.typed_len, {
      end_col = state.col + #state.word,
      hl_group = "TypingPending",
      priority = 200,
    })
  end

  local base_start = math.max(state.base_col - 1, 0)
  vim.api.nvim_buf_set_extmark(state.bufnr, ns, state.sky_height + 1, base_start, {
    end_col = base_start + #BASE_GLYPH,
    hl_group = "TypingLaser",
    priority = 250,
  })
  if state.laser then
    for _, pt in ipairs(beam_cells(state.laser)) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, pt.row + 1, pt.col, {
        end_col = pt.col + 1,
        hl_group = "TypingLaser",
        priority = 250,
      })
    end
  end
  if state.shot then
    for _, pt in ipairs(beam_cells(state.shot)) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, pt.row + 1, pt.col, {
        end_col = pt.col + 1,
        hl_group = "TypingLaser",
        priority = 250,
      })
    end
  end
  if energy_fill_end > energy_fill_start then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, state.sky_height + 2, energy_fill_start, {
      end_col = energy_fill_end,
      hl_group = "TypingEnergy",
      priority = 200,
    })
  end

  keyboard.apply_highlights(state.bufnr, kb_cells, state.keyboard_start)
end

local function stop_explosion_timer()
  if state.explosion_timer then
    state.explosion_timer:stop()
    state.explosion_timer:close()
    state.explosion_timer = nil
  end
end

--- Cancels timers and clears volatile state without touching the
--- buffer/window -- shared by M.stop() and by the BufWipeout/WinClosed
--- autocmds registered in M.start(), which fire when the owned buffer or
--- window disappeared out from under us (closed by another command/plugin)
--- rather than through our own M.stop(). In that case there's nothing sane
--- left to restore into, so this just stops the game instead of leaving
--- `active` stuck true with timers still firing against an invalid buffer.
local function force_stop()
  if not state.active then
    return
  end
  state.active = false
  state.finished = false
  stop_timer()
  stop_explosion_timer()
  state.laser = nil
  state.explosion = nil
  state.shot = nil
  state.bufnr = nil
  state.winid = nil
end

--- Play the ember spray at a just-destroyed word's center cell, advancing
--- one frame every `explosion_frame_ms`; spawns the next word once the
--- animation finishes.
local function start_explosion(row, col)
  local cfg = config.get().defense
  state.explosion = { row = row, col = col, frame = 0, max_frames = cfg.explosion_frames }
  render()
  state.explosion_timer = vim.loop.new_timer()
  state.explosion_timer:start(
    cfg.explosion_frame_ms,
    cfg.explosion_frame_ms,
    vim.schedule_wrap(function()
      if not state.explosion then
        return
      end
      state.explosion.frame = state.explosion.frame + 1
      if state.explosion.frame > state.explosion.max_frames then
        stop_explosion_timer()
        state.explosion = nil
        if state.active and not state.finished then
          if state.on_cleared then
            local update = state.on_cleared(state.score)
            if update then
              state.pool_override = update.word_pool or state.pool_override
              state.label = update.label or state.label
              if update.level and update.level ~= state.level then
                bank_level_points()
                state.level = update.level
              end
            end
          end
          spawn_word()
          render()
        end
        return
      end
      render()
    end)
  )
end

--- Fire the turret at a just-destroyed word's center cell: paints a beam
--- from the base to the target for `laser_ms`, then triggers the ember
--- explosion. Falling and input are frozen throughout (see the
--- `state.laser`/`state.explosion` guards in `tick`/`handle_char`) so the
--- dead word doesn't drift or eat keystrokes while the effect plays.
--- Captures the current session so that if a game is stopped and a new one
--- started within `laser_ms` of this being scheduled, the stale callback
--- recognizes it no longer belongs to the active session and no-ops instead
--- of firing with the old game's row/col against the new one.
local function fire_laser(row, col)
  state.laser = { row = row, col = col }
  local cfg = config.get().defense
  local session = state.session
  vim.defer_fn(function()
    if not state.active or state.finished or state.session ~= session then
      return
    end
    state.laser = nil
    start_explosion(row, col)
  end, cfg.laser_ms)
end

--- Fire a lightweight beam at (row,col) for every keystroke that doesn't
--- destroy the word -- a hit-in-progress aims at the word itself, a miss
--- goes to a random cell (see handle_char). Purely visual: unlike
--- fire_laser, it never freezes tick()/handle_char(), so keystrokes keep
--- landing at full speed while these flash on screen. Self-clears via
--- table identity rather than the active/finished guard fire_laser uses --
--- a stale timer from a stopped/restarted game just finds state.shot is no
--- longer (or not yet) its own table and no-ops, so this sidesteps the
--- restart race documented on fire_laser above.
local function fire_shot(row, col)
  local shot = { row = row, col = col }
  state.shot = shot
  vim.defer_fn(function()
    if state.shot == shot then
      state.shot = nil
      render()
    end
  end, config.get().defense.shot_ms)
end

local function tick()
  if not state.active or state.finished or state.laser or state.explosion then
    return
  end
  state.row = state.row + 1
  if state.row >= state.sky_height then
    lose_life()
  end
  render()
end

local function handle_char(char)
  if not state.active or state.finished or state.laser or state.explosion then
    return
  end
  local expected = state.word:sub(state.typed_len + 1, state.typed_len + 1)
  local hit = char == expected
  local cfg = config.get().defense
  state.energy = effects.clamp(state.energy + effects.energy_delta(hit), 0, cfg.energy_max)

  if hit then
    state.typed_len = state.typed_len + 1
    if state.level then
      state.level_correct = state.level_correct + 1
    end
    local target_col = state.col + math.floor(#state.word / 2)
    if state.typed_len >= #state.word then
      state.score = state.score + 1
      fire_laser(state.row, target_col)
    else
      fire_shot(state.row, target_col)
    end
  else
    state.misses = state.misses + 1
    if state.level then
      state.level_incorrect = state.level_incorrect + 1
    end
    local p = effects.random_point(state.sky_height, state.width)
    fire_shot(p.row, p.col)
  end

  if state.energy <= 0 then
    render()
    finish("The turret runs out of power!")
    return
  end
  render()
end

local PRINTABLE_MIN, PRINTABLE_MAX = 32, 126

local function setup_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  for code = PRINTABLE_MIN, PRINTABLE_MAX do
    local char = string.char(code)
    pcall(vim.keymap.set, "n", char, function()
      handle_char(char)
    end, opts)
  end
  vim.keymap.set("n", "<Esc>", function()
    M.stop()
  end, opts)
  vim.keymap.set("n", "<C-c>", function()
    M.stop()
  end, opts)
end

--- Start typing-defense.
---@param opts table|nil { word_pool: string[], label: string, level: integer, points: integer, on_cleared: fun(score: integer): {word_pool: string[], label: string, level: integer}|nil }
---   word_pool overrides config.words/words.list as the falling-word source
---   (used by :TypingDefenseLearning to fall back to a curriculum stage's
---   drills instead of the default common-word pool); label is prepended
---   to the status line (e.g. a stage name); level is the current
---   curriculum-stage number and, if given, turns on points tracking/display
---   (base value = level * 100, scaled by that level's keystroke accuracy --
---   see level_points() above); points seeds the running total (e.g. a
---   caller resuming after tearing this session down for a boss interlude
---   -- see M.get_points()); on_cleared is called with the running score
---   right before each new word spawns and may return a new
---   word_pool/label/level to switch to (used by learning mode to
---   auto-advance curriculum stages every N words).
function M.start(opts)
  opts = opts or {}
  if state.active then
    M.stop()
  end

  highlights.setup()
  keyboard.setup_highlights()

  state.prev_bufnr = vim.api.nvim_get_current_buf()
  state.prev_winid = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "typingnvim"

  vim.api.nvim_win_set_buf(state.prev_winid, buf)
  state.bufnr = buf
  state.winid = state.prev_winid
  state.active = true
  state.finished = false
  state.session = state.session + 1

  -- See force_stop() above: if this buffer or window goes away through
  -- something other than M.stop() (another command wipes/deletes the
  -- buffer, or the window is closed), stop cleanly instead of leaving
  -- `active` stuck true with timers still running. `once = true` since a
  -- fresh M.start() re-registers on the new buffer/window anyway; guarding
  -- on state.bufnr/state.winid keeps this a no-op for the wipe/close that
  -- M.stop() itself triggers when it hands the window back.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.bufnr == buf then
        force_stop()
      end
    end,
  })
  local winid = state.winid
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if state.active and state.winid == winid then
        force_stop()
      end
    end,
  })

  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].cursorline = false
  vim.wo[state.winid].signcolumn = "no"

  local cfg = config.get().defense
  state.lives = cfg.lives
  state.score = 0
  state.misses = 0
  state.laser = nil
  state.explosion = nil
  state.shot = nil
  state.energy = cfg.energy_max
  state.pool_override = opts.word_pool
  state.label = opts.label
  state.on_cleared = opts.on_cleared
  state.level = opts.level
  state.level_correct = 0
  state.level_incorrect = 0
  state.points = opts.points or 0

  local win_width = vim.api.nvim_win_get_width(state.winid)
  local win_height = vim.api.nvim_win_get_height(state.winid)
  state.width = math.max(win_width, 40)
  -- 1 status line + skyline + energy bar + blank separator + 9 keyboard lines = 13
  state.sky_height = math.max(win_height - 13, 5)
  state.keyboard_start = 1 + state.sky_height + 3
  state.base_col = math.floor(state.width / 2)

  spawn_word()
  setup_keymaps(buf)
  render()

  -- fall_interval_ms is tuned for speed_reference_height rows of sky; scale
  -- it so a word takes roughly the same real time to cross the screen no
  -- matter how tall the window is (a taller area has more rows to cover in
  -- the same time, so each row-drop tick must come faster, and vice versa).
  local interval = math.max(math.floor(cfg.fall_interval_ms * cfg.speed_reference_height / state.sky_height), 30)
  state.timer = vim.loop.new_timer()
  state.timer:start(interval, interval, vim.schedule_wrap(tick))
end

function M.stop()
  if not state.active then
    return
  end
  local prev_winid, prev_bufnr = state.prev_winid, state.prev_bufnr
  force_stop()

  if prev_winid and vim.api.nvim_win_is_valid(prev_winid) then
    if prev_bufnr and vim.api.nvim_buf_is_valid(prev_bufnr) then
      vim.api.nvim_win_set_buf(prev_winid, prev_bufnr)
    end
  end
end

function M.is_active()
  return state.active
end

--- Live point total: points already banked from completed levels, plus
--- what the current in-progress level would bank right now at its
--- accuracy so far -- the same total status_line() displays. 0 if this
--- session isn't in a leveled (learning) mode. Meant for a caller to carry
--- the running total across a session teardown/restart (e.g. resuming
--- after a boss interlude) via M.start's `points` option.
function M.get_points()
  if not state.level then
    return 0
  end
  return state.points + level_points(state.level, state.level_correct, state.level_incorrect)
end

return M
