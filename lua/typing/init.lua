local config = require("typing.config")
local game = require("typing.game")
local defense = require("typing.defense")
local boss = require("typing.boss")
local splash = require("typing.splash")
local words = require("typing.words")
local lessons = require("typing.lessons")
local curriculum = require("typing.curriculum")

local M = {}

--- Only one mode (words/lesson use `game`, defense/boss/splash use their
--- own engines) can own the window's buffer at a time; stop whichever is
--- currently running before handing the buffer to another mode.
local function stop_active()
  game.stop()
  defense.stop()
  boss.stop()
  splash.stop()
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

--- Open typing-defense's mode-select splash: Learning, Word Speed, or Code
--- Speed (not implemented yet). See |typing-defense|.
function M.start_defense()
  stop_active()
  splash.start()
end

--- Start typing-defense in "word speed" mode: words fall from the top of
--- the screen towards a city on the horizon; type them before they land.
--- Keyboard hint diagram shown along the bottom. Random words from the
--- full dictionary -- a pure speed/accuracy drill, no curriculum gating.
function M.start_defense_speed()
  stop_active()
  defense.start()
end

--- Start typing-defense using the curated key-introduction curriculum (see
--- |typing-defense|) instead of random common words: falling words are
--- drawn from one stage's drills/patterns, same progressive key order as
--- |typing-lessons| but with curated content. Every `words_per_stage`
--- words cleared, auto-advances to the next stage (staying on the last
--- stage once reached).
---@param stage integer|nil curriculum stage (1..curriculum.stage_count()); defaults to config.defense_learning.stage
function M.start_defense_learning(stage)
  local cfg = config.get()
  stage = stage or cfg.defense_learning.stage
  local words_per_stage = cfg.defense_learning.words_per_stage
  if words_per_stage < 1 then
    vim.notify("typing.nvim: defense_learning.words_per_stage must be at least 1 -- auto-advance disabled", vim.log.levels.WARN)
  end
  -- clamped the same way curriculum.get() clamps internally, so `current`
  -- (which drives auto-advance) never desyncs from the stage curriculum.get()
  -- actually returns for an out-of-range {stage} argument
  local current = math.max(1, math.min(stage, curriculum.stage_count()))

  local function pool_and_label(lesson)
    return {
      word_pool = lesson.pool,
      label = string.format("Learning %d/%d: %s (%s)", lesson.id, curriculum.stage_count(), lesson.title, lesson.focus),
    }
  end

  stop_active()
  defense.start(vim.tbl_extend("force", pool_and_label(curriculum.get(current)), {
    on_cleared = function(score)
      if words_per_stage < 1 or current >= curriculum.stage_count() then
        return nil
      end
      if score > 0 and score % words_per_stage == 0 then
        current = current + 1
        return pool_and_label(curriculum.get(current))
      end
      return nil
    end,
  }))
end

--- Start the boss level: destroy all 4 ship zones before your lives run
--- out, while dodging periodic bomb waves. See |typing-boss|.
---@param name string|nil ship name (defaults to config.boss.ship)
function M.start_boss(name)
  stop_active()
  boss.start(name)
end

function M.stop()
  stop_active()
end

function M.is_active()
  return game.is_active() or defense.is_active() or boss.is_active() or splash.is_active()
end

M.lessons = lessons

return M
