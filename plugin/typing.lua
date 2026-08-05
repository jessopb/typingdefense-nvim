if vim.g.loaded_typing_nvim then
  return
end
vim.g.loaded_typing_nvim = true

-- LuaJIT's math.random uses a fixed default seed, so without this every
-- Neovim session would generate the exact same "random" word order.
math.randomseed(vim.loop.hrtime())

vim.api.nvim_create_user_command("TypingWords", function(cmdopts)
  local count = tonumber(cmdopts.args)
  require("typing").start_words(count)
end, {
  nargs = "?",
  desc = "Start a random-word typing test (optional word count)",
})

vim.api.nvim_create_user_command("TypingLesson", function(cmdopts)
  local stage = tonumber(cmdopts.args)
  require("typing").start_lesson(stage)
end, {
  nargs = "?",
  desc = "Start a home-row key drill lesson (optional stage number)",
})

vim.api.nvim_create_user_command("TypingDefense", function()
  require("typing").start_defense()
end, {
  desc = "Open typing-defense's mode-select splash (Learning / Word Speed / Code Speed)",
})

vim.api.nvim_create_user_command("TypingDefenseLearning", function(cmdopts)
  local stage = tonumber(cmdopts.args)
  require("typing").start_defense_learning(stage)
end, {
  nargs = "?",
  desc = "Start typing-defense using the curated key-introduction curriculum (optional stage number)",
})

vim.api.nvim_create_user_command("TypingBoss", function(cmdopts)
  local name = cmdopts.args ~= "" and cmdopts.args or nil
  require("typing").start_boss(name)
end, {
  nargs = "?",
  desc = "Start the boss level: destroy all 4 ship zones before your lives run out",
})

vim.api.nvim_create_user_command("TypingStop", function()
  require("typing").stop()
end, {
  desc = "Abort the current typing test",
})

vim.api.nvim_create_user_command("TypingKeyboardPreview", function(cmdopts)
  local kb = require("typing.keyboard")
  local at, from = cmdopts.fargs[1], cmdopts.fargs[2]
  local hint = at and { at = at:upper(), from = from and from:upper() or nil } or nil

  kb.setup_highlights()
  local lines, cells = kb.render({ hint = hint })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  kb.apply_highlights(buf, cells)

  local width = #lines[1]
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].cursorline = false

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
  end
end, {
  nargs = "*",
  desc = "Preview the keyboard hint diagram; optional [AT] [FROM] to relocate the finger outline, e.g. :TypingKeyboardPreview U J",
})
