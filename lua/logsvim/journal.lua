local config = require("logsvim.config")
local graph = require("logsvim.graph")
local buffer = require("logsvim.buffer")
local index = require("logsvim.index")

local M = {}

local ns = vim.api.nvim_create_namespace("logsvim_journal")

-- bufnr -> { root, files = {filenames desc}, next_index, extmarks = {id ->
-- {path, original_lines}}, loading }
local state = {}

local function scheme_root(bufname)
  return bufname:match("^logsvim%-journal://(.*)$")
end

local function list_journal_files(root)
  local dir = graph.journal_dir(root)
  local files = {}
  local ok, entries = pcall(vim.fn.readdir, dir)
  if ok and entries then
    for _, name in ipairs(entries) do
      if name:match("%.md$") then
        table.insert(files, name)
      end
    end
  end
  -- "YYYY_MM_DD.md" sorts chronologically as a plain string, so descending
  -- string order is newest-first.
  table.sort(files, function(a, b)
    return a > b
  end)
  return files
end

local function read_file_lines(path)
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

-- Render up to `count` files starting at st.next_index into `bufnr`,
-- appending after the current last line (or replacing the initial empty
-- buffer on first load). Each day gets a "# <date>" header line that its
-- extmark anchors to; content starts on the line below the header.
local function append_batch(bufnr, st, count)
  if st.next_index > #st.files then
    return false
  end

  local first_batch = st.next_index == 1
  local start_row = first_batch and 0 or vim.api.nvim_buf_line_count(bufnr)

  local lines = {}
  local new_marks = {}
  local have_content = not first_batch

  for i = st.next_index, math.min(st.next_index + count - 1, #st.files) do
    local filename = st.files[i]
    local path = graph.journal_dir(st.root) .. "/" .. filename
    local content = read_file_lines(path)

    if have_content then
      table.insert(lines, "")
    end
    table.insert(lines, "# " .. graph.filename_display(filename))
    local header_offset = #lines - 1 -- 0-indexed row of header within `lines`
    for _, l in ipairs(content) do
      table.insert(lines, l)
    end

    table.insert(new_marks, { offset = header_offset, path = path, original_lines = content })
    have_content = true
  end

  if first_batch then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, start_row, start_row, false, lines)
  end

  for _, m in ipairs(new_marks) do
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row + m.offset, 0, {})
    st.extmarks[id] = { path = m.path, original_lines = m.original_lines }
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

  local st = { root = root, files = list_journal_files(root), next_index = 1, extmarks = {}, loading = false }
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

  vim.keymap.set("n", "gd", function()
    require("logsvim.pages").goto_under_cursor()
  end, { buffer = bufnr, desc = "logsvim: go to reference under cursor" })
  vim.keymap.set("n", "<CR>", function()
    require("logsvim.pages").goto_under_cursor()
  end, { buffer = bufnr, desc = "logsvim: go to reference under cursor" })
  vim.keymap.set("n", "<leader>rn", function()
    require("logsvim.pages").rename_under_cursor()
  end, { buffer = bufnr, desc = "logsvim: rename page under cursor" })
  buffer.attach(bufnr)
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

function M.write(bufnr)
  local st = state[bufnr]
  if not st then
    vim.notify("logsvim: no tracked state for buffer", vim.log.levels.ERROR)
    return
  end

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  table.sort(marks, function(a, b)
    return a[2] < b[2]
  end)

  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local changed = false

  for idx, mark in ipairs(marks) do
    local id, header_row = mark[1], mark[2]
    local region = st.extmarks[id]
    if region then
      local content_start = header_row + 1
      -- next region's header row minus the blank separator line before it;
      -- for the last region, content runs to the end of the buffer.
      local content_end = idx < #marks and (marks[idx + 1][2] - 1) or last_line

      local current = {}
      if content_end > content_start then
        current = vim.api.nvim_buf_get_lines(bufnr, content_start, content_end, false)
      end

      if not vim.deep_equal(current, region.original_lines) then
        local f, err = io.open(region.path, "w")
        if not f then
          error("logsvim: failed to write " .. region.path .. ": " .. tostring(err))
        end
        if #current > 0 then
          f:write(table.concat(current, "\n") .. "\n")
        end
        f:close()
        region.original_lines = current
        changed = true
      end
    end
  end

  vim.bo[bufnr].modified = false

  -- Reindex [[Page]] links in the background so new/renamed links show up in
  -- completion without waiting on a manual :LogsvimReindex. index.refresh()
  -- shells out to rg asynchronously, so this never blocks the save.
  if changed then
    index.refresh(st.root)
  end
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
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "logsvim-journal://*",
    callback = function(args)
      M.write(args.buf)
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
