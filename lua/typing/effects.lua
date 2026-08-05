-- Shared visual/math primitives for the "kinetic" game modes (defense,
-- boss): the bottom turret, its laser beam, the ember-spray explosion, and
-- the skyline. Pure and config-agnostic (no require("typing.config")) so
-- any mode can depend on it without risking a circular require.
local M = {}

function M.round(x)
  if x >= 0 then
    return math.floor(x + 0.5)
  end
  return -math.floor(-x + 0.5)
end

--- Overlay `str` onto `line` at 0-idx column `col`, padding with spaces if
--- the line is too short.
function M.set_col(line, col, str)
  if col < 0 then
    return line
  end
  if #line < col then
    line = line .. string.rep(" ", col - #line)
  end
  local before = line:sub(1, col)
  local after = line:sub(col + 1 + #str)
  return before .. str .. after
end

--- Points along the straight line from (row0,col0) to (row1,col1), one per
--- unit step. Skips the origin (i=0) -- callers use this for a turret beam,
--- where the origin is the turret itself, drawn separately.
function M.laser_cells(row0, col0, row1, col1)
  local dr, dc = row1 - row0, col1 - col0
  local steps = math.max(math.abs(dr), math.abs(dc), 1)
  local pts = {}
  for i = 1, steps do
    local t = i / steps
    pts[#pts + 1] = {
      row = math.floor(row0 + dr * t + 0.5),
      col = math.floor(col0 + dc * t + 0.5),
    }
  end
  return pts
end

-- 5 embers spraying outward from an impact point; `h` is horizontal speed
-- (columns per frame). Vertical drop grows with frame^2 so col-linear +
-- row-quadratic traces a ballistic arc, like a spark falling under gravity.
M.EMBERS = {
  { h = -2 },
  { h = -1 },
  { h = 0 },
  { h = 1 },
  { h = 2 },
}

function M.ember_offset(h, frame)
  local col_offset = M.round(h * frame)
  local row_offset = math.floor((frame * frame) / 3)
  return row_offset, col_offset
end

function M.hex_to_rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

--- Linearly interpolate an RGB hex color: t=0 -> gray_hex, t=1 -> red_hex.
--- Unclamped outside [0,1] (extrapolates).
function M.lerp_color(gray_hex, red_hex, t)
  local gr, gg, gb = M.hex_to_rgb(gray_hex)
  local rr, rg, rb = M.hex_to_rgb(red_hex)
  return string.format(
    "#%02x%02x%02x",
    M.round(gr + (rr - gr) * t),
    M.round(gg + (rg - gg) * t),
    M.round(gb + (rb - gb) * t)
  )
end

--- Net energy change for one keypress -- always -1 (the keypress itself),
--- plus +1.1 more if it was a hit, netting +0.1 per correct keystroke while
--- a miss costs a full bar outright.
function M.energy_delta(hit)
  local delta = -1
  if hit then
    delta = delta + 1.1
  end
  return delta
end

function M.clamp(x, lo, hi)
  if x < lo then
    return lo
  end
  if x > hi then
    return hi
  end
  return x
end

--- A random cell inside a `height` x `width` grid -- the target for a
--- "miss" shot that goes wide instead of hitting anything.
function M.random_point(height, width)
  return {
    row = math.random(0, math.max(height - 1, 0)),
    col = math.random(0, math.max(width - 1, 0)),
  }
end

--- Render `energy` (0..max) as a fixed-width bracketed bar meter,
--- floor-rounded to whole bars (M.LASER_CHAR doubles as the bar glyph --
--- it's the same shot this meter charges). Returns the line plus the
--- [start, end) 0-idx column span of the filled portion, for the caller to
--- highlight.
function M.energy_bar(energy, max, prefix)
  prefix = prefix or "Energy: "
  local bars = M.clamp(math.floor(energy), 0, max)
  local line = prefix .. "[" .. string.rep(M.LASER_CHAR, bars) .. string.rep(" ", max - bars) .. "]"
  local fill_start = #prefix + 1
  return line, fill_start, fill_start + bars
end

function M.build_skyline(width)
  local tile = "_|#|__|##|_|###|__|#|___"
  local s = tile:rep(math.ceil(width / #tile) + 1)
  return s:sub(1, width)
end

M.BASE_GLYPH = "[A]"
M.LASER_CHAR = "|"
M.EMBER_CHAR = "."
M.TARGET_CHAR = "+"

return M
