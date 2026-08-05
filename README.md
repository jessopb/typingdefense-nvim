# typing.nvim

A typing-practice game that runs inside a Neovim window. Starting a test
takes over your current buffer with practice text; your original buffer
comes back automatically when the test ends or is aborted.

Four modes:

- **Words** — random common English words, Monkeytype-style.
- **Lesson** — progressive home-row key drills (generated pseudo-words) for
  building raw muscle memory one key at a time, spreading out from the home
  row two keys per stage.
- **Defense** — words fall from the top of the screen towards a city on the
  horizon; type each one before it lands, or lose a life. A keyboard hint
  diagram along the bottom highlights the next key you need.
  `:TypingDefense` opens a mode-select splash: Learning (a curated
  key-introduction curriculum, same key order as Lesson mode but with
  hand-picked drills) or Word Speed (random words, no curriculum gating);
  `:TypingDefenseLearning` skips straight to Learning mode.
- **Boss** — a stationary ship hovers at the top; type the word in each of
  its zones to destroy it while dodging periodic bomb waves.

In Words/Lesson mode, correct characters and mistakes are highlighted
live, `<BS>` lets you fix mistakes, and finishing the text shows WPM,
accuracy, elapsed time, and mistake count. `<Esc>`/`<C-c>` aborts a test in
progress (any mode).

## Install

**lazy.nvim**

```lua
{
  "jessopb/typingdefense-nvim",
  cmd = {
    "TypingWords",
    "TypingLesson",
    "TypingDefense",
    "TypingDefenseLearning",
    "TypingBoss",
    "TypingStop",
    "TypingKeyboardPreview",
  },
  opts = {},
}
```

**packer.nvim**

```lua
use {
  "jessopb/typingdefense-nvim",
  config = function()
    require("typing").setup()
  end,
}
```

## Usage

```vim
:TypingWords              " 25 random words (configurable)
:TypingWords 50           " 50 random words
:TypingLesson             " stage 1 home-row drill (f/j)
:TypingLesson 5           " stage 5 (cumulative through g/h)
:TypingDefense            " open the mode-select splash (Learning / Word Speed)
:TypingDefenseLearning    " skip the splash, start Learning mode directly
:TypingBoss               " destroy a ship's zones before your lives run out
:TypingKeyboardPreview    " preview the keyboard hint diagram
:TypingStop               " abort the current test/game
```

Suggested keymaps:

```lua
vim.keymap.set("n", "<leader>tw", "<cmd>TypingWords<cr>")
vim.keymap.set("n", "<leader>tl", "<cmd>TypingLesson<cr>")
vim.keymap.set("n", "<leader>td", "<cmd>TypingDefense<cr>")
```

## Configuration

```lua
require("typing").setup({
  word_count = 25,
  words = nil, -- override the built-in word list, e.g. { "foo", "bar" }

  highlights = {
    pending   = "Comment",
    correct   = "String",
    incorrect = "ErrorMsg",
    cursor    = "CursorLine",
    key_hint  = "#ffff00", -- relocated finger-outline in the keyboard hint diagram
                            -- (a literal hex color, not a link target, so it
                            -- stays vivid regardless of colorscheme)
  },

  lesson = {
    stage = 1,
    word_count = 30,
    word_length = { 2, 5 },
  },

  defense = {
    lives = 3,
    fall_interval_ms = 1000, -- how often the falling word drops one row
  },
})
```

See `:help typing.nvim` for the full lesson-stage key order and highlight
group names.
