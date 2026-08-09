local graph = require("logsvim.graph")
local journal = require("logsvim.journal")
local index = require("logsvim.index")

local M = {}

local ns = vim.api.nvim_create_namespace("logsvim_pages")

-- Row (0-indexed) where the editable page-content region always starts:
-- row 0 is the "# name" header, row 1 is a structural blank separator.
local CONTENT_START = 2

-- bufnr -> { root, name, mark }. `mark` is an extmark at the row (0-indexed)
-- where the read-only "Linked references" section begins, or nil if the
-- page currently has no references (in which case everything from
-- CONTENT_START to the end of the buffer is page content).
local state = {}

local function indent_len(line)
  return #(line:match("^[ \t]*"))
end

local function line_references(line, name)
  for match in line:gmatch("%[%[([^%[%]]+)%]%]") do
    if match == name then
      return true
    end
  end
  return false
end

-- Collect the bullet block starting at line `i`: its own line plus every
-- more-deeply-indented line below it. Blank lines are passed through without
-- ending the block (they may just be a paragraph break within its contents),
-- but trimmed off the end. Returns the block's lines and the index of the
-- first line after it.
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

local function list_journal_files(root)
  local dir = graph.journal_dir(root)
  local files = {}
  local ok, entries = pcall(vim.fn.readdir, dir)
  if ok and entries then
    for _, fname in ipairs(entries) do
      if fname:match("%.md$") then
        table.insert(files, fname)
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

-- Journal blocks (and their subblocks) that reference "[[name]]", grouped by
-- date, newest first: { { date = "2026_08_01", blocks = { {line, ...}, ... } }, ... }
function M.find_references(root, name)
  local groups = {}
  for _, filename in ipairs(list_journal_files(root)) do
    local lines = read_lines(graph.journal_dir(root) .. "/" .. filename)
    local blocks = {}
    local i = 1
    while i <= #lines do
      if line_references(lines[i], name) then
        local block, next_i = collect_block(lines, i)
        table.insert(blocks, block)
        i = next_i
      else
        i = i + 1
      end
    end
    if #blocks > 0 then
      table.insert(groups, { date = graph.filename_display(filename), blocks = blocks })
    end
  end
  return groups
end

local function page_content(root, name)
  local path = graph.pages_dir(root) .. "/" .. name .. ".md"
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return read_lines(path)
end

-- Render the page view for `name`: an editable header + page content (from
-- pages/<name>.md, if it exists), followed by a read-only "linked
-- references" section listing every journal block that references it,
-- grouped by date. Returns the lines plus the 0-indexed row at which the
-- linked-references section begins (== #lines if there are no references).
function M.render(root, name)
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
      for _, block in ipairs(group.blocks) do
        table.insert(lines, "")
        for _, l in ipairs(block) do
          table.insert(lines, l)
        end
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

function M.read(bufnr)
  local root, name = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  if not root or not name then
    vim.notify("logsvim: invalid page buffer name", vim.log.levels.ERROR)
    return
  end

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false

  local lines, content_end = M.render(root, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  local st = { root = root, name = name, mark = nil }
  state[bufnr] = st
  set_mark(bufnr, st, lines, content_end)

  vim.keymap.set("n", "gd", M.open_under_cursor, { buffer = bufnr, desc = "logsvim: go to page under cursor" })
  vim.keymap.set("n", "<CR>", function()
    M.goto_reference(bufnr)
  end, { buffer = bufnr, desc = "logsvim: jump to this reference's date in the journal" })
end

-- Write the editable page-content region (above the linked-references
-- boundary, if any) to pages/<name>.md, creating the file (and pages/ dir)
-- if it doesn't exist yet. The linked-references section is never read from
-- the buffer, and the whole buffer is re-rendered from disk afterwards, so
-- any stray edits made there are discarded rather than persisted.
function M.write(bufnr)
  local st = state[bufnr]
  if not st then
    vim.notify("logsvim: no tracked state for buffer", vim.log.levels.ERROR)
    return
  end

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

  local lines, new_content_end = M.render(st.root, st.name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  set_mark(bufnr, st, lines, new_content_end)

  -- Reindex [[Page]] links in the background so a newly-created page (or new
  -- links within it) show up in completion without a manual :LogsvimReindex.
  index.refresh(st.root)
end

-- Find the nearest "### <date>" heading at or above the cursor and jump to
-- that date in the journal (exact block navigation isn't supported, but
-- landing on the right day gets you close).
function M.goto_reference(bufnr)
  local root = scheme_parts(vim.api.nvim_buf_get_name(bufnr))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)
  for i = #lines, 1, -1 do
    local date = lines[i]:match("^### (.+)$")
    if date then
      journal.goto_date(root, date)
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

-- Extract the [[Page Name]] under the cursor on the current line, if any,
-- and open it (like `gd`).
function M.open_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  for s, name, e in line:gmatch("()%[%[([^%[%]]+)%]%]()") do
    if col >= s and col < e then
      M.open(name)
      return
    end
  end

  vim.notify("logsvim: no [[Page]] link under cursor", vim.log.levels.WARN)
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
