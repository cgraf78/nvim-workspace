-- A small in-memory file source that demonstrates the full extension contract.
-- Real index integrations can replace the `paths` table with their backend
-- while keeping the same partial-result, final-result, status, and cancellation
-- behavior.

local M = {}

local function matches_terms(path, terms)
  local candidate = path:lower()
  for _, term in ipairs(terms) do
    if not candidate:find(term:lower(), 1, true) then
      return false
    end
  end
  return true
end

local function absolute(root, path)
  if path:sub(1, 1) == "/" then
    return path
  end
  return root:gsub("/$", "") .. "/" .. path
end

function M.register(options)
  options = options or {}
  local workspace = require("nvim_workspace")
  local paths = assert(options.paths, "file-source requires options.paths")
  local name = options.name or "Example index"

  return workspace.register_file_source(function(prompt, done, root, ctx)
    local canceled = false

    -- Scheduling mirrors an asynchronous index without introducing a test-only
    -- process or timer. Cancellation can win before any stale callback runs.
    vim.schedule(function()
      if canceled then
        return
      end

      local terms = workspace.path_query_terms(prompt)
      local results = {}
      for _, path in ipairs(paths) do
        if matches_terms(path, terms) then
          results[#results + 1] = absolute(root, path)
        end
      end

      local suffix = #results == 1 and "match" or "matches"
      ctx.status(("%s: %d %s"):format(name, #results, suffix))

      -- A partial callback may make initial results visible immediately. The
      -- final callback is mandatory even when the remaining chunk is empty.
      local split = math.ceil(#results / 2)
      local first = {}
      local remaining = {}
      for index, path in ipairs(results) do
        local target = index <= split and first or remaining
        target[#target + 1] = path
      end
      done(first, { partial = true })
      if not canceled then
        done(remaining)
      end
    end)

    return {
      cancel = function()
        canceled = true
      end,
    }
  end, { name = name })
end

return M
