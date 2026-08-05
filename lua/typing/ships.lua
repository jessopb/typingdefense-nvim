local effects = require("typing.effects")

-- Data-driven ship geometry for :TypingBoss. A ship is a row of "pods"
-- (engine/bridge/shield/etc.) joined by a gap string; each pod renders as a
-- 4-line box (top border / label / blank word row / bottom border). This
-- is the reusable framework piece: adding a new boss ship means describing
-- pods here, not hand-drawing new ASCII art.
local M = {}

--- Center `text` in `width` columns, space-padded (extra pad goes right).
--- Truncated from the right if too long. Lua has no string.center.
function M.center(text, width)
  text = text or ""
  if #text >= width then
    return text:sub(1, width)
  end
  local pad = width - #text
  local left = math.floor(pad / 2)
  local right = pad - left
  return string.rep(" ", left) .. text .. string.rep(" ", right)
end

-- pod = { id, kind, label, width, cap? }
--   width: total rendered width INCLUDING the 2 border columns.
--   cap: override char for THIS pod's ship-outer vertical border (label +
--     word rows only -- top/bottom border rows and any inner border facing
--     a neighboring pod always use "|"/"."/"'" regardless of cap). Only
--     meaningful on the first pod's left edge / last pod's right edge; a
--     pod that is neither first nor last ignores `cap` even if set.

--- Build a ship's static geometry: the ASCII art (word rows left BLANK --
--- callers overlay live word text and own its color/state every render,
--- the same way defense.lua owns its falling word's text) plus per-pod
--- zone metadata for placing that text.
---@param ship_def table { pods: pod[], gap: string, antenna: string|nil, antenna_over: string|nil }
---@return string[] art_lines
---@return table[] zones  { id, kind, label, row (0-idx into art_lines, the
---   word row), col_start, col_end (0-idx interior span, end exclusive) }
function M.build(ship_def)
  local pods = ship_def.pods
  local gap = ship_def.gap or ""
  local n = #pods

  local tops, labels, words_row, bottoms = {}, {}, {}, {}
  local zones = {}
  local col = 0

  for i, pod in ipairs(pods) do
    local interior = pod.width - 2
    local left_char, right_char = "|", "|"
    if i == 1 and pod.cap then
      left_char = pod.cap
    end
    if i == n and pod.cap then
      right_char = pod.cap
    end

    tops[i] = "." .. string.rep("-", interior) .. "."
    labels[i] = left_char .. M.center(pod.label, interior) .. right_char
    words_row[i] = left_char .. string.rep(" ", interior) .. right_char
    bottoms[i] = "'" .. string.rep("-", interior) .. "'"

    zones[#zones + 1] = {
      id = pod.id,
      kind = pod.kind,
      label = pod.label,
      row = nil, -- filled in once we know whether there's an antenna line
      col_start = col + 1,
      col_end = col + 1 + interior,
    }

    col = col + pod.width + #gap
  end

  local top_line = table.concat(tops, gap)
  local art_lines = { top_line, table.concat(labels, gap), table.concat(words_row, gap), table.concat(bottoms, gap) }
  local word_row_idx0 = 2 -- 0-idx word row within art_lines, before any antenna offset

  if ship_def.antenna then
    local width = #top_line
    local running, target_start, target_end = 0, nil, nil
    for _, pod in ipairs(pods) do
      if pod.id == ship_def.antenna_over then
        target_start, target_end = running, running + pod.width
      end
      running = running + pod.width + #gap
    end
    local antenna_line = string.rep(" ", width)
    if target_start then
      local span = target_end - target_start
      antenna_line = effects.set_col(antenna_line, target_start, M.center(ship_def.antenna, span))
    end
    table.insert(art_lines, 1, antenna_line)
    word_row_idx0 = word_row_idx0 + 1
  end

  for _, z in ipairs(zones) do
    z.row = word_row_idx0
  end

  return art_lines, zones
end

M.ships = {
  cruiser = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      { id = "engine_l", kind = "engine", label = "ENGINE-L", width = 12, cap = "<" },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "engine_r", kind = "engine", label = "ENGINE-R", width = 12, cap = ">" },
    },
  },
}

--- Defaults to "cruiser" if `name` is nil or unknown.
function M.get(name)
  return M.ships[name] or M.ships.cruiser
end

return M
