local config = require("logsvim.config")
local graph = require("logsvim.graph")
local buffer = require("logsvim.buffer")
local index = require("logsvim.index")

local M = {}

local ns = vim.api.nvim_create_namespace("logsvim_journal")

-- bufnr -> { root, files = {filenames desc}, next_index, extmarks = {id ->
-- {path, original_lines}}, loading, notified = {path -> disk version
-- already warned about by M.reload} }. `original_lines` is the version of
-- the file the buffer is based on: what M.write() expects to still find on
-- disk.
local state = {}

local function scheme_root(bufname)
  return bufname:match("^logsvim%-journal://(.*)$")
end

-- Render up to `count` files starting at st.next_index into `bufnr`,
-- appending after the current last line (or replacing the initial empty
-- buffer on first load). Each day gets a "# <date>" header line, and its
-- content (the lines below the header, up to the next day's blank
-- separator or the end of buffer) is tracked by a *range* extmark so that
-- M.write() can read each day's boundaries directly off its own mark
-- instead of inferring them from a neighboring mark's position — see the
-- prev_last_id handling below for why that distinction matters.
local function append_batch(bufnr, st, count)
  if st.next_index > #st.files then
    return false
  end

  local first_batch = st.next_index == 1
  local start_row = first_batch and 0 or vim.api.nvim_buf_line_count(bufnr)
  local prev_last_id = st.last_mark_id

  local lines = {}
  local day_spans = {}
  local have_content = not first_batch

  for i = st.next_index, math.min(st.next_index + count - 1, #st.files) do
    local filename = st.files[i]
    local path = graph.journal_dir(st.root) .. "/" .. filename
    local content = graph.read_lines(path)

    if have_content then
      table.insert(lines, "")
    end
    table.insert(lines, "# " .. graph.filename_display(filename))
    local content_start_offset = #lines -- 0-indexed row of first content line within `lines`
    for _, l in ipairs(content) do
      table.insert(lines, l)
    end
    local content_end_offset = #lines -- exclusive; row after the last content line

    table.insert(day_spans, {
      content_start_offset = content_start_offset,
      content_end_offset = content_end_offset,
      path = path,
      original_lines = content,
    })
    have_content = true
  end

  if first_batch then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, start_row, start_row, false, lines)
  end

  local last_id = nil
  for _, span in ipairs(day_spans) do
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row + span.content_start_offset, 0, {
      end_row = start_row + span.content_end_offset,
      end_col = 0,
      right_gravity = false,
      -- So a bullet typed at the end of a day's content (right before the
      -- blank separator) is picked up as part of that day, not lost outside
      -- the tracked region.
      end_right_gravity = true,
    })
    st.extmarks[id] = { path = span.path, original_lines = span.original_lines }
    last_id = id
  end

  -- The lines we just inserted landed exactly at the previous last day's
  -- content-end boundary. Because that mark's end has end_right_gravity =
  -- true (needed for the reason above), Neovim would otherwise treat this
  -- batch's new content as an append *into* that day's region and extend
  -- its end to swallow it. Snap it back to the boundary that existed before
  -- this insert.
  if prev_last_id and st.extmarks[prev_last_id] then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, prev_last_id, {})
    vim.api.nvim_buf_set_extmark(bufnr, ns, pos[1], 0, {
      id = prev_last_id,
      end_row = start_row,
      end_col = 0,
      right_gravity = false,
      end_right_gravity = true,
    })
  end

  if last_id then
    st.last_mark_id = last_id
  end

  st.next_index = st.next_index + count
  return true
end

function M.read(bufnr)
  local root = scheme_root(vim.api.nvim_buf_get_name(bufnr))
  if not root then
    vim.notify("logsvim: invalid journal buffer name", vim.log.levels.ERROR)
    return
  end

  local st = { root = root, files = graph.list_journal_files(root), next_index = 1, extmarks = {}, loading = false, last_mark_id = nil }
  state[bufnr] = st

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false

  if #st.files == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "-- no journal entries in " .. graph.journal_dir(root) .. " --" })
  else
    append_batch(bufnr, st, config.options.journal_batch_size)
  end

  vim.bo[bufnr].modified = false

  config.set_keymap(bufnr, "goto_reference", function()
    require("logsvim.pages").goto_under_cursor()
  end, "logsvim: go to reference under cursor")
  config.set_keymap(bufnr, "rename", function()
    require("logsvim.pages").rename_under_cursor()
  end, "logsvim: rename page under cursor")
  buffer.attach(bufnr, root)
end

local function maybe_load_more(bufnr)
  local st = state[bufnr]
  if not st or st.loading or st.next_index > #st.files then
    return
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return
  end

  local near_bottom = (info.topline + info.height) >= vim.api.nvim_buf_line_count(bufnr) - 5
  if not near_bottom then
    return
  end

  st.loading = true
  local modified = vim.bo[bufnr].modified
  append_batch(bufnr, st, config.options.journal_batch_size)
  vim.bo[bufnr].modified = modified
  st.loading = false
end

-- Every tracked day region in `bufnr`, in buffer order: { id, region,
-- content_start, content_end (exclusive), current = its buffer lines }.
-- Each mark carries its own content range (see append_batch), so regions
-- are read independently rather than derived from a neighboring mark's
-- position — an edit that mangles one day's boundary must not corrupt
-- another, untouched day's write.
local function regions(bufnr, st)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    local id, content_start, details = mark[1], mark[2], mark[4]
    local region = st.extmarks[id]
    if region then
      local content_end = details.end_row or content_start
      local current = {}
      if content_end > content_start then
        current = vim.api.nvim_buf_get_lines(bufnr, content_start, content_end, false)
      end
      table.insert(out, { id = id, region = region, content_start = content_start, content_end = content_end, current = current })
    end
  end
  return out
end

-- Replace a day's content in the buffer with `lines`, then pin its range
-- mark to exactly the new rows rather than relying on extmark gravity to
-- get the boundaries right (an empty day, or the last loaded day, whose end
-- sits at the end of the buffer).
local function replace_region(bufnr, r, lines)
  vim.api.nvim_buf_set_lines(bufnr, r.content_start, r.content_end, false, lines)
  vim.api.nvim_buf_set_extmark(bufnr, ns, r.content_start, 0, {
    id = r.id,
    end_row = r.content_start + #lines,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  r.region.original_lines = lines
end

-- A day's path relative to the graph root, for messages.
local function display_path(st, path)
  return vim.startswith(path, st.root .. "/") and path:sub(#st.root + 2) or path
end

-- Write every day whose region differs from what was loaded. A day is only
-- written if its file still holds exactly what was loaded; if it changed on
-- disk in the meantime (logsurf, git pull, another nvim), the two versions
-- are three-way merged, and on a conflict that day is left unwritten and
-- the buffer stays modified. `opts.force` (`:w!`) skips the check and
-- overwrites.
function M.write(bufnr, opts)
  opts = opts or {}
  local st = state[bufnr]
  if not st then
    vim.notify("logsvim: no tracked state for buffer", vim.log.levels.ERROR)
    return
  end

  local changed = false
  local failed = false

  buffer.keep_views(bufnr, function()
    -- Bottom-up, so replacing one region with merged lines of a different
    -- length doesn't shift the rows of regions still to be processed.
    local rs = regions(bufnr, st)
    for i = #rs, 1, -1 do
      local r = rs[i]
      local region = r.region
      if not vim.deep_equal(r.current, region.original_lines) then
        if opts.force then
          graph.write_lines_atomic(region.path, r.current)
          region.original_lines = r.current
          changed = true
        else
          local ok, disk = graph.write_lines_checked(region.path, region.original_lines, r.current)
          if ok then
            region.original_lines = r.current
            changed = true
          else
            local merged = graph.merge_lines(r.current, region.original_lines, disk)
            if merged and graph.write_lines_checked(region.path, disk, merged) then
              replace_region(bufnr, r, merged)
              changed = true
            else
              failed = true
              vim.notify(
                ("logsvim: %s changed on disk and conflicts with your edits, so it wasn't written. "
                  .. "Your edits are kept in the buffer: :w! to overwrite the file with them, "
                  .. "or :LogsvimReload! to discard them and load the file"):format(display_path(st, region.path)),
                vim.log.levels.WARN
              )
            end
          end
        end
      end
    end
  end)

  vim.bo[bufnr].modified = failed

  -- Reindex [[Page]] links in the background so new/renamed links show up in
  -- completion without waiting on a manual :LogsvimReindex. index.refresh()
  -- shells out to rg asynchronously, so this never blocks the save.
  if changed then
    index.refresh(st.root)
  end
end

-- Pick up changes made to loaded days elsewhere. A day the user hasn't
-- edited is replaced with its file's current content; an edited one is
-- left alone (M.write() merges or refuses it later), with a one-time
-- notice per file version -- unless `opts.discard` (`:LogsvimReload!`),
-- which throws the edits away and loads the file. Days not loaded yet need
-- nothing: they're read from disk when scrolled to.
function M.reload(bufnr, opts)
  opts = opts or {}
  local st = state[bufnr]
  if not st then
    return
  end
  st.notified = st.notified or {}

  local was_modified = vim.bo[bufnr].modified
  local dirty = false

  buffer.keep_views(bufnr, function()
    local rs = regions(bufnr, st)
    for i = #rs, 1, -1 do
      local r = rs[i]
      local region = r.region
      local disk = graph.read_lines(region.path)
      local edited = not vim.deep_equal(r.current, region.original_lines)
      if not vim.deep_equal(disk, region.original_lines) or (opts.discard and edited) then
        if not edited or opts.discard then
          replace_region(bufnr, r, disk)
          st.notified[region.path] = nil
        else
          dirty = true
          local version = table.concat(disk, "\n")
          if st.notified[region.path] ~= version then
            st.notified[region.path] = version
            vim.notify(
              ("logsvim: %s changed on disk, but you have unsaved edits to that day. "
                .. ":w tries to merge them, :LogsvimReload! discards yours"):format(display_path(st, region.path)),
              vim.log.levels.WARN
            )
          end
        end
      elseif edited then
        dirty = true
      end
    end
  end)

  -- Edits outside any day (headers, separators) are never written, so
  -- once no day differs from disk there's nothing left to save.
  vim.bo[bufnr].modified = was_modified and dirty
end

function M.open(root)
  if root then
    graph.ensure_journal_file(root)
    vim.cmd("edit logsvim-journal://" .. root)
    return
  end

  graph.resolve_root(function(resolved)
    if not resolved then
      return
    end
    graph.ensure_journal_file(resolved)
    vim.cmd("edit logsvim-journal://" .. resolved)
  end)
end

-- Open (or switch to) the journal buffer for `root` and move the cursor to
-- `date_str`'s "# <date>" header, loading further batches if it isn't
-- visible yet. Used by the page-references view to jump to a referencing day.
function M.goto_date(root, date_str)
  root = root or graph.root()
  M.open(root)
  local bufnr = vim.api.nvim_get_current_buf()
  local st = state[bufnr]
  if not st then
    return
  end

  local target = "# " .. date_str
  local function find_line()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == target then
        return i
      end
    end
    return nil
  end

  local lnum = find_line()
  if not lnum then
    local modified = vim.bo[bufnr].modified
    while not lnum and st.next_index <= #st.files do
      append_batch(bufnr, st, config.options.journal_batch_size)
      lnum = find_line()
    end
    vim.bo[bufnr].modified = modified
  end

  if lnum then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  else
    vim.notify("logsvim: could not find " .. date_str .. " in the journal", vim.log.levels.WARN)
  end
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("logsvim_journal", { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "logsvim-journal://*",
    callback = function(args)
      M.read(args.buf)
      if state[args.buf] then
        -- The BufEnter that follows this read has nothing new to pick up.
        state[args.buf].just_read = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "logsvim-journal://*",
    callback = function(args)
      M.write(args.buf, { force = vim.v.cmdbang == 1 })
    end,
  })

  -- No file watcher: pick up changes made elsewhere whenever the user comes
  -- back to the buffer, or to Neovim itself.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "logsvim-journal://*",
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

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      if state[args.buf] then
        maybe_load_more(args.buf)
      end
    end,
  })
end

-- Internal accessors for the test suite only; not part of the public API.
M._test = {
  state = state,
  maybe_load_more = maybe_load_more,
}

return M
