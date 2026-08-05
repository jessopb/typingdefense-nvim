local config = require("typing.config")
local game = require("typing.game")
local defense = require("typing.defense")
local words = require("typing.words")
local lessons = require("typing.lessons")

local M = {}

--- Only one mode (words/lesson use `game`, defense uses its own engine) can
--- own the window's buffer at a time; stop whichever is currently running
--- before handing the buffer to another mode.
local function stop_active()
  game.stop()
  defense.stop()
end

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
  stop_active()
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
  stop_active()
  game.start(text, "lesson")
end

--- Start typing-defense: words fall from the top of the screen towards a
--- city on the horizon; type them before they land. Keyboard hint diagram
--- shown along the bottom.
function M.start_defense()
  stop_active()
  defense.start()
end

function M.stop()
  stop_active()
end

function M.is_active()
  return game.is_active() or defense.is_active()
end

M.lessons = lessons

return M
