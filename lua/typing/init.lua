local config = require("typing.config")
local game = require("typing.game")
local words = require("typing.words")
local lessons = require("typing.lessons")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

--- Start a random-word typing test.
---@param count integer|nil number of words (defaults to config.word_count)
function M.start_words(count)
  local cfg = config.get()
  count = count or cfg.word_count
  if count < 1 then
    vim.notify("typing.nvim: word count must be at least 1", vim.log.levels.WARN)
    return
  end
  local pool = cfg.words or words.list

  local picked = {}
  for i = 1, count do
    picked[i] = pool[math.random(#pool)]
  end
  game.start(table.concat(picked, " "), "words")
end

--- Start a home-row key drill lesson.
---@param stage integer|nil lesson stage (1..lessons.stage_count()); defaults to config.lesson.stage
function M.start_lesson(stage)
  local cfg = config.get()
  stage = stage or cfg.lesson.stage
  if (cfg.lesson.word_count or 1) < 1 then
    vim.notify("typing.nvim: lesson word count must be at least 1", vim.log.levels.WARN)
    return
  end
  local text = lessons.generate(stage, cfg.lesson)
  game.start(text, "lesson")
end

function M.stop()
  game.stop()
end

function M.is_active()
  return game.is_active()
end

M.lessons = lessons

return M
