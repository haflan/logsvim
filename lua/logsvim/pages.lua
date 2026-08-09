local config = require("logsvim.config")
local graph = require("logsvim.graph")
local journal = require("logsvim.journal")
local index = require("logsvim.index")
local outline = require("logsvim.outline")
local schedule = require("logsvim.schedule")

local M = {}

local ns = vim.api.nvim_create_namespace("logsvim_pages")

-- Row (0-indexed) where the editable page-content region always starts:
-- row 0 is the "# name" header, row 1 is a structural blank separator.
-- Pseudo-pages (below) have no editable region at all -- everything from
-- here on is the read-only aggregation.
local CONTENT_START = 2

-- bufnr -> { root, name, mark, pseudo, heading_kind }. `mark` is an extmark
-- at the row (0-indexed) where the read-only aggregation section begins, or
-- nil if the page currently has nothing to show there (in which case
-- everything from CONTENT_START to the end of the buffer is page content).
-- `heading_kind` maps each "### <name>" heading's 1-indexed line number in
-- the buffer to "journal" or "page", so goto_reference() knows which one to
-- jump to. Keyed by line rather than name, since a pseudo-page can list a
-- journal-sourced and a page-sourced group whose names happen to collide
-- (e.g. a page and a journal date with the same display text).
local state = {}

-- "Pseudo-pages": synthetic, read-only pages that don't correspond to a
-- real pages/<name>.md file. Opening one (via :LogsvimPage, or a [[Name]]
-- link + gd/<CR>, exactly like any other page) shows a live, graph-wide
-- aggregation instead of a real file's content + backlinks: "Scheduled"
-- lists SCHEDULED/DEADLINE blocks due today or earlier that aren't done
-- yet, and one page per Logseq task marker (TODO, DOING, NOW, LATER,
-- WAITING, IN-PROGRESS, DONE, CANCELED, CANCELLED) lists every block
-- currently carrying that marker -- anywhere in the graph, grouped by
-- source and re-indented under its ancestor context (see outline.lua).
local PSEUDO_PAGES = {
  Scheduled = function(root)
    return schedule.due(root)
  end,
}
for _, status in ipairs(schedule.MARKERS) do
  PSEUDO_PAGES[status] = function(root)
    return schedule.by_marker(root, status)
  end
end

local function line_references(line, name)
  for match in line:gmatch("%[%[([^%[%]]+)%]%]") do
    if match == name then
      return true
    end
  end
  return false
end

local function list_journal_files(root)
  local files = graph.list_md_files(graph.journal_dir(root))
  -- "YYYY_MM_DD.md" sorts chronologically as a plain string, so descending
  -- string order is newest-first.
  table.sort(files, function(a, b)
    return a > b
  end)
  return files
end

-- Journal blocks that reference "[[name]]", grouped by date, newest first,
-- with each match's ancestor context included and same-context matches
-- merged together (see outline.lua):
-- { { date = "2026_08_01", lines = {...outline...} }, ... }
function M.find_references(root, name)
  local groups = {}
  for _, filename in ipairs(list_journal_files(root)) do
    local lines = graph.read_lines(graph.journal_dir(root) .. "/" .. filename)
    local headers = {}
    for i, line in ipairs(lines) do
      if line_references(line, name) then
        table.insert(headers, i)
      end
    end
    if #headers > 0 then
      table.insert(groups, { date = graph.filename_display(filename), lines = outline.group(lines, headers) })
    end
  end
  return groups
end

local function page_content(root, name)
  local path = graph.pages_dir(root) .. "/" .. name .. ".md"
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return graph.read_lines(path)
end

-- Render a pseudo-page: "# name" plus its aggregated groups, each under a
-- "### <source>" heading, with no editable region at all (content_end ==
-- CONTENT_START unconditionally). `heading_kind` maps each heading's line
-- number to its source's kind ("journal" or "page") for goto_reference() to
-- consult.
local function render_pseudo(root, name, provider)
  local lines = { "# " .. name, "" }
  local heading_kind = {}

  for gi, group in ipairs(provider(root)) do
    if gi > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, "### " .. group.name)
    heading_kind[#lines] = group.kind
    table.insert(lines, "")
    for _, l in ipairs(group.lines) do
      table.insert(lines, l)
    end
  end

  return lines, CONTENT_START, heading_kind
end

-- Render the page view for `name`: for a pseudo-page (see PSEUDO_PAGES
-- above), its live aggregation with no editable region; otherwise an
-- editable header + page content (from pages/<name>.md, if it exists),
-- followed by a read-only "linked references" section listing every
-- journal block that references it, grouped by date. Returns the lines,
-- the 0-indexed row at which the read-only section begins (== #lines if
-- there's nothing to show there), and a heading->kind map for
-- goto_reference() (always "journal" for linked references; per-group for
-- a pseudo-page).
function M.render(root, name)
  if PSEUDO_PAGES[name] then
    return render_pseudo(root, name, PSEUDO_PAGES[name])
  end

  local lines = { "# " .. name, "" }

  local content = page_content(root, name) or {}
  for _, l in ipairs(content) do
    table.insert(lines, l)
  end
  local content_end = #lines

  local groups = M.find_references(root, name)
  if #groups > 0 then
    if #content > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, "## Linked references")
    for _, group in ipairs(groups) do
      table.insert(lines, "")
      table.insert(lines, "### " .. group.date)
      table.insert(lines, "")
      for _, l in ipairs(group.lines) do
        table.insert(lines, l)
      end
    end
  end

  return lines, content_end, {}
end

local function scheme_parts(bufname)
  return bufname:match("^logsvim%-page://(.*)/([^/]+)$")
end

-- Place (or move) the boundary extmark at `content_end`, dropping it
-- entirely if the page currently has no linked-references section.
local function set_mark(bufnr, st, lines, content_end)
  if st.mark then
    vim.api.nvim_buf_del_extmark(bufnr, ns, st.mark)
    st.mark = nil
  end
  if content_end < #lines then
    st.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, content_end, 0, {})
  end
end

function M.read(bufnr)
  local root, name = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  if not root or not name then
    vim.notify("logsvim: invalid page buffer name", vim.log.levels.ERROR)
    return
  end

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false

  local lines, content_end, heading_kind = M.render(root, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  local st = { root = root, name = name, mark = nil, pseudo = PSEUDO_PAGES[name] ~= nil, heading_kind = heading_kind }
  state[bufnr] = st
  set_mark(bufnr, st, lines, content_end)

  config.set_keymap(bufnr, "goto_reference", M.goto_under_cursor, "logsvim: go to reference under cursor")
  config.set_keymap(bufnr, "rename", M.rename_under_cursor, "logsvim: rename page under cursor")
end

-- Write the editable page-content region (above the read-only boundary, if
-- any) to pages/<name>.md, creating the file (and pages/ dir) if it doesn't
-- exist yet. The read-only section is never read from the buffer, and the
-- whole buffer is re-rendered afterwards, so any stray edits made there are
-- discarded rather than persisted. A pseudo-page (see PSEUDO_PAGES) has no
-- editable region at all -- writing one just re-renders it against the
-- current graph state, without touching pages/<name>.md or reindexing.
function M.write(bufnr)
  local st = state[bufnr]
  if not st then
    vim.notify("logsvim: no tracked state for buffer", vim.log.levels.ERROR)
    return
  end

  if not st.pseudo then
    local content_end
    if st.mark then
      content_end = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, st.mark, {})[1]
    else
      content_end = vim.api.nvim_buf_line_count(bufnr)
    end

    local content = {}
    if content_end > CONTENT_START then
      content = vim.api.nvim_buf_get_lines(bufnr, CONTENT_START, content_end, false)
    end

    local path = graph.pages_dir(st.root) .. "/" .. st.name .. ".md"
    if #content > 0 or vim.fn.filereadable(path) == 1 then
      vim.fn.mkdir(graph.pages_dir(st.root), "p")
      local f, err = io.open(path, "w")
      if not f then
        error("logsvim: failed to write " .. path .. ": " .. tostring(err))
      end
      if #content > 0 then
        f:write(table.concat(content, "\n") .. "\n")
      end
      f:close()
    end
  end

  local lines, new_content_end, heading_kind = M.render(st.root, st.name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  st.heading_kind = heading_kind
  set_mark(bufnr, st, lines, new_content_end)

  if not st.pseudo then
    -- Reindex [[Page]] links in the background so a newly-created page (or
    -- new links within it) show up in completion without a manual
    -- :LogsvimReindex.
    index.refresh(st.root)
  end
end

-- Find the nearest "### <name>" heading at or above the cursor and jump to
-- it: a journal date for a normal page's linked references (or a
-- journal-sourced pseudo-page group), or another page for a page-sourced
-- pseudo-page group (see state[bufnr].heading_kind). Exact block navigation
-- isn't supported, but landing on the right day/page gets you close.
function M.goto_reference(bufnr)
  local root = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  local st = state[bufnr]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)
  for i = #lines, 1, -1 do
    local date = lines[i]:match("^### (.+)$")
    if date then
      if st and st.heading_kind and st.heading_kind[i] == "page" then
        M.open(date)
      else
        journal.goto_date(root, date)
      end
      return
    end
  end
  vim.notify("logsvim: no referencing date found above the cursor", vim.log.levels.WARN)
end

function M.open(name)
  if not name or name == "" then
    vim.notify("logsvim: page name required", vim.log.levels.ERROR)
    return
  end

  graph.resolve_root(function(root)
    if not root then
      return
    end
    local bufname = "logsvim-page://" .. root .. "/" .. name
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 then
      if vim.bo[existing].modified then
        vim.cmd("buffer " .. existing)
        return
      end
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd("edit " .. vim.fn.fnameescape(bufname))
  end)
end

-- The [[Page Name]] under the cursor on the current line, if any.
local function link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  for s, name, e in line:gmatch("()%[%[([^%[%]]+)%]%]()") do
    if col >= s and col < e then
      return name
    end
  end
  return nil
end

-- Extract the [[Page Name]] under the cursor on the current line, if any,
-- and open it (like `gd`).
function M.open_under_cursor()
  local name = link_under_cursor()
  if not name then
    vim.notify("logsvim: no [[Page]] link under cursor", vim.log.levels.WARN)
    return
  end
  M.open(name)
end

-- Follow whatever's at the cursor, in either direction: a [[Page]] link
-- opens that page (journal -> page, or page -> another page), and failing
-- that, inside a page's linked-references view, the nearest "### <date>"
-- heading at or above the cursor jumps to that date in the journal (page ->
-- journal). Bound to both `gd` and <CR> in journal and page buffers, so
-- either key follows either kind of reference.
function M.goto_under_cursor()
  local name = link_under_cursor()
  if name then
    M.open(name)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local root = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  if root then
    M.goto_reference(bufnr)
    return
  end

  vim.notify("logsvim: no [[Page]] link under cursor", vim.log.levels.WARN)
end

-- Reload every open logsvim buffer for `root` that could show stale text
-- after `old_name` was renamed to `new_name`: the renamed page's own buffer
-- (whose identity changes, so it's closed and reopened under the new name)
-- and every other page buffer (whose content or linked references may quote
-- the old name). Buffers with unsaved changes are left alone and flagged,
-- since overwriting them could either discard edits or silently resurrect
-- the old name on next save.
local function reload_page_buffers(root, old_name, new_name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_root, name = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
      if buf_root == root then
        if vim.bo[bufnr].modified then
          vim.notify(
            "logsvim: " .. vim.api.nvim_buf_get_name(bufnr) .. " has unsaved changes; reload manually after the rename",
            vim.log.levels.WARN
          )
        elseif name == old_name then
          local was_current = bufnr == vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_delete(bufnr, { force = true })
          if was_current then
            M.open(new_name)
          end
        else
          M.read(bufnr)
        end
      end
    end
  end
end

-- Rename `old_name` to `new_name` everywhere: every [[old_name]] reference
-- across journals/pages, the page file itself (if any), and any open
-- buffers that would otherwise show stale text.
function M.rename(root, old_name, new_name)
  if PSEUDO_PAGES[old_name] then
    vim.notify("logsvim: [[" .. old_name .. "]] is a built-in page and can't be renamed", vim.log.levels.WARN)
    return
  end
  if PSEUDO_PAGES[new_name] then
    vim.notify("logsvim: [[" .. new_name .. "]] is a built-in page name and can't be used", vim.log.levels.WARN)
    return
  end

  local updated, err = graph.rename_page(root, old_name, new_name)
  if not updated then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  reload_page_buffers(root, old_name, new_name)
  local journal_bufnr = vim.fn.bufnr("logsvim-journal://" .. root)
  if journal_bufnr ~= -1 and vim.api.nvim_buf_is_loaded(journal_bufnr) then
    if vim.bo[journal_bufnr].modified then
      vim.notify("logsvim: journal buffer has unsaved changes; reload manually (:e!) after the rename", vim.log.levels.WARN)
    else
      journal.read(journal_bufnr)
    end
  end

  index.refresh(root)
  vim.notify(("logsvim: renamed [[%s]] to [[%s]] (%d file(s) updated)"):format(old_name, new_name, updated), vim.log.levels.INFO)
end

-- Prompt for a new name and rename the [[Page Name]] link under the cursor
-- everywhere in the graph. Meant for use from a reference to a page (a
-- [[link]] in a journal entry or in another page's linked-references view),
-- not from the page's own buffer, which has no [[link]] syntax to target.
function M.rename_under_cursor()
  local name = link_under_cursor()
  if not name then
    vim.notify("logsvim: no [[Page]] link under cursor", vim.log.levels.WARN)
    return
  end

  graph.resolve_root(function(root)
    if not root then
      return
    end
    vim.ui.input({ prompt = "logsvim: rename [[" .. name .. "]] to: ", default = name }, function(new_name)
      if not new_name or new_name == "" or new_name == name then
        return
      end
      M.rename(root, name, new_name)
    end)
  end)
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("logsvim_pages", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "logsvim-page://*",
    callback = function(args)
      M.read(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "logsvim-page://*",
    callback = function(args)
      M.write(args.buf)
    end,
  })
end

return M
