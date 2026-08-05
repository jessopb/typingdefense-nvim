-- Curated key-introduction curriculum for :TypingDefenseLearning, transcribed
-- from temp/lessonJson1to4.js and temp/lessonJsonRemaning.js. Each stage's
-- `pool` (the falling-word source for defense.lua) is derived at load time
-- from its patterns/words -- a multi-token pattern like "fj fj fj fj" is
-- split on whitespace into individual falling entries, so heavily-repeated
-- drills naturally show up more often in the random pool.
local M = {}

-- Kept close to the source JS shape (exercises for stages 1-4, flat
-- words/patterns for 5-17 -- that split exists in the source data itself)
-- so future edits can be diffed against temp/ if the curriculum grows.
local RAW = {
  {
    id = 1,
    title = "Index Fingers",
    new_keys = { "F", "J" },
    objectives = { "Alternate hands", "Develop rhythm", "Build finger independence" },
    exercises = {
      { name = "Alternating", patterns = { "fj fj fj fj", "jf jf jf jf" } },
      { name = "Repeats", patterns = { "ffff", "jjjj" } },
      { name = "Blocks", patterns = { "fjjf", "jffj", "ffjj", "jjff" } },
      { name = "Flow", patterns = { "fjfj", "jfjf", "fjff", "jjff" } },
    },
  },
  {
    id = 2,
    title = "Middle Fingers",
    new_keys = { "D", "K" },
    objectives = { "Introduce middle fingers", "Practice inward and outward movement", "Learn two-hand rolling patterns" },
    exercises = {
      { name = "Pairs", patterns = { "df", "fd", "jk", "kj" } },
      { name = "Cross-Hand", patterns = { "dj", "fk", "dk", "fj" } },
      { name = "Rolls", patterns = { "dfjk", "kjfd", "fdjk", "jkfd" } },
      { name = "Blocks", patterns = { "ddff", "jjkk", "dfdf", "jkjk" } },
      { name = "Sequences", patterns = { "dfjk", "fjdk", "kjfd", "dkfj" } },
    },
  },
  {
    id = 3,
    title = "Ring Fingers",
    new_keys = { "S", "L" },
    objectives = { "Introduce ring fingers", "Learn rolling motions", "Increase hand span" },
    exercises = {
      { name = "Rolls", patterns = { "sdf", "fds", "jkl", "lkj" } },
      { name = "Mirror Rolls", patterns = { "sdfj", "jkls", "fdjk", "lkfd" } },
      { name = "Alternating", patterns = { "sl sl sl", "sd jl", "sf lj" } },
      { name = "Long Runs", patterns = { "sdfjkl", "lkjfds", "sdfjkl", "lkjfds" } },
    },
  },
  {
    id = 4,
    title = "Pinkies",
    new_keys = { "A", ";" },
    objectives = { "Complete the home row", "Strengthen pinkies", "Practice full-row motion" },
    exercises = {
      { name = "Scales", patterns = { "asdf", "jkl;", "asdfjkl;", ";lkjfdsa" } },
      { name = "Alternating", patterns = { "a;", "as ;l", "ad ;k", "af ;j" } },
      { name = "Mirror", patterns = { "asdf fdsa", "jkl; ;lkj" } },
      { name = "Long Runs", patterns = { "asdfjkl;", ";lkjfdsa", "asdfjkl;", ";lkjfdsa" } },
      { name = "Mixed", patterns = { "afjk", "sdl;", "aksl", "fjd;" } },
    },
  },
  {
    id = 5,
    title = "E and I",
    new_keys = { "E", "I" },
    focus = "Nearest upward reaches",
    words = { "is", "if", "idea", "idle", "seal", "side", "dies", "like", "life", "safe" },
    patterns = { "de de de", "ki ki ki", "asdfei", "eidf", "side", "dies" },
  },
  {
    id = 6,
    title = "R and U",
    new_keys = { "R", "U" },
    focus = "Index finger reaches",
    words = { "sure", "user", "rise", "rise", "rule", "idle", "surely" },
    patterns = { "fr fr", "ju ju", "erui", "rude", "user" },
  },
  {
    id = 7,
    title = "T and Y",
    new_keys = { "T", "Y" },
    focus = "Outer index reaches",
    words = { "try", "true", "yet", "tire", "style", "study" },
    patterns = { "ty ty", "rtyu", "tyui", "try", "true" },
  },
  {
    id = 8,
    title = "O",
    new_keys = { "O" },
    focus = "Right ring finger",
    words = { "to", "too", "tool", "door", "food", "root", "rose" },
    patterns = { "io oi", "uo", "tool", "root" },
  },
  {
    id = 9,
    title = "N",
    new_keys = { "N" },
    focus = "Right index down",
    words = { "one", "tone", "stone", "into", "inner", "send", "stand" },
    patterns = { "jn nj", "tone", "into" },
  },
  {
    id = 10,
    title = "H and G",
    new_keys = { "H", "G" },
    focus = "Inner index crossover",
    words = { "the", "this", "that", "then", "thing", "their", "there" },
    patterns = { "gh hg", "fg hj", "the", "that", "then" },
  },
  {
    id = 11,
    title = "C and M",
    new_keys = { "C", "M" },
    focus = "Nearest bottom row",
    words = { "come", "same", "some", "case", "mouse", "music" },
    patterns = { "cm mc", "dc km", "come", "same" },
  },
  {
    id = 12,
    title = "V and ,",
    new_keys = { "V", "," },
    focus = "Bottom row rolls",
    words = { "move", "save", "river", "drive" },
    patterns = { "vm", "fv", "move", "save" },
  },
  {
    id = 13,
    title = "W and O",
    new_keys = { "W", "P" },
    focus = "Ring finger reaches",
    words = { "power", "people", "press", "proof", "upper" },
    patterns = { "wp", "we", "pop", "power" },
  },
  {
    id = 14,
    title = "B",
    new_keys = { "B" },
    focus = "Center bottom",
    words = { "about", "able", "better", "build", "bring" },
    patterns = { "vb", "bn", "bring", "about" },
  },
  {
    id = 15,
    title = "X and .",
    new_keys = { "X", "." },
    focus = "Outer bottom row",
    words = { "next", "text", "extra", "exit" },
    patterns = { "x.", "cx", "text", "next" },
  },
  {
    id = 16,
    title = "Q and Z",
    new_keys = { "Q", "Z" },
    focus = "Least common letters",
    words = { "quiz", "quick", "equal", "zero", "zone" },
    patterns = { "qaz", "zaq", "quiz" },
  },
  {
    id = 17,
    title = "Punctuation",
    new_keys = { ".", ",", "/", "'", "\"", "?", "!" },
    focus = "Common punctuation",
    words = {},
    patterns = { "word, word.", "Hello, world.", "Yes!", "Really?" },
  },
}

--- Split "fj fj fj fj" into its space-separated tokens; a pattern with no
--- space (e.g. "asdfjkl;") comes back as a single token.
local function tokens(pattern)
  local out = {}
  for tok in pattern:gmatch("%S+") do
    out[#out + 1] = tok
  end
  return out
end

local function build_pool(stage)
  local pool = {}
  if stage.exercises then
    for _, ex in ipairs(stage.exercises) do
      for _, p in ipairs(ex.patterns) do
        for _, t in ipairs(tokens(p)) do
          pool[#pool + 1] = t
        end
      end
    end
  else
    for _, w in ipairs(stage.words or {}) do
      pool[#pool + 1] = w
    end
    for _, p in ipairs(stage.patterns or {}) do
      for _, t in ipairs(tokens(p)) do
        pool[#pool + 1] = t
      end
    end
  end
  return pool
end

-- The source's own `availableKeys` field is inconsistent (a string on some
-- stages, missing on others, a literal "..." placeholder on stage 9), so
-- available_keys is computed here instead: the cumulative set of every
-- new_keys introduced through this stage, same convention as
-- typing.lessons.keys_for_stage.
M.STAGES = {}
do
  local seen, cumulative = {}, {}
  for _, stage in ipairs(RAW) do
    for _, k in ipairs(stage.new_keys) do
      if not seen[k] then
        seen[k] = true
        cumulative[#cumulative + 1] = k
      end
    end
    M.STAGES[#M.STAGES + 1] = {
      id = stage.id,
      title = stage.title,
      new_keys = stage.new_keys,
      available_keys = vim.deepcopy(cumulative),
      focus = stage.focus or table.concat(stage.objectives or {}, "; "),
      pool = build_pool(stage),
    }
  end
end

function M.stage_count()
  return #M.STAGES
end

--- Clamped to the valid stage range, same convention as typing.lessons.
function M.get(stage)
  stage = math.max(1, math.min(stage or 1, #M.STAGES))
  return M.STAGES[stage]
end

return M
