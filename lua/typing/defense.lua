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
  laser = nil, -- { row, col } target cell while a beam is firing, else nil
  explosion = nil, -- { row, col, frame, max_frames } while the ember spray is animating
  explosion_timer = nil,

  score = 0,
  misses = 0,
  lives = 3,
}

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
  return string.format(
    "Score: %d   Lives: %s   Misses: %d   [type the falling word -- <Esc> to quit]",
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

local function finish()
  state.finished = true
  stop_timer()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  vim.bo[state.bufnr].modifiable = true
  local lines = {
    "",
    "  The city has fallen!",
    "",
    string.format("  Words cleared: %d", state.score),
    string.format("  Misses:        %d", state.misses),
    "",
    "  Press <CR>, q, or <Esc> to continue...",
  }
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
    -- the destroyed word itself still occupies its row (fully green), so
    -- stop the beam one row short of the target instead of drawing over it
    for _, pt in ipairs(laser_cells(state.sky_height, state.base_col, state.laser.row, state.laser.col)) do
      if pt.row >= 0 and pt.row < state.sky_height and pt.row ~= state.laser.row and pt.col >= 0 and pt.col < state.width then
        local idx = pt.row + 2
        lines[idx] = set_col(lines[idx], pt.col, LASER_CHAR)
      end
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
    for _, pt in ipairs(laser_cells(state.sky_height, state.base_col, state.laser.row, state.laser.col)) do
      if pt.row >= 0 and pt.row < state.sky_height and pt.row ~= state.laser.row and pt.col >= 0 and pt.col < state.width then
        vim.api.nvim_buf_set_extmark(state.bufnr, ns, pt.row + 1, pt.col, {
          end_col = pt.col + 1,
          hl_group = "TypingLaser",
          priority = 250,
        })
      end
    end
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
local function fire_laser(row, col)
  state.laser = { row = row, col = col }
  local cfg = config.get().defense
  vim.defer_fn(function()
    if not state.active or state.finished then
      return
    end
    state.laser = nil
    start_explosion(row, col)
  end, cfg.laser_ms)
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
  if char == expected then
    state.typed_len = state.typed_len + 1
    if state.typed_len >= #state.word then
      state.score = state.score + 1
      fire_laser(state.row, state.col + math.floor(#state.word / 2))
    end
  else
    state.misses = state.misses + 1
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

function M.start()
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

  local win_width = vim.api.nvim_win_get_width(state.winid)
  local win_height = vim.api.nvim_win_get_height(state.winid)
  state.width = math.max(win_width, 40)
  -- 1 status line + skyline + blank separator + 9 keyboard lines = 12
  state.sky_height = math.max(win_height - 12, 5)
  state.keyboard_start = 1 + state.sky_height + 2
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
  state.active = false
  state.finished = false
  stop_timer()
  stop_explosion_timer()
  state.laser = nil
  state.explosion = nil

  if state.prev_winid and vim.api.nvim_win_is_valid(state.prev_winid) then
    if state.prev_bufnr and vim.api.nvim_buf_is_valid(state.prev_bufnr) then
      vim.api.nvim_win_set_buf(state.prev_winid, state.prev_bufnr)
    end
  end
  state.bufnr = nil
  state.winid = nil
end

function M.is_active()
  return state.active
end

return M
