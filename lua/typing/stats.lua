local M = {}

-- Gross WPM: standard "5 chars = 1 word" convention, based on total chars
-- typed over elapsed time.
function M.wpm(total_chars, elapsed_seconds)
  if elapsed_seconds <= 0 then
    return 0
  end
  return (total_chars / 5) / (elapsed_seconds / 60)
end

function M.accuracy(correct, incorrect)
  local total = correct + incorrect
  if total == 0 then
    return 100
  end
  return (correct / total) * 100
end

return M
