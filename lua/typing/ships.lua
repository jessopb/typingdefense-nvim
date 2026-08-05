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

-- pod = { id, kind, label, width, row_offset?, cap_left?, cap_right?, taper? }
--   width: total rendered width INCLUDING the 2 border columns.
--   row_offset: how many rows this pod's 4-line box sits below the ship's
--     highest content (default 0). May be NEGATIVE -- e.g. a bridge raised
--     above the rest of the hull -- M.build normalizes the whole canvas
--     afterwards so nothing is ever clipped, so ship authors never need to
--     hand-balance offsets to stay non-negative. Pods in different column
--     slots never collide regardless of offset.
--   cap_left / cap_right: override character for that side's vertical
--     border (label + word rows only -- top/bottom border rows and any
--     inner border facing a neighboring pod in the same stack always use
--     "|" regardless). Left unset, both default to a plain "|".
--   taper: "left" to draw this pod's outer top/bottom corners as "/" and
--     "\" (converging toward cap_left) instead of the flat "."/"'" corner
--     -- the pointed-nose look.
--
-- `ship_def.pods` is a left-to-right sequence of column slots; a slot is
-- either a single pod table, or `{ stack = { pod, pod, ... } }` -- several
-- pods sharing ONE column slot (same width, required equal across the
-- stack), each independently placed by its own row_offset. Used for a
-- vertical run of engines (top/mid/bottom) behind the hull instead of
-- flanking it left/right.

local function crow(row0)
  return row0 + 1 -- convert a 0-idx canvas row to its 1-idx Lua array slot
end

--- Build a ship's static geometry: the ASCII art (word rows left BLANK --
--- callers overlay live word text and own its color/state every render,
--- the same way defense.lua owns its falling word's text) plus per-pod
--- zone metadata for placing that text.
---@param ship_def table { pods: (pod|{stack: pod[]})[], gap: string, antenna: string|nil, antenna_over: string|nil }
---@return string[] art_lines
---@return table[] zones  { id, kind, label, row (0-idx into art_lines, the
---   word row), col_start, col_end (0-idx interior span, end exclusive) }
function M.build(ship_def)
  local gap = ship_def.gap or ""

  -- Flatten pods and pod-stacks into one list of { pod, col, row0 } --
  -- everything in one slot shares a column; nothing shares a row unless
  -- the ship data says so. `slot_members` groups those same entries back
  -- by slot, and `gap_cols` remembers where each slot boundary fell, so
  -- the gap-fill pass below can draw `gap` only on rows actually adjacent
  -- to a pod on one side or the other -- not down the ship's full height.
  local flat, slot_members, gap_cols, col = {}, {}, {}, 0
  for _, slot in ipairs(ship_def.pods) do
    local members = slot.stack or { slot }
    local this_slot = {}
    for _, pod in ipairs(members) do
      local f = { pod = pod, col = col, row0 = pod.row_offset or 0 }
      flat[#flat + 1] = f
      this_slot[#this_slot + 1] = f
    end
    slot_members[#slot_members + 1] = this_slot
    col = col + members[1].width
    if #gap > 0 then
      gap_cols[#gap_cols + 1] = col
    end
    col = col + #gap
  end
  local width = col - #gap -- undo the trailing gap counted after the last slot

  -- The antenna sits one row above its target pod's own row0, wherever
  -- that landed -- fold it into the normalization pass below so it's never
  -- the thing that ends up clipped off the top of the canvas.
  local antenna_row0 = nil
  if ship_def.antenna then
    for _, f in ipairs(flat) do
      if f.pod.id == ship_def.antenna_over then
        antenna_row0 = f.row0 - 1
      end
    end
  end

  local min_row0 = antenna_row0 or math.huge
  local max_bottom = 0
  for _, f in ipairs(flat) do
    min_row0 = math.min(min_row0, f.row0)
    max_bottom = math.max(max_bottom, f.row0 + 4)
  end
  local shift = -min_row0 -- makes the topmost content land on row 0
  local height = shift + max_bottom

  local canvas = {}
  for r = 1, height do
    canvas[r] = string.rep(" ", width)
  end

  -- Fill each slot boundary with `gap`, but only on rows that actually
  -- touch a pod on the left or the right -- a row where neither neighbor
  -- has anything gets left blank rather than drawn as a connector to
  -- nothing. Ties adjacent pods together without drawing a full-height
  -- band past whichever one is shorter (e.g. nose next to the taller
  -- raised bridge).
  local function touches(members, row0)
    for _, f in ipairs(members) do
      if row0 >= f.row0 + shift and row0 <= f.row0 + shift + 3 then
        return true
      end
    end
    return false
  end
  if #gap > 0 then
    for i, gcol in ipairs(gap_cols) do
      if gcol < width then
        local left_slot, right_slot = slot_members[i], slot_members[i + 1]
        for r = 1, height do
          local row0 = r - 1
          if touches(left_slot, row0) or touches(right_slot, row0) then
            canvas[r] = effects.set_col(canvas[r], gcol, gap)
          end
        end
      end
    end
  end

  local zones = {}
  for _, f in ipairs(flat) do
    local pod, c, row0 = f.pod, f.col, f.row0 + shift
    local interior = pod.width - 2
    local left_char = pod.cap_left or "|"
    local right_char = pod.cap_right or "|"

    local top, bottom
    if pod.taper == "left" then
      top = "/" .. string.rep("-", interior) .. "."
      bottom = "\\" .. string.rep("-", interior) .. "'"
    else
      top = "." .. string.rep("-", interior) .. "."
      bottom = "'" .. string.rep("-", interior) .. "'"
    end
    local label = left_char .. M.center(pod.label, interior) .. right_char
    local word_row = left_char .. string.rep(" ", interior) .. right_char

    canvas[crow(row0)] = effects.set_col(canvas[crow(row0)], c, top)
    canvas[crow(row0 + 1)] = effects.set_col(canvas[crow(row0 + 1)], c, label)
    canvas[crow(row0 + 2)] = effects.set_col(canvas[crow(row0 + 2)], c, word_row)
    canvas[crow(row0 + 3)] = effects.set_col(canvas[crow(row0 + 3)], c, bottom)

    zones[#zones + 1] = {
      id = pod.id,
      kind = pod.kind,
      label = pod.label,
      row = row0 + 2, -- 0-idx word row within the returned art_lines
      col_start = c + 1,
      col_end = c + 1 + interior,
    }
  end

  if antenna_row0 then
    for _, f in ipairs(flat) do
      if f.pod.id == ship_def.antenna_over then
        local r = crow(antenna_row0 + shift)
        canvas[r] = effects.set_col(canvas[r], f.col, M.center(ship_def.antenna, f.pod.width))
        break
      end
    end
  end

  return canvas, zones
end

--- The ship's rear engine cluster, sized to its tier: 1 engine for small
--- hulls (flush with the rest, no protrusion), 2 for mid-size hulls
--- (top/bottom only, row_offset -4/+4 -- both stick out, with a gap in
--- between), or 3 for the largest hulls (top/middle/bottom, the middle one
--- filling that gap flush with the hull). All share cap_right = ">" so
--- however many are present, their trailing edges read as one
--- roughly-vertical line down the stern. Labeled/numbered top to bottom
--- (ENGINE-1, ENGINE-2, ...) rather than by position name; a lone engine
--- stays unnumbered since there's nothing to distinguish it from.
---@param n integer 1, 2, or 3
local function engine_stack(n)
  local offsets = { { -4 }, { 0 }, { 4 } }
  if n == 2 then
    offsets = { { -4 }, { 4 } }
  elseif n == 1 then
    offsets = { { 0 } }
  end
  local pods = {}
  for i, o in ipairs(offsets) do
    local id, label = "engine_" .. i, "ENGINE-" .. i
    if n == 1 then
      id, label = "engine", "ENGINE"
    end
    pods[i] = { id = id, kind = "engine", label = label, width = 14, row_offset = o[1], cap_right = ">" }
  end
  if n == 1 then
    return pods[1]
  end
  return { stack = pods }
end

local function nose()
  return { id = "nose", kind = "nose", label = "NOSE", width = 10, cap_left = "<", taper = "left" }
end

-- The boss campaign roster (see :TypingBoss), smallest/weakest first: each
-- entry adds a pair of critical parts over the last, from a 3-pod skiff up
-- to the 10-pod leviathan. Every ship reads left to right like a real
-- hull -- a pointed nose (taper = "left") leads, the bridge rides
-- row_offset = -2 above the rest (a raised command deck rather than
-- sitting flush), and the hull ends in a rear engine cluster sized to the
-- ship's tier: skiff/interceptor/corvette get a single flush engine,
-- frigate/gunship/destroyer/battlecruiser get 2 (sticking out top and
-- bottom), and carrier/juggernaut/leviathan get the full 3-engine stack.
-- All keep the shared "===" gaps and a ".^." antenna over "bridge".
M.ships = {
  cruiser = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      engine_stack(2),
    },
  },

  -- 3 pods -- the smallest boss: nose, raised bridge, a single engine --
  -- no other hull pods between them.
  skiff = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      engine_stack(1),
    },
  },

  -- 4 pods -- same tier as skiff, a forward weapon added ahead of the bridge.
  interceptor = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "weapon", kind = "weapon", label = "WEAPON", width = 12 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      engine_stack(1),
    },
  },

  -- 5 pods -- interceptor's sibling: shield instead of a weapon.
  corvette = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "weapon", kind = "weapon", label = "WEAPON", width = 12 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      engine_stack(1),
    },
  },

  -- 5 pods -- the first 2-engine tier: shield up front, twin engines
  -- (upper/lower, sticking out top and bottom) at the stern.
  frigate = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      engine_stack(2),
    },
  },

  -- 6 pods -- weapons flank the raised bridge on both sides now.
  gunship = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "weapon_1", kind = "weapon", label = "WEAPON-1", width = 12 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "weapon_2", kind = "weapon", label = "WEAPON-2", width = 12 },
      engine_stack(2),
    },
  },

  -- 6 pods -- gunship's sibling: one weapon traded for a shield generator.
  destroyer = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "weapon", kind = "weapon", label = "WEAPON", width = 12 },
      engine_stack(2),
    },
  },

  -- 7 pods -- a shield generator joins the flanking weapons, still 2 engines.
  battlecruiser = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "weapon_1", kind = "weapon", label = "WEAPON-1", width = 12 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "weapon_2", kind = "weapon", label = "WEAPON-2", width = 12 },
      engine_stack(2),
    },
  },

  -- 9 pods -- the first 3-engine tier: twin hangars outboard of the
  -- weapons, and the full upper/mid/lower engine stack at the stern.
  carrier = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "hangar_1", kind = "hangar", label = "HANGAR-1", width = 12 },
      { id = "weapon_1", kind = "weapon", label = "WEAPON-1", width = 12 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "hangar_2", kind = "hangar", label = "HANGAR-2", width = 12 },
      engine_stack(3),
    },
  },

  -- 9 pods -- carrier's sibling, traded in for armor plating instead.
  juggernaut = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "armor_1", kind = "armor", label = "ARMOR-1", width = 12 },
      { id = "weapon_1", kind = "weapon", label = "WEAPON-1", width = 12 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "weapon_2", kind = "weapon", label = "WEAPON-2", width = 12 },
      { id = "armor_2", kind = "armor", label = "ARMOR-2", width = 12 },
      engine_stack(3),
    },
  },

  -- 10 pods -- the largest, baddest boss: a reactor and sensor array join
  -- the full weapon/shield/armor loadout around the raised bridge, and the
  -- full 3-engine stack at the stern.
  leviathan = {
    gap = "===",
    antenna = ".^.",
    antenna_over = "bridge",
    pods = {
      nose(),
      { id = "reactor", kind = "reactor", label = "REACTOR", width = 12 },
      { id = "weapon_1", kind = "weapon", label = "WEAPON-1", width = 12 },
      { id = "shield", kind = "shield", label = "SHIELD GEN", width = 14 },
      { id = "bridge", kind = "bridge", label = "BRIDGE", width = 14, row_offset = -2 },
      { id = "weapon_2", kind = "weapon", label = "WEAPON-2", width = 12 },
      { id = "sensor", kind = "sensor", label = "SENSOR", width = 12 },
      engine_stack(3),
    },
  },
}

--- Campaign order for the boss roster, smallest/weakest first -- the order
--- future level-based boss selection (task: "Design N-boss progression
--- system") should walk through as the player advances.
M.CAMPAIGN = {
  "skiff",
  "interceptor",
  "corvette",
  "frigate",
  "gunship",
  "destroyer",
  "battlecruiser",
  "carrier",
  "juggernaut",
  "leviathan",
}

--- Defaults to "cruiser" if `name` is nil or unknown.
function M.get(name)
  return M.ships[name] or M.ships.cruiser
end

return M
