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
-- a plain (non-task) bullet. Requires the marker to be its own word (end of
-- line or followed by whitespace) so prose like "DONE-ish workaround" isn't
-- misread as the DONE marker -- Lua's %f frontier alone would backtrack
-- across the trailing hyphen and accept just that.
local function marker(header_line)
  if not graph.is_bullet_line(header_line) then
    return nil
  end
  local content = header_line:match("^[ \t]*%-%s*(.*)$")
  local word, rest = content:match("^(%u[%u%-]*)(.*)$")
  if word and (rest == "" or rest:match("^%s")) then
    return word
  end
  return nil
end

local function is_done(header_line)
  local m = marker(header_line)
  return m ~= nil and DONE_MARKERS[m] == true
end

-- Walk every journal/page file, calling `on_file(path, kind, name, lines)`
-- for each. `kind` is "journal" or "page", `name` is the display name
-- (journal date or page name) for that source file.
local function each_file(root, on_file)
  for _, entry in ipairs({ { dir = graph.journal_dir(root), kind = "journal" }, { dir = graph.pages_dir(root), kind = "page" } }) do
    for _, fname in ipairs(graph.list_md_files(entry.dir)) do
      local path = entry.dir .. "/" .. fname
      on_file(path, entry.kind, graph.filename_display(fname), graph.read_lines(path))
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
-- A block with both a SCHEDULED and a DEADLINE line is reported once, with
-- date_t set to the earlier of the two -- so it's treated as due as soon as
-- either one is, rather than only the first line encountered in the file.
function M.scan(root)
  local items = {}
  each_file(root, function(path, kind, name, lines)
    local by_header = {}
    local order = {}
    for i, line in ipairs(lines) do
      local date_t = marker_date(line)
      if date_t then
        local header = outline.header_for(lines, i)
        local item = by_header[header]
        if not item then
          item = { source = path, kind = kind, name = name, header = header, lines = lines, date_t = date_t, done = is_done(lines[header]) }
          by_header[header] = item
          table.insert(order, item)
        else
          item.date_t = math.min(item.date_t, date_t)
        end
      end
    end
    for _, item in ipairs(order) do
      table.insert(items, item)
    end
  end)
  return items
end

-- Which pseudo-pages currently have something to show: { Scheduled = bool,
-- [marker] = bool, ... }. Used by pages.completion_names() to decide which
-- pseudo-pages to list -- computed with a single pass over the graph rather
-- than calling M.due()/M.by_marker() once per pseudo-page (10 full scans).
function M.presence(root, now)
  local t = os.date("*t", now or os.time())
  local cutoff = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })

  local present = {}
  local remaining_markers = {}
  for _, status in ipairs(M.MARKERS) do
    remaining_markers[status] = true
  end

  each_file(root, function(_, _, _, lines)
    for i, line in ipairs(lines) do
      local m = marker(line)
      if m and remaining_markers[m] then
        present[m] = true
        remaining_markers[m] = nil
      end

      if not present.Scheduled then
        local date_t = marker_date(line)
        if date_t and date_t <= cutoff and not is_done(lines[outline.header_for(lines, i)]) then
          present.Scheduled = true
        end
      end
    end
  end)

  return present
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
