local config = require("typing.config")
local game = require("typing.game")
local defense = require("typing.defense")
local boss = require("typing.boss")
local splash = require("typing.splash")
local words = require("typing.words")
local lessons = require("typing.lessons")
local curriculum = require("typing.curriculum")
local ships = require("typing.ships")

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
  game.start(table.concat(picked, " "), "words", {
    on_restart = function()
      M.start_words(count)
    end,
  })
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
  game.start(text, "lesson", {
    on_restart = function()
      M.start_lesson(stage)
    end,
  })
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
  defense.start({
    on_restart = function()
      M.start_defense_speed()
    end,
  })
end

local function titlecase(s)
  return (s:gsub("^%l", string.upper))
end

--- Start typing-defense using the curated key-introduction curriculum (see
--- |typing-defense|) instead of random common words: falling words are
--- drawn from one stage's drills/patterns, same progressive key order as
--- |typing-lessons| but with curated content. Every `words_per_stage`
--- words cleared, auto-advances to the next stage (staying on the last
--- stage once reached).
---
--- Stages listed in `defense_learning.boss_stages` interrupt that advance
--- with a boss fight instead (see |typing-boss|), restricted to the stage
--- just cleared's keys, using the matching ship from `typing.ships.CAMPAIGN`
--- (boss_stages[i] <-> CAMPAIGN[i]) -- small bosses for the first few
--- levels, progressively bigger/badder ones later -- before resuming
--- curriculum practice on the next stage once the fight is dismissed.
---@param stage integer|nil curriculum stage (1..curriculum.stage_count()); defaults to config.defense_learning.stage
function M.start_defense_learning(stage)
  local cfg = config.get()
  stage = stage or cfg.defense_learning.stage
  local words_per_stage = cfg.defense_learning.words_per_stage
  local boss_stages = cfg.defense_learning.boss_stages or {}
  if words_per_stage < 1 then
    vim.notify("typing.nvim: defense_learning.words_per_stage must be at least 1 -- auto-advance disabled", vim.log.levels.WARN)
  end
  -- clamped the same way curriculum.get() clamps internally, so `start_stage`
  -- never desyncs from the stage curriculum.get() actually returns for an
  -- out-of-range {stage} argument
  local start_stage = math.max(1, math.min(stage, curriculum.stage_count()))

  local function pool_and_label(lesson)
    return {
      word_pool = lesson.pool,
      label = string.format("Learning %d/%d: %s (%s)", lesson.id, curriculum.stage_count(), lesson.title, lesson.focus),
      level = lesson.id,
    }
  end

  --- boss_stages[i] pairs positionally with ships.CAMPAIGN[i]; returns the
  --- ship name and its 1-based roster position for stage `n`, or nil if `n`
  --- isn't a boss stage.
  local function boss_for_stage(n)
    for i, s in ipairs(boss_stages) do
      if s == n then
        return ships.CAMPAIGN[i], i
      end
    end
    return nil
  end

  -- Points earned in defense_learning carry across a boss interlude's
  -- session teardown/restart (defense.lua's own state resets to 0 on every
  -- M.start) -- captured from defense.get_points() right before each
  -- handoff, then fed back in as run_stage's starting total.
  local campaign_points = 0

  -- run_stage(n) (re)starts curriculum practice at stage n; forward
  -- declared so on_cleared's boss handoff can call back into it once the
  -- fight is dismissed.
  local run_stage
  run_stage = function(n)
    stop_active()
    defense.start(vim.tbl_extend("force", pool_and_label(curriculum.get(n)), {
      points = campaign_points,
      -- "play again" restarts the whole learning run from the stage the
      -- player originally requested, not wherever they happened to die --
      -- matches what re-running the command would do.
      on_restart = function()
        M.start_defense_learning(start_stage)
      end,
      on_cleared = function(score)
        if words_per_stage < 1 or n >= curriculum.stage_count() then
          return nil
        end
        if score <= 0 or score % words_per_stage ~= 0 then
          return nil
        end
        local next_stage = n + 1
        local ship_name, idx = boss_for_stage(n)
        if not ship_name then
          return pool_and_label(curriculum.get(next_stage))
        end
        -- Hand off on the next event-loop tick, after this callback (deep
        -- inside defense.lua's own explosion-timer closure) finishes
        -- unwinding, rather than tearing defense down mid-callback.
        campaign_points = defense.get_points()
        local lesson = curriculum.get(n)
        vim.schedule(function()
          stop_active()
          boss.start(ship_name, {
            word_pool = lesson.pool,
            label = string.format("Boss %d/%d: %s -- %s keys", idx, #ships.CAMPAIGN, titlecase(ship_name), lesson.title),
            on_finish = function()
              run_stage(next_stage)
            end,
          })
        end)
        return nil
      end,
    }))
  end

  run_stage(start_stage)
end

--- Start the boss level: destroy every ship zone before your lives run
--- out, while dodging periodic bomb waves. See |typing-boss|.
---@param name string|nil ship name from typing.ships.ships, e.g. one of
---   typing.ships.CAMPAIGN (defaults to config.boss.ship)
function M.start_boss(name)
  stop_active()
  boss.start(name, {
    on_restart = function()
      M.start_boss(name)
    end,
  })
end

function M.stop()
  stop_active()
end

function M.is_active()
  return game.is_active() or defense.is_active() or boss.is_active() or splash.is_active()
end

M.lessons = lessons

return M
