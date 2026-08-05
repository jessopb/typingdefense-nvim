local M = {}

local defaults = {
  -- number of words for :TypingWords when no count is given
  word_count = 25,
  -- override the built-in word list, e.g. { "foo", "bar" }
  words = nil,

  -- highlight groups are linked (not overridden) to these targets at setup time,
  -- so users can `:hi TypingCorrect ...` themselves and it will stick.
  highlights = {
    pending = "Comment",
    correct = "String",
    incorrect = "ErrorMsg",
    cursor = "CursorLine",
    key_hint = "Todo", -- the relocated finger-outline in the keyboard hint diagram
  },

  lesson = {
    -- default stage used by :TypingLesson when no stage number is given
    stage = 1,
    word_count = 30,
    word_length = { 2, 5 },
  },

  defense = {
    lives = 3,
    fall_interval_ms = 500, -- how often the falling word drops one row
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
