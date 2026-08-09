local graph = require("logsvim.graph")
local outline = require("logsvim.outline")

-- Finds Logseq task blocks anywhere in the graph (journals and pages) for
-- the pseudo-pages pages.lua serves: "Scheduled" (SCHEDULED:/DEADLINE:
-- blocks due today or earlier, not yet done) and one page per task marker
-- (TODO/DOING/NOW/LATER/WAITING/IN-PROGRESS/DONE/CANCELED/CANCELLED).

local M = {}

-- Every task marker Logseq recognizes, in the order its own task-cycling
-- UI presents them.
M.MARKERS = { "TODO", "DOING", "NOW", "LATER", "WAITING", "IN-PROGRESS", "DONE", "CANCELED", "CANCELLED" }

-- Logseq always writes SCHEDULED/DEADLINE as an active timestamp in ISO
-- form ("<2026-08-10 Mon ...>"), independent of :journal/file-name-format.
local function marker_date(line)
  local y, mo, d = line:match("SCHEDULED%s*:%s*<(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    y, mo, d = line:match("DEADLINE%s*:%s*<(%d%d%d%d)%-(%d%d)%-(%d%d)")
  end
  if not y then
    return nil
  end
  -- Noon avoids DST edge cases nudging the timestamp onto the wrong
  -- calendar day when compared against another noon-anchored timestamp.
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
end

local DONE_MARKERS = { DONE = true, CANCELED = true, CANCELLED = true }

-- Logseq's task marker (TODO/DOING/NOW/LATER/WAITING/IN-PROGRESS/DONE/
-- CANCELED/CANCELLED) if the block's own first line has one, else nil for
-- a plain (non-task) bullet.
local function marker(header_line)
  local content = header_line:match("^[ \t]*%-%s*(.*)$")
  if not content then
    return nil
  end
  return content:match("^(%u[%u%-]*)%f[%A]")
end

local function is_done(header_line)
  local m = marker(header_line)
  return m ~= nil and DONE_MARKERS[m] == true
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  return lines
end

local function list_md_files(dir)
  local files = {}
  local ok, entries = pcall(vim.fn.readdir, dir)
  if ok and entries then
    for _, fname in ipairs(entries) do
      if fname:match("%.md$") then
        table.insert(files, fname)
      end
    end
  end
  table.sort(files)
  return files
end

-- Walk every journal/page file, calling `on_file(path, kind, name, lines)`
-- for each. `kind` is "journal" or "page", `name` is the display name
-- (journal date or page name) for that source file.
local function each_file(root, on_file)
  for _, entry in ipairs({ { dir = graph.journal_dir(root), kind = "journal" }, { dir = graph.pages_dir(root), kind = "page" } }) do
    for _, fname in ipairs(list_md_files(entry.dir)) do
      local path = entry.dir .. "/" .. fname
      on_file(path, entry.kind, graph.filename_display(fname), read_lines(path))
    end
  end
end

-- Group a flat list of `{ source, kind, name, lines, header }` matches by
-- source file and render each group's headers via outline.group(), sorted
-- by `sort_key(group)` ascending. `group` passed to `sort_key` has `name`,
-- `kind`, and whatever extra fields `extra(group, item)` folds in (e.g. a
-- running minimum due-date).
local function group_matches(matches, sort_key, extra)
  local by_source, order = {}, {}
  for _, item in ipairs(matches) do
    local g = by_source[item.source]
    if not g then
      g = { name = item.name, kind = item.kind, lines = item.lines, headers = {} }
      by_source[item.source] = g
      table.insert(order, g)
    end
    table.insert(g.headers, item.header)
    if extra then
      extra(g, item)
    end
  end

  table.sort(order, function(a, b)
    local ka, kb = sort_key(a), sort_key(b)
    if ka ~= kb then
      return ka < kb
    end
    return a.name < b.name
  end)

  local groups = {}
  for _, g in ipairs(order) do
    table.insert(groups, { name = g.name, kind = g.kind, lines = outline.group(g.lines, g.headers) })
  end
  return groups
end

-- Every SCHEDULED/DEADLINE block found anywhere in the graph:
-- { { source = "<path>", kind = "journal"|"page", name = <page/date name>,
--     header = <line index>, lines = <file's lines array>, date_t = <time>,
--     done = bool }, ... }
function M.scan(root)
  local items = {}
  each_file(root, function(path, kind, name, lines)
    local seen = {}
    for i, line in ipairs(lines) do
      local date_t = marker_date(line)
      if date_t then
        local header = outline.header_for(lines, i)
        if not seen[header] then
          seen[header] = true
          table.insert(
            items,
            { source = path, kind = kind, name = name, header = header, lines = lines, date_t = date_t, done = is_done(lines[header]) }
          )
        end
      end
    end
  end)
  return items
end

-- Every not-yet-done SCHEDULED/DEADLINE block whose date is on or before
-- `now` (defaults to the real current time), for the "Scheduled" pseudo-
-- page: grouped by source file and re-indented relative to its ancestor
-- context (see outline.lua), oldest group-due-date first (tracked across
-- all of a group's items, even ones absorbed into another's subtree).
-- Returns { { name = <page/date>, kind = "journal"|"page",
--             lines = {...outline...} }, ... }.
function M.due(root, now)
  local t = os.date("*t", now or os.time())
  local cutoff = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })

  local due = {}
  for _, item in ipairs(M.scan(root)) do
    if item.date_t <= cutoff and not item.done then
      table.insert(due, item)
    end
  end

  local min_date = {}
  return group_matches(due, function(g)
    return min_date[g]
  end, function(g, item)
    min_date[g] = min_date[g] and math.min(min_date[g], item.date_t) or item.date_t
  end)
end

-- Every block anywhere in the graph whose own task marker is exactly
-- `status` (e.g. "LATER", "DONE"), for that status's pseudo-page: grouped
-- by source file and re-indented relative to its ancestor context, sorted
-- by source name. Returns the same shape as M.due().
function M.by_marker(root, status)
  local matches = {}
  each_file(root, function(path, kind, name, lines)
    for i, line in ipairs(lines) do
      if marker(line) == status then
        table.insert(matches, { source = path, kind = kind, name = name, header = i, lines = lines })
      end
    end
  end)

  return group_matches(matches, function(g)
    return g.name
  end)
end

return M
