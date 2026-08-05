local M = {}

local ns = vim.api.nvim_create_namespace("typing.nvim.keyboard")

-- Deliberately NOT physically staggered (real keyboards shift each row by
-- ~half a key) -- keys line up in straight columns instead, per spec.
M.ROWS = {
  { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "{", "}" },
  { "A", "S", "D", "F", "G", "H", "J", "K", "L", ":", "\"" },
  { "Z", "X", "C", "V", "B", "N", "M", "<", ">", "?" },
}

M.HOME_ROW = 2

-- Only the 8 true resting-finger keys get the finger-outline by default --
-- not every physical home-row key. G/H (index-finger reach-ins) and the
-- shifted apostrophe stay plain squares.
M.HOME_KEYS = { A = true, S = true, D = true, F = true, J = true, K = true, L = true, [":"] = true }

local CELL_WIDTH = 5 -- " ___ " / "/ A \" / "\___/"

--- Render a single key as a 3-line ASCII cell.
--- Home-row keys get slanted "/" "\" sides (the finger-rest outline);
--- everything else gets straight "|" sides. Top/bottom bar is the same
--- shape either way.
---@param letter string single character to draw
---@param opts table|nil { home: boolean }
---@return string top, string mid, string bottom  each CELL_WIDTH chars wide
function M.drawKey(letter, opts)
  opts = opts or {}
  local home = opts.home
  local left = home and "/" or "|"
  local right = home and "\\" or "|"
  local top = " ___ "
  local mid = string.format("%s %s %s", left, letter, right)
  local bottom = (home and "\\___/" or "|___|")
  return top, mid, bottom
end

--- Render one keyboard row (list of letters) as 3 joined lines.
---@param letters string[]
---@param is_home fun(ch: string): boolean
---@return string top, string mid, string bottom
local function render_row(letters, is_home)
  local tops, mids, bots = {}, {}, {}
  for _, ch in ipairs(letters) do
    local top, mid, bottom = M.drawKey(ch, { home = is_home(ch) })
    table.insert(tops, top)
    table.insert(mids, mid)
    table.insert(bots, bottom)
  end
  return table.concat(tops, " "), table.concat(mids, " "), table.concat(bots, " ")
end

--- Render the full 3-row keyboard as a flat list of lines (9 lines total:
--- top/mid/bottom for each of the 3 key rows), ready to drop into a buffer.
---
--- `opts.hint` optionally relocates the finger-outline for a single-finger
--- preview: `{ at = "U", from = "J" }` draws "J" as a plain square (the
--- finger has left home) and draws "U" with the finger-outline instead
--- (marked in `cells` so the caller can highlight it, e.g. yellow). This is
--- a manual one-off for now -- the general one-to-many finger dictionary
--- (which key relocates to which on its own) is still future work.
---
--- `opts.window_width` optionally centers the whole diagram: every line gets
--- the same leading pad (computed from the widest row, top-row QWERTY),
--- which keeps columns aligned across rows rather than centering each row
--- individually and reintroducing a stagger.
---@param opts table|nil { hint: { at: string, from: string }, window_width: integer }
---@return string[] lines
---@return table cells  cells[i] = { row=1..3, letter=ch, home=bool, hint=bool,
---                                  line=buffer-relative 0-idx line of the
---                                  mid row, col_start=0-idx, col_end=0-idx }
---   `cells` is metadata for the highlighter: enough to build an extmark per
---   key without re-deriving column math from the rendered strings.
function M.render(opts)
  opts = opts or {}
  local hint = opts.hint

  local function is_home(ch)
    if hint then
      if ch == hint.from then
        return false
      end
      if ch == hint.at then
        return true
      end
    end
    return M.HOME_KEYS[ch] or false
  end

  local lines = {}
  local cells = {}
  local line_no = 0

  for row_idx, row in ipairs(M.ROWS) do
    local top, mid, bottom = render_row(row, is_home)
    table.insert(lines, top)
    table.insert(lines, mid)
    table.insert(lines, bottom)

    local col = 0
    for _, ch in ipairs(row) do
      table.insert(cells, {
        row = row_idx,
        letter = ch,
        home = is_home(ch),
        hint = hint ~= nil and ch == hint.at,
        line = line_no + 1, -- the mid line, where the letter itself sits
        col_start = col,
        col_end = col + CELL_WIDTH,
      })
      col = col + CELL_WIDTH + 1 -- +1 for the joining space
    end

    line_no = line_no + 3
  end

  if opts.window_width then
    local max_w = 0
    for _, l in ipairs(lines) do
      max_w = math.max(max_w, #l)
    end
    local pad = math.max(math.floor((opts.window_width - max_w) / 2), 0)
    if pad > 0 then
      local prefix = string.rep(" ", pad)
      for i, l in ipairs(lines) do
        lines[i] = prefix .. l
      end
      for _, cell in ipairs(cells) do
        cell.col_start = cell.col_start + pad
        cell.col_end = cell.col_end + pad
      end
    end
  end

  return lines, cells
end

--- Link the diagram's highlight groups to the configured targets. Safe to
--- call repeatedly; kept here as a convenience alias since callers that only
--- need the keyboard widget (e.g. the preview command) shouldn't have to
--- know about the shared highlights module.
function M.setup_highlights()
  require("typing.highlights").setup()
end

--- Paint the `hint` cell(s) from `render()`'s second return value onto
--- `bufnr` at `line_offset` (0-idx line the diagram's first line starts
--- at). Covers all 3 lines of each hinted key so the whole outline -- not
--- just the letter -- turns yellow.
---@param bufnr integer
---@param cells table   second return value of M.render()
---@param line_offset integer|nil defaults to 0
function M.apply_highlights(bufnr, cells, line_offset)
  line_offset = line_offset or 0
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, cell in ipairs(cells) do
    if cell.hint then
      for _, dl in ipairs({ -1, 0, 1 }) do
        vim.api.nvim_buf_set_extmark(bufnr, ns, line_offset + cell.line + dl, cell.col_start, {
          end_col = cell.col_end,
          hl_group = "TypingKeyHint",
          priority = 300,
        })
      end
    end
  end
end

return M
