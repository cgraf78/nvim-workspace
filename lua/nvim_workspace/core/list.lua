local M = {}

function M.islist(value)
  if type(value) ~= "table" then
    return false
  end
  if type(vim.islist) == "function" then
    return vim.islist(value)
  end

  local count = 0
  local max = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > max then
      max = key
    end
  end
  return count == max
end

return M
