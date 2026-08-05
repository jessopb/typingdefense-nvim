local config = require("typing.config")
local words = require("typing.words")
local keyboard = require("typing.keyboard")
local highlights = require("typing.highlights")
local effects = require("typing.effects")
local ships = require("typing.ships")

local M = {}

local ns = vim.api.nvim_create_namespace("typing.nvim.boss")

local WRECKAGE_CHAR = "x"
local PRINTABLE_MIN, PRINTABLE_MAX = 32, 126

local state = {
  active = false,
  finished = false,
  session = 0, -- bumped every M.start(); see fire_laser's use of it below,
  -- same rationale as defense.lua's state.session
  bufnr = nil,
  winid = nil,
  prev_bufnr = nil,
  prev_winid = nil,

  ship = nil,
  art_lines = nil,
  zones = nil,
  zones_by_id = nil,

  queue = nil, -- ordered not-yet-destroyed zone ids; queue[1] is the active zone
  words = nil, -- id -> assigned word string
  destroyed = nil, -- id -> true
  typed_len = 0, -- progress into words[queue[1]]

  bombs = {}, -- 0..2 of { word, typed_len, row (gap-relative), col }
  bomb_timer = nil, -- repeating: spawns waves for the whole fight
  fall_timer = nil, -- repeating: advances bomb rows, only while #bombs > 0

  laser = nil, -- { row, col } -- the word/zone-destroying "kill shot" beam; at most one in
  -- flight at a time, freezes handle_char()/bomb_tick() until it (and the explosion
  -- after it) resolves
  explosions = {}, -- list of { row, col, frame, max_frames, zone_id?, on_resolve? }
  explosion_timer = nil, -- one shared timer drains every entry in `explosions`
  shot = nil, -- { row, col } lightweight per-keystroke beam fired on every hit (aimed at
  -- the zone/bomb being typed) or miss (aimed at effects.random_point) -- purely
  -- visual, never freezes play; see fire_shot()
  energy = 0, -- float energy level (see effects.energy_delta); floor-rounded for display;
  -- starts at energy_max (M.start resets it) and dropping below a full bar (1) ends
  -- the fight (handle_char) -- matches the energy bar visually reading empty

  pending_defeat = false,
  pending_victory = false,

  pool_override = nil, -- word list to fall back to instead of config.words/words.list (zone
  -- and bomb words both draw from this), used to restrict a campaign boss to one
  -- curriculum stage's keys
  label = nil, -- optional prefix shown in the status line (e.g. a campaign boss's name)
  on_finish = nil, -- optional fn(won: boolean), called once the results screen is dismissed
  -- (after M.stop() has already restored the caller's buffer) -- lets a caller
  -- chain into whatever comes next (e.g. defense_learning resuming the next stage)

  width = 80,
  ship_height = 0,
  gap_height = 5,
  H = 0, -- skyline row = ship_height + gap_height
  keyboard_start = 0,
  base_col = 0,

  score = 0,
  misses = 0,
  lives = 3,
}

local function word_pool()
  if state.pool_override then
    return state.pool_override
  end
  return config.get().words or words.list
end

--- Retry a random pick until it fits the zone's interior width; falls back
--- to truncating (only reachable with a pathological custom `words` list
--- that has nothing short enough for a 10-12 column pod).
local function pick_zone_word(zone)
  local pool = word_pool()
  local interior = zone.col_end - zone.col_start
  for _ = 1, 100 do
    local w = pool[math.random(#pool)]
    if #w <= interior then
      return w
    end
  end
  return pool[math.random(#pool)]:sub(1, interior)
end

--- A bomb word whose first letter differs from `exclude_first` (if given) --
--- with only 2 concurrent bombs this fully eliminates first-keystroke
--- targeting ambiguity between them.
local function pick_bomb_word(exclude_first)
  local pool = word_pool()
  for _ = 1, 50 do
    local w = pool[math.random(#pool)]
    if not exclude_first or w:sub(1, 1) ~= exclude_first then
      return w
    end
  end
  return pool[math.random(#pool)]
end

--- Activation order: every non-bridge zone shuffled, then every bridge-kind
--- zone appended last -- gates the bridge behind the rest with no
--- special-case code, and generalizes to any future ship's pod kinds.
local function build_queue()
  local first, last = {}, {}
  for _, z in ipairs(state.zones) do
    if z.kind == "bridge" then
      table.insert(last, z.id)
    else
      table.insert(first, z.id)
    end
  end
  for i = #first, 2, -1 do
    local j = math.random(i)
    first[i], first[j] = first[j], first[i]
  end
  for _, id in ipairs(last) do
    table.insert(first, id)
  end
  return first
end

--- Two zones to launch bombs from -- prefer engine-kind pods (thematic:
--- "bombs launch from the engine bays"); falls back to the ship's outermost
--- zones for a future ship with fewer than 2 engine-kind pods.
local function bomb_launch_zones()
  local engines = {}
  for _, z in ipairs(state.zones) do
    if z.kind == "engine" then
      table.insert(engines, z)
    end
  end
  if #engines >= 2 then
    return engines[1], engines[2]
  end
  return state.zones[1], state.zones[#state.zones]
end

local function status_line()
  local prefix = state.label and (state.label .. "   ") or ""
  return string.format(
    "%sScore: %d   Lives: %s   Misses: %d   [destroy the ship -- <Esc> to quit]",
    prefix,
    state.score,
    string.rep("#", math.max(state.lives, 0)),
    state.misses
  )
end

-- Shared row axis: 0..ship_height-1 is the ship, ship_height..H-1 is the
-- bomb-fall gap, H is the skyline/turret. `lines` is 1-indexed with a
-- status line at slot 1; buffer lines are 0-indexed.
local function table_idx(abs_row)
  return abs_row + 2
end

local function buffer_line(abs_row)
  return abs_row + 1
end

--- A word centered in a zone (via ships.center) doesn't start at
--- zone.col_start unless it exactly fills the interior -- this is the same
--- left-pad math ships.center uses internally, needed here to align the
--- typed/untyped highlight split with the actually-rendered text.
local function word_col(zone, word)
  local interior = zone.col_end - zone.col_start
  local pad = math.max(interior - #word, 0)
  return zone.col_start + math.floor(pad / 2)
end

local function stop_bomb_timer()
  if state.bomb_timer then
    state.bomb_timer:stop()
    state.bomb_timer:close()
    state.bomb_timer = nil
  end
end

local function stop_fall_timer()
  if state.fall_timer then
    state.fall_timer:stop()
    state.fall_timer:close()
    state.fall_timer = nil
  end
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
--- rather than through our own M.stop(). Same rationale as defense.lua's
--- force_stop.
local function force_stop()
  if not state.active then
    return
  end
  state.active = false
  state.finished = false
  stop_bomb_timer()
  stop_fall_timer()
  stop_explosion_timer()
  state.laser = nil
  state.explosions = {}
  state.bombs = {}
  state.shot = nil
  state.bufnr = nil
  state.winid = nil
end

local function finish(won)
  state.finished = true
  stop_bomb_timer()
  stop_fall_timer()
  stop_explosion_timer()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  vim.bo[state.bufnr].modifiable = true
  local lines = {
    "",
    won and "  Boss destroyed!" or "  The ship's counterattack overwhelms you!",
    "",
    string.format("  Score:  %d", state.score),
    string.format("  Misses: %d", state.misses),
    "",
    "  Press <CR>, q, or <Esc> to continue...",
  }
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  -- M.stop() first (it restores the caller's buffer/window), then hand off
  -- to on_finish so it can chain into whatever comes next -- on_finish sees
  -- a fully torn-down boss (matches the finished result screen, not a live
  -- fight to bail out of the way <C-c> during play does).
  local function dismiss()
    local cb = state.on_finish
    M.stop()
    if cb then
      cb(won)
    end
  end
  vim.keymap.set("n", "<CR>", dismiss, opts)
  vim.keymap.set("n", "q", dismiss, opts)
  vim.keymap.set("n", "<Esc>", dismiss, opts)
end

--- Current ember positions for one `state.explosions` entry, clipped to the
--- gap (never drawn over the ship's own art -- see the module doc comment
--- at the top of render() for why).
local function explosion_points(e)
  local pts = {}
  for _, ember in ipairs(effects.EMBERS) do
    local row_offset, col_offset = effects.ember_offset(ember.h, e.frame)
    local row = e.row + row_offset
    local col = e.col + col_offset
    if row >= state.ship_height and row < state.H and col >= 0 and col < state.width then
      pts[#pts + 1] = { row = row, col = col }
    end
  end
  return pts
end

--- Cells for a beam from the turret to `target` {row,col}, clipped to the
--- bomb-fall gap (never drawn over the ship's own art above it or past the
--- skyline/turret below) and skipping the target's own row -- that row
--- already shows the zone/bomb word itself, so drawing a beam glyph over
--- it would clash. Shared by both the kill-shot beam (`state.laser`) and
--- the lightweight per-keystroke beam (`state.shot`).
local function beam_cells(target)
  local pts = {}
  for _, pt in ipairs(effects.laser_cells(state.H, state.base_col, target.row, target.col)) do
    if pt.row >= state.ship_height and pt.row < state.H and pt.row ~= target.row and pt.col >= 0 and pt.col < state.width then
      pts[#pts + 1] = pt
    end
  end
  return pts
end

-- A zone-kill beam travels from the bottom turret up into the ship itself,
-- which would otherwise draw straight through neighboring pods' box-drawing
-- characters. Both the beam and its embers are clipped to the gap
-- (abs_row >= ship_height); the "hit" feedback at the pod itself comes
-- entirely from recoloring that zone's word-row extmark to TypingExplosion,
-- the same trick defense.lua uses for its own destroyed word.
local function render()
  if not state.active or state.finished then
    return
  end
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local kb_hint = nil
  if #state.bombs > 0 then
    local b = state.bombs[1]
    if b.typed_len < #b.word then
      kb_hint = { at = b.word:sub(b.typed_len + 1, b.typed_len + 1):upper() }
    end
  else
    local id = state.queue[1]
    if id then
      local w = state.words[id]
      if state.typed_len < #w then
        kb_hint = { at = w:sub(state.typed_len + 1, state.typed_len + 1):upper() }
      end
    end
  end
  local kb_lines, kb_cells = keyboard.render({ hint = kb_hint, window_width = state.width })

  local lines = { status_line() }
  for _, l in ipairs(state.art_lines) do
    lines[#lines + 1] = l
  end
  for _, z in ipairs(state.zones) do
    local idx = table_idx(z.row)
    local interior = z.col_end - z.col_start
    local content
    if state.destroyed[z.id] then
      content = string.rep(WRECKAGE_CHAR, interior)
    else
      content = ships.center(state.words[z.id], interior)
    end
    lines[idx] = effects.set_col(lines[idx], z.col_start, content)
  end

  for _ = 1, state.gap_height do
    lines[#lines + 1] = ""
  end
  for _, b in ipairs(state.bombs) do
    local idx = table_idx(state.ship_height + b.row)
    lines[idx] = effects.set_col(lines[idx], b.col, b.word)
  end

  if state.laser then
    for _, pt in ipairs(beam_cells(state.laser)) do
      local idx = table_idx(pt.row)
      lines[idx] = effects.set_col(lines[idx], pt.col, effects.LASER_CHAR)
    end
  end
  if state.shot then
    for _, pt in ipairs(beam_cells(state.shot)) do
      local idx = table_idx(pt.row)
      lines[idx] = effects.set_col(lines[idx], pt.col, effects.LASER_CHAR)
    end
  end

  for _, e in ipairs(state.explosions) do
    for _, p in ipairs(explosion_points(e)) do
      local idx = table_idx(p.row)
      lines[idx] = effects.set_col(lines[idx], p.col, effects.EMBER_CHAR)
    end
  end

  lines[#lines + 1] = effects.set_col(effects.build_skyline(state.width), math.max(state.base_col - 1, 0), effects.BASE_GLYPH)
  local energy_line, energy_fill_start, energy_fill_end = effects.energy_bar(state.energy, config.get().boss.energy_max)
  lines[#lines + 1] = energy_line
  lines[#lines + 1] = ""
  for _, l in ipairs(kb_lines) do
    lines[#lines + 1] = l
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  for _, z in ipairs(state.zones) do
    local line = buffer_line(z.row)
    if state.destroyed[z.id] then
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, z.col_start, {
        end_col = z.col_end,
        hl_group = "TypingBossInactive",
        priority = 200,
      })
    else
      local mid_kill = false
      for _, e in ipairs(state.explosions) do
        if e.zone_id == z.id then
          mid_kill = true
          break
        end
      end
      if mid_kill then
        vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, z.col_start, {
          end_col = z.col_end,
          hl_group = "TypingExplosion",
          priority = 200,
        })
      elseif z.id == state.queue[1] then
        local word = state.words[z.id]
        local start_col = word_col(z, word)
        if state.typed_len > 0 then
          vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, start_col, {
            end_col = start_col + state.typed_len,
            hl_group = "TypingCorrect",
            priority = 200,
          })
        end
        if state.typed_len < #word then
          vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, start_col + state.typed_len, {
            end_col = start_col + #word,
            hl_group = "TypingBossActive",
            priority = 200,
          })
        end
      else
        vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, z.col_start, {
          end_col = z.col_end,
          hl_group = "TypingBossInactive",
          priority = 200,
        })
      end
    end
  end

  for _, b in ipairs(state.bombs) do
    local line = buffer_line(state.ship_height + b.row)
    if b.typed_len > 0 then
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, b.col, {
        end_col = b.col + b.typed_len,
        hl_group = "TypingCorrect",
        priority = 200,
      })
    end
    if b.typed_len < #b.word then
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, line, b.col + b.typed_len, {
        end_col = b.col + #b.word,
        hl_group = "TypingPending",
        priority = 200,
      })
    end
  end

  local base_start = math.max(state.base_col - 1, 0)
  vim.api.nvim_buf_set_extmark(state.bufnr, ns, buffer_line(state.H), base_start, {
    end_col = base_start + #effects.BASE_GLYPH,
    hl_group = "TypingLaser",
    priority = 250,
  })
  if state.laser then
    for _, pt in ipairs(beam_cells(state.laser)) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, buffer_line(pt.row), pt.col, {
        end_col = pt.col + 1,
        hl_group = "TypingLaser",
        priority = 250,
      })
    end
  end
  if state.shot then
    for _, pt in ipairs(beam_cells(state.shot)) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, buffer_line(pt.row), pt.col, {
        end_col = pt.col + 1,
        hl_group = "TypingLaser",
        priority = 250,
      })
    end
  end
  if energy_fill_end > energy_fill_start then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, buffer_line(state.H + 1), energy_fill_start, {
      end_col = energy_fill_end,
      hl_group = "TypingEnergy",
      priority = 200,
    })
  end
  for _, e in ipairs(state.explosions) do
    for _, p in ipairs(explosion_points(e)) do
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, buffer_line(p.row), p.col, {
        end_col = p.col + 1,
        hl_group = "TypingExplosion",
        priority = 260,
      })
    end
  end

  keyboard.apply_highlights(state.bufnr, kb_cells, state.keyboard_start)
end

local function ensure_explosion_timer()
  if state.explosion_timer then
    return
  end
  local cfg = config.get().boss
  state.explosion_timer = vim.loop.new_timer()
  state.explosion_timer:start(
    cfg.explosion_frame_ms,
    cfg.explosion_frame_ms,
    vim.schedule_wrap(function()
      if not state.active then
        return
      end
      local remaining = {}
      for _, e in ipairs(state.explosions) do
        e.frame = e.frame + 1
        if e.frame > e.max_frames then
          if e.on_resolve then
            e.on_resolve()
          end
        else
          remaining[#remaining + 1] = e
        end
      end
      state.explosions = remaining
      if #state.explosions == 0 then
        stop_explosion_timer()
        if state.pending_victory then
          finish(true)
          return
        end
        if state.pending_defeat then
          finish(false)
          return
        end
      end
      render()
    end)
  )
end

local function start_explosion(row, col, on_resolve, zone_id)
  local cfg = config.get().boss
  table.insert(state.explosions, {
    row = row,
    col = col,
    frame = 0,
    max_frames = cfg.explosion_frames,
    on_resolve = on_resolve,
    zone_id = zone_id,
  })
  ensure_explosion_timer()
  render()
end

--- Fires the turret at (row,col); after laser_ms, starts the ember
--- explosion there. `vim.defer_fn` callbacks can't be cancelled, so this
--- self-guards on state.active/state.finished/state.session, same as
--- defense.lua's fire_laser -- a stopped-then-restarted fight within
--- laser_ms would otherwise let this stale callback fire against the new
--- session's row/col.
local function fire_laser(row, col, on_resolve, zone_id)
  state.laser = { row = row, col = col }
  local cfg = config.get().boss
  local session = state.session
  vim.defer_fn(function()
    if not state.active or state.finished or state.session ~= session then
      return
    end
    state.laser = nil
    start_explosion(row, col, on_resolve, zone_id)
  end, cfg.laser_ms)
end

--- Fire a lightweight beam at (row,col) for every keystroke that doesn't
--- destroy a zone/bomb -- a hit-in-progress aims at whatever it's typing
--- towards, a miss goes to a random cell in the gap (see handle_char).
--- Purely visual: unlike fire_laser, it never freezes handle_char()/
--- bomb_tick(), so keystrokes keep landing at full speed. Self-clears via
--- table identity rather than the active/finished guard fire_laser uses,
--- same reasoning as defense.lua's fire_shot.
local function fire_shot(row, col)
  local shot = { row = row, col = col }
  state.shot = shot
  vim.defer_fn(function()
    if state.shot == shot then
      state.shot = nil
      render()
    end
  end, config.get().boss.shot_ms)
end

local function bomb_tick()
  if not state.active or state.finished then
    return
  end
  if state.laser or #state.explosions > 0 then
    return
  end
  if #state.bombs == 0 then
    stop_fall_timer()
    return
  end

  local remaining, landed = {}, {}
  for _, b in ipairs(state.bombs) do
    b.row = b.row + 1
    if b.row >= state.gap_height then
      landed[#landed + 1] = b
    else
      remaining[#remaining + 1] = b
    end
  end
  state.bombs = remaining
  if #remaining == 0 then
    stop_fall_timer()
  end

  for _, b in ipairs(landed) do
    state.lives = state.lives - 1
    if state.lives <= 0 then
      state.pending_defeat = true
    end
    -- impact only, no beam -- it wasn't shot down
    start_explosion(state.H - 1, b.col + math.floor(#b.word / 2), nil, nil)
  end

  render()
end

local function start_fall_timer()
  if state.fall_timer then
    return
  end
  local cfg = config.get().boss
  local interval = math.max(math.floor(cfg.fall_interval_ms * cfg.speed_reference_height / state.gap_height), 30)
  state.fall_timer = vim.loop.new_timer()
  state.fall_timer:start(interval, interval, vim.schedule_wrap(bomb_tick))
end

local function launch_col(zone, word)
  local interior = zone.col_end - zone.col_start
  local c = zone.col_start + math.floor((interior - #word) / 2)
  return math.max(math.min(c, state.width - #word), 0)
end

--- The interrupt: two bombs launch at once, and the active zone's typed
--- progress resets to 0 (it stays queue[1] -- the wave doesn't reselect,
--- just wipes progress, so the same zone resumes from scratch once cleared).
local function spawn_bomb_wave()
  local zone_a, zone_b = bomb_launch_zones()
  local w1 = pick_bomb_word(nil)
  local w2 = pick_bomb_word(w1:sub(1, 1))
  state.bombs = {
    { word = w1, typed_len = 0, row = 0, col = launch_col(zone_a, w1) },
    { word = w2, typed_len = 0, row = 0, col = launch_col(zone_b, w2) },
  }
  state.typed_len = 0
  start_fall_timer()
  render()
end

local function maybe_spawn_wave()
  if not state.active or state.finished then
    return
  end
  if #state.bombs > 0 then
    return
  end
  if #state.queue == 0 then
    return
  end
  spawn_bomb_wave()
end

--- A random target for a "miss" shot, confined to the bomb-fall gap (the
--- only region a beam is ever drawn in -- see beam_cells).
local function random_gap_point()
  local p = effects.random_point(state.gap_height, state.width)
  return state.ship_height + p.row, p.col
end

local function handle_char(char)
  if not state.active or state.finished then
    return
  end
  if state.laser or #state.explosions > 0 then
    return
  end
  if state.energy < 1 then
    -- Shouldn't normally still be reachable -- finish() ends the fight the
    -- instant energy drops below a full bar, below -- but guard against
    -- firing on a keystroke that arrives with less than one bar regardless.
    finish(false)
    return
  end
  local cfg = config.get().boss

  if #state.bombs > 0 then
    local match = nil
    for _, b in ipairs(state.bombs) do
      if b.typed_len > 0 and char == b.word:sub(b.typed_len + 1, b.typed_len + 1) then
        match = b
        break
      end
    end
    if not match then
      for _, b in ipairs(state.bombs) do
        if char == b.word:sub(b.typed_len + 1, b.typed_len + 1) then
          match = b
          break
        end
      end
    end

    if match then
      state.energy = effects.clamp(state.energy + effects.energy_delta(true), 0, cfg.energy_max)
      match.typed_len = match.typed_len + 1
      local abs_row = state.ship_height + match.row
      local col = match.col + math.floor(#match.word / 2)
      if match.typed_len >= #match.word then
        state.score = state.score + 1
        for i, b in ipairs(state.bombs) do
          if b == match then
            table.remove(state.bombs, i)
            break
          end
        end
        if #state.bombs == 0 then
          stop_fall_timer()
        end
        fire_laser(abs_row, col, nil, nil)
      else
        fire_shot(abs_row, col)
      end
    else
      state.energy = effects.clamp(state.energy + effects.energy_delta(false), 0, cfg.energy_max)
      state.misses = state.misses + 1
      state.lives = state.lives - 1
      fire_shot(random_gap_point())
      if state.lives <= 0 or state.energy < 1 then
        render()
        finish(false)
        return
      end
    end
    render()
    return
  end

  local id = state.queue[1]
  if not id then
    return
  end
  local word = state.words[id]
  local expected = word:sub(state.typed_len + 1, state.typed_len + 1)
  if char == expected then
    state.energy = effects.clamp(state.energy + effects.energy_delta(true), 0, cfg.energy_max)
    state.typed_len = state.typed_len + 1
    local z = state.zones_by_id[id]
    local target_col = word_col(z, word) + math.floor(#word / 2)
    if state.typed_len >= #word then
      state.score = state.score + 1
      fire_laser(z.row, target_col, function()
        state.destroyed[id] = true
        table.remove(state.queue, 1)
        state.typed_len = 0
        if #state.queue == 0 then
          state.pending_victory = true
        end
      end, id)
    else
      fire_shot(z.row, target_col)
    end
  else
    state.energy = effects.clamp(state.energy + effects.energy_delta(false), 0, cfg.energy_max)
    state.misses = state.misses + 1
    state.lives = state.lives - 1
    fire_shot(random_gap_point())
    if state.lives <= 0 or state.energy <= 0 then
      render()
      finish(false)
      return
    end
  end
  render()
end

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

--- Start the boss level. `name` is a typing.ships registry key (defaults
--- to config.boss.ship, itself defaulting to "cruiser").
---@param opts table|nil { word_pool: string[], label: string, on_finish: fun(won: boolean) }
---   word_pool overrides config.words/words.list as the zone/bomb word
---   source (used by a campaign boss to restrict the fight to one
---   curriculum stage's keys); label is prepended to the status line;
---   on_finish is called with whether the fight was won once the player
---   dismisses the results screen (used by defense_learning to resume the
---   next stage after a boss interlude).
function M.start(name, opts)
  opts = opts or {}
  if state.active then
    M.stop()
  end

  highlights.setup()
  keyboard.setup_highlights()

  local cfg = config.get().boss
  state.ship = ships.get(name or cfg.ship)
  state.art_lines, state.zones = ships.build(state.ship)
  state.ship_height = #state.art_lines
  state.zones_by_id = {}
  for _, z in ipairs(state.zones) do
    state.zones_by_id[z.id] = z
  end

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
  -- something other than M.stop(), stop cleanly instead of leaving
  -- `active` stuck true with timers still running. Same pattern as
  -- defense.lua's M.start().
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

  state.lives = cfg.lives
  state.score = 0
  state.misses = 0
  state.laser = nil
  state.explosions = {}
  state.bombs = {}
  state.shot = nil
  state.energy = cfg.energy_max
  state.pending_defeat = false
  state.pending_victory = false
  state.pool_override = opts.word_pool
  state.label = opts.label
  state.on_finish = opts.on_finish

  local win_width = vim.api.nvim_win_get_width(state.winid)
  local win_height = vim.api.nvim_win_get_height(state.winid)
  local ship_width = #state.art_lines[1]
  state.width = math.max(win_width, ship_width)

  -- Center the ship in the play area: evenly pad both sides rather than
  -- leaving it flush against column 0. Shift the ship's own art plus every
  -- zone's columns by the same amount so word placement, extmarks, laser
  -- targeting (word_col), and bomb launch columns (launch_col) -- all of
  -- which derive from zone.col_start/col_end -- stay correctly aligned
  -- without each needing its own pad-aware math. 0 when the ship already
  -- fills (or exceeds) the window width, same as a left-aligned ship did
  -- before centering existed.
  local left_pad = math.max(math.floor((state.width - ship_width) / 2), 0)
  if left_pad > 0 then
    local pad_str = string.rep(" ", left_pad)
    for i, l in ipairs(state.art_lines) do
      state.art_lines[i] = pad_str .. l
    end
    for _, z in ipairs(state.zones) do
      z.col_start = z.col_start + left_pad
      z.col_end = z.col_end + left_pad
    end
  end

  -- 1 status + ship_height + 1 skyline + 1 energy bar + 1 blank separator + 9 keyboard lines
  local fixed_rows = 1 + state.ship_height + 1 + 1 + 1 + 9
  state.gap_height = math.max(win_height - fixed_rows, 3)
  state.H = state.ship_height + state.gap_height
  state.keyboard_start = 1 + state.ship_height + state.gap_height + 3
  state.base_col = math.floor(state.width / 2)

  state.queue = build_queue()
  state.destroyed = {}
  state.words = {}
  state.typed_len = 0
  for _, z in ipairs(state.zones) do
    state.words[z.id] = pick_zone_word(z)
  end

  setup_keymaps(buf)
  render()

  state.bomb_timer = vim.loop.new_timer()
  state.bomb_timer:start(cfg.bomb_interval_ms, cfg.bomb_interval_ms, vim.schedule_wrap(maybe_spawn_wave))
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

return M
