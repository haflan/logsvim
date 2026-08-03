local index = require("logsvim.index")
local graph = require("logsvim.graph")

local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end

function Source:is_available()
  return true
end

function Source:get_trigger_characters()
  return { "[" }
end

-- Anything up to the cursor, excluding brackets: the text typed so far
-- inside an open "[[...]]".
function Source:get_keyword_pattern()
  return [[[^][]*]]
end

function Source:complete(params, callback)
  local before = params.context.cursor_before_line
  if not before:match("%[%[[^%[%]]*$") then
    callback({ items = {}, isIncomplete = false })
    return
  end

  -- Autopairs (if installed) already dropped a "]]" after the cursor when
  -- "[[" was typed; only add our own if there isn't one there already, so
  -- confirming a completion never doubles it up.
  local after = params.context.cursor_after_line
  local closing = after:match("^%]%]") and "" or "]]"

  local items = {}
  for _, name in ipairs(index.names(graph.root())) do
    table.insert(items, { label = name, insertText = name .. closing, filterText = name })
  end
  callback({ items = items, isIncomplete = true })
end

return Source
