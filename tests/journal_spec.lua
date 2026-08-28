local helpers = require("tests.helpers")
local config = require("logsvim.config")
local graph = require("logsvim.graph")
local journal = require("logsvim.journal")
local index = require("logsvim.index")

local function close_journal_buf(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].modified = false
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

describe(":LogsvimJournal buffer", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root, journal_batch_size = 14 })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("loads all fixture days newest-first with header lines", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    assert.are.equal("acwrite", vim.bo[bufnr].buftype)
    assert.are.equal("markdown", vim.bo[bufnr].filetype)
    assert.is_false(vim.bo[bufnr].modified)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- journal.open() ensures today's (empty) file exists, so it's the newest
    assert.are.equal("# " .. graph.filename_display(graph.date_to_filename(os.time())), lines[1])

    local text = table.concat(lines, "\n")
    assert.truthy(text:find("# 2026_08_01", 1, true))
    assert.truthy(text:find("- [[Neovim]]", 1, true))
    assert.truthy(text:find("# 2026_07_31", 1, true))
    assert.truthy(text:find("# 2026_07_30", 1, true))
    -- newest-to-oldest order
    assert.is_true(text:find("# 2026_08_01", 1, true) < text:find("# 2026_07_31", 1, true))
    assert.is_true(text:find("# 2026_07_31", 1, true) < text:find("# 2026_07_30", 1, true))

    close_journal_buf(bufnr)
  end)

  it("writes an edited day back to its own file and leaves others untouched", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    local unrelated_before = helpers.read_file(root .. "/journals/2026_07_30.md")

    -- journal.open() may prepend an empty "today" entry ahead of the
    -- fixtures, so locate 2026_08_01's header rather than assume a line number.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local header_idx
    for i, l in ipairs(lines) do
      if l == "# 2026_08_01" then
        header_idx = i
        break
      end
    end
    assert.truthy(header_idx)

    vim.api.nvim_buf_set_lines(bufnr, header_idx, header_idx + 1, false, { "- [[Neovim]]", "  edited via test" })
    vim.cmd("write")

    local edited = helpers.read_file(root .. "/journals/2026_08_01.md")
    assert.are.equal("- [[Neovim]]\n  edited via test\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n", edited)

    local unrelated_after = helpers.read_file(root .. "/journals/2026_07_30.md")
    assert.are.equal(unrelated_before, unrelated_after)
    assert.is_false(vim.bo[bufnr].modified)

    close_journal_buf(bufnr)
  end)

  it("does not rewrite a file whose region is untouched", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()
    local path = root .. "/journals/2026_07_30.md"
    local mtime_before = vim.fn.getftime(path)

    -- touch a different region only
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "- [[Neovim]]", "  changed" })
    vim.cmd("write")

    assert.are.equal(mtime_before, vim.fn.getftime(path))
    close_journal_buf(bufnr)
  end)

  it("reindexes in the background after an edited region is actually saved", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local header_idx
    for i, l in ipairs(lines) do
      if l == "# 2026_08_01" then
        header_idx = i
        break
      end
    end
    assert.truthy(header_idx)

    local calls = 0
    local original = index.refresh
    index.refresh = function(...)
      calls = calls + 1
    end

    vim.api.nvim_buf_set_lines(bufnr, header_idx, header_idx + 1, false, { "- [[Brand New Page]]" })
    vim.cmd("write")

    assert.are.equal(1, calls)

    index.refresh = original
    close_journal_buf(bufnr)
  end)

  it("does not reindex on a save with no actual changes", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    local calls = 0
    local original = index.refresh
    index.refresh = function(...)
      calls = calls + 1
    end

    vim.cmd("write")

    assert.are.equal(0, calls)

    index.refresh = original
    close_journal_buf(bufnr)
  end)

  it("preserves an untouched day's surviving lines when a delete spans into its header/boundary", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    local function find_row(text)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, l in ipairs(lines) do
        if l == text then
          return i - 1 -- 0-indexed
        end
      end
      return nil
    end

    local unrelated_before = helpers.read_file(root .. "/journals/2026_07_30.md")

    -- Delete from the last line of 2026_08_01's content through the middle
    -- of 2026_07_31's content. This spans the blank separator and the
    -- "# 2026_07_31" header itself, which used to corrupt boundary tracking
    -- for the day above (2026_08_01) even though its earlier lines were
    -- never touched.
    local screenshot_row = find_row("  - ![screenshot.png](../assets/screenshot.png)")
    local quickadd_row = find_row("  - logsvim: journal quick-add")
    assert.truthy(screenshot_row)
    assert.truthy(quickadd_row)

    vim.api.nvim_buf_set_lines(bufnr, screenshot_row, quickadd_row + 1, false, {})
    vim.cmd("write")

    local edited_2026_08_01 = helpers.read_file(root .. "/journals/2026_08_01.md")
    assert.are.equal("- [[Neovim]]\n  - Wired up logsvim.nvim\n", edited_2026_08_01)

    local edited_2026_07_31 = helpers.read_file(root .. "/journals/2026_07_31.md")
    assert.are.equal("  - logsvim: page backlinks\n", edited_2026_07_31)

    local unrelated_after = helpers.read_file(root .. "/journals/2026_07_30.md")
    assert.are.equal(unrelated_before, unrelated_after)

    close_journal_buf(bufnr)
  end)

  it("keeps every day's boundary correct across three lazy-loaded batches", function()
    config.setup({ root = root, journal_batch_size = 1 })
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()
    local st = journal._test.state[bufnr]

    -- journal.open() loads today's (empty) file as batch 1. Load the rest
    -- one day at a time so every append_batch call has to snap back the
    -- previous batch's open-ended boundary (see the prev_last_id handling
    -- in append_batch) -- this exercises that chain across more than one
    -- link, not just a single load-more.
    while st.next_index <= #st.files do
      journal._test.maybe_load_more(bufnr)
    end
    assert.are.equal(4, #st.files) -- today (empty) + the 3 fixture days

    local function find_row(text)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, l in ipairs(lines) do
        if l == text then
          return i - 1 -- 0-indexed
        end
      end
      return nil
    end

    -- Edit the very first (today, initially empty) and very last (oldest,
    -- open-ended) day's regions -- the two ends of the chain -- while
    -- leaving the two middle days untouched.
    local today_header_row = find_row("# " .. graph.filename_display(graph.date_to_filename(os.time())))
    assert.truthy(today_header_row)
    vim.api.nvim_buf_set_lines(bufnr, today_header_row + 1, today_header_row + 1, false, { "- [[Quick add]]" })

    local unrelated_1 = helpers.read_file(root .. "/journals/2026_08_01.md")
    local unrelated_2 = helpers.read_file(root .. "/journals/2026_07_31.md")

    local last_line = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, last_line, last_line, false, { "  - appended at the very end" })

    vim.cmd("write")

    local edited_today = helpers.read_file(root .. "/journals/" .. graph.date_to_filename(os.time()))
    assert.are.equal("- [[Quick add]]\n", edited_today)

    local edited_last = helpers.read_file(root .. "/journals/2026_07_30.md")
    assert.are.equal(
      "- [[Groceries]]\n  - Bought milk and eggs\n- [[Neovim]]\n  - Started reading the [[Plugin Ideas]] notes\n  - appended at the very end\n",
      edited_last
    )

    assert.are.equal(unrelated_1, helpers.read_file(root .. "/journals/2026_08_01.md"))
    assert.are.equal(unrelated_2, helpers.read_file(root .. "/journals/2026_07_31.md"))

    close_journal_buf(bufnr)
  end)

  it("lazy-loads the next batch once the visible buffer is exhausted", function()
    config.setup({ root = root, journal_batch_size = 1 })
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    local st = journal._test.state[bufnr]
    assert.are.equal(2, st.next_index) -- only the first file loaded so far

    journal._test.maybe_load_more(bufnr)
    assert.are.equal(3, st.next_index)

    close_journal_buf(bufnr)
  end)

  it("creates and shows today's (empty) file when the graph has no journal entries yet", function()
    local empty_root = helpers.temp_graph()
    helpers.rmtree(empty_root .. "/journals")
    config.setup({ root = empty_root })

    journal.open(empty_root)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.equal(1, #lines)
    assert.are.equal("# " .. graph.filename_display(graph.date_to_filename(os.time())), lines[1])
    assert.are.equal(1, #vim.fn.readdir(empty_root .. "/journals"))

    close_journal_buf(bufnr)
    helpers.rmtree(empty_root)
  end)
end)

describe("graph.filename_display", function()
  it("strips the .md extension", function()
    assert.are.equal("2026_08_01", graph.filename_display("2026_08_01.md"))
  end)
end)
