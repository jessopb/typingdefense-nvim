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

vim.api.nvim_create_user_command("TypingStop", function()
  require("typing").stop()
end, {
  desc = "Abort the current typing test",
})
