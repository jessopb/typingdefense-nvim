local stats = require("typing.stats")
local highlights = require("typing.highlights")

local M = {}

local ns = vim.api.nvim_create_namespace("typing.nvim")

local state = {
  active = false,
  finished = false,
  bufnr = nil,
  winid = nil,
  prev_bufnr = nil,
  prev_winid = nil,
  target = "",
  pos = 0, -- number of characters already typed (0-indexed next column)
  marks = {}, -- marks[i] = true/false for correctness of column i (1-indexed)
  mistakes = 0, -- raw count of wrong keystrokes, including later-corrected ones
  start_time = nil,
  mode = nil,
  on_restart = nil, -- optional fn(), set from M.start's opts; if present, the
  -- results screen offers "r" to play again by calling it (after this
  -- session has already been torn down via M.stop()) in addition to the
  -- usual dismiss keys
}

--- Clears volatile state without touching the buffer/window -- shared by
--- M.stop() and by the BufWipeout/WinClosed autocmds registered in
--- M.start(), which fire when the owned buffer or window disappeared out
--- from under us (closed by another command/plugin) rather than through our
--- own M.stop(). Same rationale as defense.lua's force_stop.
local function force_stop()
  if not state.active then
    return
  end
  state.active = false
  state.finished = false
  state.bufnr = nil
  state.winid = nil
  state.on_restart = nil
end

local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  vim.api.nvim_buf_set_extmark(state.bufnr, ns, 0, 0, {
    end_col = #state.target,
    hl_group = "TypingPending",
    priority = 100,
  })

  for i = 1, state.pos do
    local ok = state.marks[i]
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, 0, i - 1, {
      end_col = i,
      hl_group = ok and "TypingCorrect" or "TypingIncorrect",
      priority = 200,
    })
  end

  if state.pos < #state.target then
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, 0, state.pos, {
      end_col = state.pos + 1,
      hl_group = "TypingCursor",
      priority = 300,
    })
  end
end

local function move_cursor()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local col = math.min(state.pos, math.max(#state.target - 1, 0))
    pcall(vim.api.nvim_win_set_cursor, state.winid, { 1, col })
  end
end

local finish -- forward decl

local function handle_char(char)
  if not state.active or state.finished then
    return
  end
  if state.pos >= #state.target then
    return
  end
  if not state.start_time then
    state.start_time = vim.loop.hrtime()
  end

  local expected = state.target:sub(state.pos + 1, state.pos + 1)
  local correct = char == expected
  state.marks[state.pos + 1] = correct
  if not correct then
    state.mistakes = state.mistakes + 1
  end
  state.pos = state.pos + 1

  render()
  move_cursor()

  if state.pos >= #state.target then
    finish()
  end
end

local function handle_backspace()
  if not state.active or state.finished then
    return
  end
  if state.pos <= 0 then
    return
  end
  state.pos = state.pos - 1
  state.marks[state.pos + 1] = nil
  render()
  move_cursor()
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
  vim.keymap.set("n", "<BS>", handle_backspace, opts)
  vim.keymap.set("n", "<C-h>", handle_backspace, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.stop()
  end, opts)
  vim.keymap.set("n", "<C-c>", function()
    M.stop()
  end, opts)
end

--- Tears this session down and, if the caller gave M.start an on_restart,
--- hands off to it -- captured before M.stop() clears state.on_restart.
local function restart()
  local on_restart = state.on_restart
  M.stop()
  if on_restart then
    on_restart()
  end
end

local function show_results(wpm, acc, elapsed, mistakes)
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  vim.bo[state.bufnr].modifiable = true
  local lines = {
    "",
    "  Typing test complete!",
    "",
    string.format("  WPM:       %.1f", wpm),
    string.format("  Accuracy:  %.1f%%", acc),
    string.format("  Time:      %.1fs", elapsed),
    string.format("  Mistakes:  %d", mistakes),
    "",
    state.on_restart and "  Press r to play again -- <CR>, q, or <Esc> to quit..." or "  Press <CR>, q, or <Esc> to continue...",
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
  if state.on_restart then
    vim.keymap.set("n", "r", restart, opts)
  end
end

finish = function()
  state.finished = true
  local elapsed = (vim.loop.hrtime() - (state.start_time or vim.loop.hrtime())) / 1e9
  local total = #state.target
  local correct = 0
  for i = 1, total do
    if state.marks[i] then
      correct = correct + 1
    end
  end
  local wpm = stats.wpm(total, elapsed)
  local acc = stats.accuracy(correct, total - correct)
  show_results(wpm, acc, elapsed, state.mistakes)
end

-- Start a typing test for `text` (a single line, no newlines). `mode` is a
-- free-form label ("words" | "lesson") kept around for callers/telemetry.
---@param opts table|nil { on_restart: fun() } -- called (after this session
---  is torn down) if the player picks "play again" on the results screen;
---  omit to leave that option off the screen entirely
function M.start(text, mode, opts)
  opts = opts or {}
  if state.active then
    M.stop()
  end
  highlights.setup()

  state.prev_bufnr = vim.api.nvim_get_current_buf()
  state.prev_winid = vim.api.nvim_get_current_win()
  state.target = text
  state.pos = 0
  state.marks = {}
  state.mistakes = 0
  state.start_time = nil
  state.finished = false
  state.mode = mode
  state.on_restart = opts.on_restart

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "typingnvim"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modifiable = false

  vim.api.nvim_win_set_buf(state.prev_winid, buf)
  state.bufnr = buf
  state.winid = state.prev_winid
  state.active = true

  -- See force_stop() below: if this buffer or window goes away through
  -- something other than M.stop(), stop cleanly instead of leaving
  -- `active` stuck true.
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

  vim.wo[state.winid].wrap = true
  vim.wo[state.winid].linebreak = true
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].cursorline = false
  vim.wo[state.winid].signcolumn = "no"

  setup_keymaps(buf)
  render()
  move_cursor()
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
