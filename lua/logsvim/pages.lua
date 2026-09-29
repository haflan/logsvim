local config = require("logsvim.config")
local graph = require("logsvim.graph")
local journal = require("logsvim.journal")
local buffer = require("logsvim.buffer")
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

-- bufnr -> { root, name, mark, pseudo, original_lines, notified }.
-- `original_lines` is the page file's content as last rendered (see
-- refresh()); `notified` the disk version M.reload() already warned about.
-- `mark` is an extmark at the row (0-indexed) where the read-only
-- aggregation section begins, or nil if the page currently has nothing to
-- show there (in which case everything from CONTENT_START to the end of the
-- buffer is page content).
local state = {}

-- "Pseudo-pages": synthetic, read-only pages that don't correspond to a
-- real pages/<name>.md file. Opening one (via :LogsvimPage, or a [[Name]]
-- link + gd/<CR>, exactly like any other page) shows a live, graph-wide
-- aggregation instead of a real file's content + backlinks: "Scheduled"
-- lists SCHEDULED/DEADLINE blocks due today or earlier that aren't done
-- yet, and one page per Logseq task marker (TODO, DOING, NOW, LATER,
-- WAITING, IN-PROGRESS, DONE, CANCELED, CANCELLED) lists every block
-- currently carrying that marker -- in any journal (tasks only live there;
-- pages are plain Markdown), grouped by date and re-indented under its
-- ancestor context (see outline.lua).
local PSEUDO_PAGES = {
  Scheduled = function(root)
    return schedule.due(root)
  end,
}
-- Display order for completion (see M.completion_names): "Scheduled" first,
-- then each task-marker status in schedule.MARKERS' order. PSEUDO_PAGES
-- itself is a plain string-keyed table, so this is the only place that
-- order is recorded.
local PSEUDO_PAGE_NAMES = { "Scheduled" }
for _, status in ipairs(schedule.MARKERS) do
  PSEUDO_PAGES[status] = function(root)
    return schedule.by_marker(root, status)
  end
  table.insert(PSEUDO_PAGE_NAMES, status)
end

local function line_references(line, name)
  for match in line:gmatch("%[%[([^%[%]]+)%]%]") do
    if match == name then
      return true
    end
  end
  return false
end

-- Journal blocks that reference "[[name]]", grouped by date, newest first,
-- with each match's ancestor context included and same-context matches
-- merged together (see outline.lua):
-- { { date = "2026_08_01", lines = {...outline...} }, ... }
function M.find_references(root, name)
  local groups = {}
  for _, filename in ipairs(graph.list_journal_files(root)) do
    local lines = graph.read_lines(graph.journal_dir(root) .. "/" .. filename)
    local headers = {}
    for i, line in ipairs(lines) do
      if line_references(line, name) then
        -- A match on the bullet's own marker line is itself a valid header
        -- -- outline.group() will add its ancestor context automatically.
        -- A match on a continuation line (no marker of its own) has to be
        -- resolved up to the bullet it belongs to first, or it gets treated
        -- as a detached header with no marker (see outline.header_for()).
        table.insert(headers, graph.is_bullet_line(line) and i or outline.header_for(lines, i))
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
-- "### <date>" heading, with no editable region at all (content_end ==
-- CONTENT_START unconditionally).
local function render_pseudo(root, name, provider)
  local lines = { "# " .. name, "" }

  for gi, group in ipairs(provider(root)) do
    if gi > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, "### " .. group.name)
    table.insert(lines, "")
    for _, l in ipairs(group.lines) do
      table.insert(lines, l)
    end
  end

  return lines, CONTENT_START
end

-- Render the page view for `name`: for a pseudo-page (see PSEUDO_PAGES
-- above), its live aggregation with no editable region; otherwise an
-- editable header + page content (from pages/<name>.md, if it exists),
-- followed by a read-only "linked references" section listing every
-- journal block that references it, grouped by date. Returns the lines and
-- the 0-indexed row at which the read-only section begins (== #lines if
-- there's nothing to show there).
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

  return lines, content_end
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

-- The editable page-content region's current buffer lines ({} for a
-- pseudo-page, which has none).
local function content_lines(bufnr, st)
  if st.pseudo then
    return {}
  end
  local content_end
  if st.mark then
    content_end = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, st.mark, {})[1]
  else
    content_end = vim.api.nvim_buf_line_count(bufnr)
  end
  if content_end <= CONTENT_START then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, CONTENT_START, content_end, false)
end

-- (Re-)render the whole buffer against the current graph state and mark it
-- unmodified. `st.original_lines` records the page file's content as
-- rendered: the version M.write() expects to still find on disk. Takes
-- M.render()'s results if the caller already has them.
local function refresh(bufnr, st, lines, content_end)
  if not lines then
    lines, content_end = M.render(st.root, st.name)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  st.original_lines = vim.list_slice(lines, CONTENT_START + 1, content_end)
  st.notified = nil
  set_mark(bufnr, st, lines, content_end)
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

  local st = { root = root, name = name, mark = nil, pseudo = PSEUDO_PAGES[name] ~= nil }
  state[bufnr] = st
  refresh(bufnr, st)

  config.set_keymap(bufnr, "goto_reference", M.goto_under_cursor, "logsvim: go to reference under cursor")
  config.set_keymap(bufnr, "rename", M.rename_under_cursor, "logsvim: rename page under cursor")
end

local function page_path(st)
  return graph.pages_dir(st.root) .. "/" .. st.name .. ".md"
end

-- Write the editable page-content region (above the read-only boundary, if
-- any) to pages/<name>.md, creating the file (and pages/ dir) if it doesn't
-- exist yet -- but only if that region was actually edited, so a `:w` just
-- to refresh the linked references never touches the file. Like the
-- journal, the write only goes through if the file still holds what was
-- rendered; a change made elsewhere in the meantime is three-way merged,
-- and on a conflict nothing is written and the buffer keeps the user's
-- edits. `opts.force` (`:w!`) overwrites regardless. The read-only section
-- is never read from the buffer, and the whole buffer is re-rendered after
-- a save, so any stray edits made there are discarded rather than
-- persisted. A pseudo-page (see PSEUDO_PAGES) has no editable region at
-- all -- writing one just re-renders it against the current graph state.
function M.write(bufnr, opts)
  opts = opts or {}
  local st = state[bufnr]
  if not st then
    vim.notify("logsvim: no tracked state for buffer", vim.log.levels.ERROR)
    return
  end

  local written = false
  local content = content_lines(bufnr, st)
  if not st.pseudo and not vim.deep_equal(content, st.original_lines) then
    local path = page_path(st)
    if opts.force then
      graph.write_lines_atomic(path, content)
      written = true
    else
      local ok, disk = graph.write_lines_checked(path, st.original_lines, content)
      if ok then
        written = true
      else
        local merged = graph.merge_lines(content, st.original_lines, disk)
        if merged and graph.write_lines_checked(path, disk, merged) then
          written = true
        else
          vim.notify(
            ("logsvim: %s changed on disk and conflicts with your edits, so it wasn't written. "
              .. "Your edits are kept in the buffer: :w! to overwrite the file with them, "
              .. "or :LogsvimReload! to discard them and load the file"):format(config.options.pages_dir .. "/" .. st.name .. ".md"),
            vim.log.levels.WARN
          )
          return
        end
      end
    end
  end

  -- Keep the cursor where it was: the re-render replaces every line.
  buffer.keep_views(bufnr, function()
    refresh(bufnr, st)
  end)

  if written then
    -- Reindex [[Page]] links in the background so a newly-created page (or
    -- new links within it) show up in completion without a manual
    -- :LogsvimReindex.
    index.refresh(st.root)
  end
end

-- Pick up changes made elsewhere: if the page's own content hasn't been
-- edited, re-render the whole buffer, which also refreshes the linked
-- references (they may have changed in *other* files). If it has been
-- edited and the file changed underneath it, leave the buffer alone
-- (M.write() merges or refuses later) and notify once per file version --
-- unless `opts.discard` (`:LogsvimReload!`), which throws the edits away.
function M.reload(bufnr, opts)
  opts = opts or {}
  local st = state[bufnr]
  if not st then
    return
  end

  local edited = not vim.deep_equal(content_lines(bufnr, st), st.original_lines)
  if edited and not opts.discard then
    local disk = graph.read_lines(page_path(st))
    local version = table.concat(disk, "\n")
    if not vim.deep_equal(disk, st.original_lines) and st.notified ~= version then
      st.notified = version
      vim.notify(
        ("logsvim: %s changed on disk, but you have unsaved edits to it. :w tries to merge them, :LogsvimReload! discards yours"):format(
          config.options.pages_dir .. "/" .. st.name .. ".md"
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  local lines, content_end = M.render(st.root, st.name)
  if vim.bo[bufnr].modified or not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) then
    buffer.keep_views(bufnr, function()
      refresh(bufnr, st, lines, content_end)
    end)
  end
end

-- Find the nearest "### <date>" heading at or above the cursor -- but only
-- within the read-only aggregation section (below st.mark; see set_mark) --
-- and jump to that date in the journal: every group there, in a page's
-- linked references or a pseudo-page, is a journal day. Restricting the scan
-- to below the boundary keeps a "### " heading the user wrote as ordinary
-- editable page content from being misread as a reference to jump to.
-- Exact block navigation isn't supported, but landing on the right day gets
-- you close.
function M.goto_reference(bufnr)
  local root = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  local st = state[bufnr]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local boundary_row = st and st.mark and vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, st.mark, {})[1]
  if not boundary_row or lnum <= boundary_row then
    vim.notify("logsvim: no referencing date found above the cursor", vim.log.levels.WARN)
    return
  end

  local section = vim.api.nvim_buf_get_lines(bufnr, boundary_row, lnum, false)
  for i = #section, 1, -1 do
    local date = section[i]:match("^### (.+)$")
    if date then
      journal.goto_date(root, date)
      return
    end
  end
  vim.notify("logsvim: no referencing date found above the cursor", vim.log.levels.WARN)
end

-- Completion candidates for :LogsvimPage: pseudo-pages that currently have
-- something to show, in PSEUDO_PAGE_NAMES order (Scheduled, then each
-- task-marker status), followed by every known real page name. An empty
-- pseudo-page is left off the list -- opening it would show nothing -- and
-- a real name that happens to collide with a pseudo-page name is skipped
-- since the pseudo-page entry already covers it. Which pseudo-pages have
-- something to show is checked via schedule.presence(), a single pass over
-- the graph, rather than rendering each of the 10 pseudo-pages in full.
function M.completion_names(root)
  local names, seen = {}, {}
  local present = schedule.presence(root)

  for _, name in ipairs(PSEUDO_PAGE_NAMES) do
    if present[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end

  for _, name in ipairs(index.names(root)) do
    if not seen[name] then
      table.insert(names, name)
    end
  end

  return names
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
      -- Refreshes the days the user hasn't touched and flags the rest.
      journal.reload(journal_bufnr)
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
      if state[args.buf] then
        -- The BufEnter that follows this read has nothing new to pick up,
        -- and re-rendering scans every journal for linked references.
        state[args.buf].just_read = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "logsvim-page://*",
    callback = function(args)
      M.write(args.buf, { force = vim.v.cmdbang == 1 })
    end,
  })

  -- No file watcher: pick up changes made elsewhere whenever the user comes
  -- back to the buffer, or to Neovim itself.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "logsvim-page://*",
    callback = function(args)
      local st = state[args.buf]
      if st and st.just_read then
        st.just_read = nil
      else
        M.reload(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      for bufnr in pairs(state) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          M.reload(bufnr)
        end
      end
    end,
  })
end

return M
