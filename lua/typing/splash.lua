local highlights = require("typing.highlights")

-- :TypingDefense's mode-select menu: Learning, Word Speed, and a
-- not-yet-implemented Code Speed placeholder. Deliberately does NOT
-- `require("typing")` at module load time -- init.lua requires this module,
-- so a top-level require back would be circular; the handlers below
-- require("typing") lazily instead, by which point init.lua has finished
-- loading.
local M = {}

local ns = vim.api.nvim_create_namespace("typing.nvim.splash")

local state = {
  active = false,
  bufnr = nil,
  winid = nil,
  prev_bufnr = nil,
  prev_winid = nil,
}

local OPTIONS = {
  {
    key = "1",
    label = "Learning",
    desc = "Curated key-introduction curriculum",
    enabled = true,
    run = function()
      require("typing").start_defense_learning()
    end,
  },
  {
    key = "2",
    label = "Word Speed",
    desc = "Random words from the full dictionary",
    enabled = true,
    run = function()
      require("typing").start_defense_speed()
    end,
  },
  {
    key = "3",
    label = "Code Speed",
    desc = "Real source snippets instead of words",
    enabled = false,
    run = function()
      vim.notify("typing.nvim: Code Speed mode isn't implemented yet", vim.log.levels.INFO)
    end,
  },
}

local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local lines = { "", "  TYPING DEFENSE", "  ==============", "" }
  local marks = {}
  for _, opt in ipairs(OPTIONS) do
    local prefix = "  ["
    local mid = "] "
    local desc = opt.enabled and opt.desc or ("(coming soon) " .. opt.desc)
    local line = prefix .. opt.key .. mid .. string.format("%-12s", opt.label) .. desc
    lines[#lines + 1] = line

    local buf_line = #lines - 1 -- 0-idx
    local key_col_start = #prefix
    local key_col_end = key_col_start + #opt.key
    if opt.enabled then
      marks[#marks + 1] = { line = buf_line, col_start = key_col_start, col_end = key_col_end, hl = "TypingKeyHint" }
    else
      marks[#marks + 1] = { line = buf_line, col_start = 0, col_end = #line, hl = "TypingBossInactive" }
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Press 1-3 to start -- <Esc> to cancel"

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, m.line, m.col_start, {
      end_col = m.col_end,
      hl_group = m.hl,
      priority = 200,
    })
  end
end

local function setup_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  for _, opt in ipairs(OPTIONS) do
    vim.keymap.set("n", opt.key, opt.run, opts)
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

  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].cursorline = false
  vim.wo[state.winid].signcolumn = "no"

  setup_keymaps(buf)
  render()
end

function M.stop()
  if not state.active then
    return
  end
  state.active = false

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
