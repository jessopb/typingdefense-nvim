local M = {}

-- Progressive key-introduction order, home row outward, two keys (mirrored on
-- each hand) per stage. Each stage is cumulative with all previous stages.
M.STAGES = {
  { "f", "j" },
  { "d", "k" },
  { "s", "l" },
  { "a", ";" },
  { "g", "h" },
  { "r", "u" },
  { "e", "i" },
  { "w", "o" },
  { "q", "p" },
  { "v", "m" },
  { "c", "," },
  { "x", "." },
  { "z", "/" },
  { "t", "y" },
  { "b", "n" },
}

function M.stage_count()
  return #M.STAGES
end

function M.default_stage()
  return 1
end

-- Returns the cumulative set of keys unlocked through `stage`, and the pair
-- of keys freshly introduced at that stage (which get extra practice weight).
-- Floored so a fractional stage (e.g. `tonumber("2.5")` from a command
-- argument) still lands on a real array index instead of missing it.
function M.keys_for_stage(stage)
  stage = math.floor(math.max(1, math.min(stage, #M.STAGES)))
  local keys = {}
  for i = 1, stage do
    for _, k in ipairs(M.STAGES[i]) do
      table.insert(keys, k)
    end
  end
  return keys, M.STAGES[stage]
end

local function random_word(keys, focus, min_len, max_len)
  local len = math.random(min_len, max_len)
  local chars = {}
  -- guarantee at least one occurrence of a freshly-introduced key so new
  -- keys actually get drilled instead of drowning in review material.
  local focus_idx = math.random(len)
  for i = 1, len do
    if i == focus_idx then
      chars[i] = focus[math.random(#focus)]
    else
      chars[i] = keys[math.random(#keys)]
    end
  end
  return table.concat(chars)
end

-- opts: { word_count = n, word_length = { min, max } }
function M.generate(stage, opts)
  opts = opts or {}
  local count = opts.word_count or 30
  local min_len, max_len = 2, 5
  if opts.word_length then
    min_len, max_len = opts.word_length[1], opts.word_length[2]
    if min_len > max_len then
      min_len, max_len = max_len, min_len
    end
  end

  local keys, focus = M.keys_for_stage(stage)
  local words = {}
  for i = 1, count do
    words[i] = random_word(keys, focus, min_len, max_len)
  end
  return table.concat(words, " ")
end

return M
