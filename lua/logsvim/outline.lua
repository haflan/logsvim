local graph = require("logsvim.graph")
local config = require("logsvim.config")

-- Shared block/ancestor/grouping helpers for anything that scans the graph
-- for "interesting" lines (a SCHEDULED/DEADLINE marker in schedule.lua, a
-- [[Page]] reference in pages.lua) and wants to render the matching bullets
-- grouped by shared context and re-indented to fit that context, rather
-- than duplicated with their raw source indentation.

local M = {}

local function indent_len(line)
  return #(line:match("^[ \t]*"))
end

-- Collect the block starting at line `i`: its own line plus every
-- more-deeply-indented line below it. Blank lines are passed through
-- without ending the block (they may just be a paragraph break within its
-- contents), but trimmed off the end. Returns the block's lines and the
-- index of the first line after it (its "extent").
local function collect_block(lines, i)
  local indent = indent_len(lines[i])
  local block = { lines[i] }
  local j = i + 1
  while j <= #lines do
    if lines[j] == "" or indent_len(lines[j]) > indent then
      table.insert(block, lines[j])
      j = j + 1
    else
      break
    end
  end
  while #block > 0 and block[#block] == "" do
    table.remove(block)
  end
  return block, j
end

-- Every ancestor of line `i`, top-down (shallowest first, immediate parent
-- last); empty if `i` is already top-level. Repeatedly finds the nearest
-- preceding non-blank line with a strictly smaller indent than a running
-- reference (updated on each hit), so multi-level nesting resolves fully
-- rather than stopping at the single nearest shallower line.
local function ancestor_chain(lines, i)
  local chain = {}
  local ref = indent_len(lines[i])
  local j = i - 1
  while j >= 1 and ref > 0 do
    if lines[j] ~= "" and indent_len(lines[j]) < ref then
      table.insert(chain, 1, j)
      ref = indent_len(lines[j])
    end
    j = j - 1
  end
  return chain
end

-- Resolve a non-bullet line (e.g. a SCHEDULED/DEADLINE property line) to
-- the bullet header it belongs to: the deepest ancestor found by
-- ancestor_chain, or `i` itself if none (shouldn't happen for a genuinely
-- nested property line).
function M.header_for(lines, i)
  local chain = ancestor_chain(lines, i)
  return chain[#chain] or i
end

local function rebase(line, cut, base)
  if line == "" then
    return ""
  end
  return base .. line:sub(cut + 1)
end

-- Build the merged/absorbed ancestor trie for `headers` (a file's list of
-- "interesting" bullet-header line indices, already known to belong to
-- `lines`) and flatten it into re-indented, grouped-by-shared-context
-- lines: a header whose ancestor chain overlaps another header's
-- already-rendered subtree is absorbed (skipped) rather than duplicated,
-- and siblings sharing a parent render that parent once. Indentation is
-- recomputed from each node's depth in this tree via
-- graph.sub_indent_for(), not copied from the source, so it's always
-- correct regardless of how deep the header lived originally.
function M.group(lines, headers)
  local unique, seen = {}, {}
  for _, h in ipairs(headers) do
    if not seen[h] then
      seen[h] = true
      table.insert(unique, h)
    end
  end
  table.sort(unique)

  local roots, node_by_index, absorbed_until = {}, {}, 0
  for _, header in ipairs(unique) do
    if header >= absorbed_until then
      local chain = ancestor_chain(lines, header)
      table.insert(chain, header)

      local parent = nil
      for _, idx in ipairs(chain) do
        local node = node_by_index[idx]
        if not node then
          node = { line = idx, children = {} }
          node_by_index[idx] = node
          table.insert(parent and parent.children or roots, node)
        end
        parent = node
      end

      -- `parent` is now the node for `header` itself (the chain's last
      -- element), since the loop above always ends there.
      local block, extent = collect_block(lines, header)
      parent.block = block
      absorbed_until = math.max(absorbed_until, extent)
    end
  end

  local out = {}
  local function render(node, depth)
    local base = graph.sub_indent_for(config.options.indentation):rep(depth)
    local cut = indent_len(lines[node.line])
    for _, l in ipairs(node.block or { lines[node.line] }) do
      table.insert(out, rebase(l, cut, base))
    end
    for _, child in ipairs(node.children) do
      render(child, depth + 1)
    end
  end
  for ri, root in ipairs(roots) do
    if ri > 1 then
      table.insert(out, "")
    end
    render(root, 0)
  end
  return out
end

-- Internal accessors for the test suite only; not part of the public API.
M._test = {
  collect_block = collect_block,
  ancestor_chain = ancestor_chain,
}

return M
