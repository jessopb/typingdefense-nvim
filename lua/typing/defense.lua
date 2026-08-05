local config = require("typing.config")
local words = require("typing.words")
local keyboard = require("typing.keyboard")
local highlights = require("typing.highlights")

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

  score = 0,
  misses = 0,
  lives = 3,
}

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

local function build_skyline(width)
  local tile = "_|#|__|##|_|###|__|#|___"
  local s = tile:rep(math.ceil(width / #tile) + 1)
  return s:sub(1, width)
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
  local kb_lines, kb_cells = keyboard.render({ hint = kb_hint })

  local lines = { status_line() }
  for row = 0, state.sky_height - 1 do
    if row == state.row then
      lines[#lines + 1] = string.rep(" ", state.col) .. state.word
    else
      lines[#lines + 1] = ""
    end
  end
  lines[#lines + 1] = build_skyline(state.width)
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
      hl_group = "TypingCorrect",
      priority = 200,
    })
  end
  if state.typed_len < #state.word then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, word_line, state.col + state.typed_len, {
      end_col = state.col + #state.word,
      hl_group = "TypingPending",
      priority = 200,
    })
  end

  keyboard.apply_highlights(state.bufnr, kb_cells, state.keyboard_start)
end

local function tick()
  if not state.active or state.finished then
    return
  end
  state.row = state.row + 1
  if state.row >= state.sky_height then
    lose_life()
  end
  render()
end

local function handle_char(char)
  if not state.active or state.finished then
    return
  end
  local expected = state.word:sub(state.typed_len + 1, state.typed_len + 1)
  if char == expected then
    state.typed_len = state.typed_len + 1
    if state.typed_len >= #state.word then
      state.score = state.score + 1
      spawn_word()
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

  local win_width = vim.api.nvim_win_get_width(state.winid)
  local win_height = vim.api.nvim_win_get_height(state.winid)
  state.width = math.max(win_width, 40)
  -- 1 status line + skyline + blank separator + 9 keyboard lines = 12
  state.sky_height = math.max(win_height - 12, 5)
  state.keyboard_start = 1 + state.sky_height + 2

  spawn_word()
  setup_keymaps(buf)
  render()

  state.timer = vim.loop.new_timer()
  state.timer:start(cfg.fall_interval_ms, cfg.fall_interval_ms, vim.schedule_wrap(tick))
end

function M.stop()
  if not state.active then
    return
  end
  state.active = false
  state.finished = false
  stop_timer()

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
