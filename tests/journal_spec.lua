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

describe(":LogsvimJournal with concurrent changes on disk", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root, journal_batch_size = 14 })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  local function find_row(bufnr, text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l == text then
        return i - 1 -- 0-indexed
      end
    end
    return nil
  end

  local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  -- Capture vim.notify messages while `fn` runs.
  local function capture_notify(fn)
    local messages = {}
    local original = vim.notify
    vim.notify = function(msg)
      table.insert(messages, msg)
    end
    local ok, err = pcall(fn)
    vim.notify = original
    assert(ok, err)
    return messages
  end

  local day_path = function(day)
    return root .. "/journals/" .. day .. ".md"
  end

  it("leaves a day that changed on disk alone when only another day was edited", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    write_file(day_path("2026_07_30"), "- changed elsewhere\n")

    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- [[Neovim]] edited" })
    vim.cmd("write")

    assert.are.equal("- changed elsewhere\n", helpers.read_file(day_path("2026_07_30")))
    assert.are.equal(
      "- [[Neovim]] edited\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n",
      helpers.read_file(day_path("2026_08_01"))
    )
    close_journal_buf(bufnr)
  end)

  it("merges an edit with a change to a different line made on disk, and shows the result", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    -- On disk: the last line changes and a line is added.
    write_file(
      day_path("2026_08_01"),
      "- [[Neovim]]\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png) (from the web)\n  - added in the browser\n"
    )

    -- In nvim: the first line changes.
    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- [[Neovim]] edited in nvim" })
    vim.cmd("write")

    local merged = "- [[Neovim]] edited in nvim\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png) (from the web)\n  - added in the browser\n"
    assert.are.equal(merged, helpers.read_file(day_path("2026_08_01")))
    assert.is_false(vim.bo[bufnr].modified)

    -- The buffer shows the merged day, and the next day's header still
    -- follows it right after the separator.
    row = find_row(bufnr, "# 2026_08_01")
    local shown = vim.api.nvim_buf_get_lines(bufnr, row + 1, row + 7, false)
    assert.are.same({
      "- [[Neovim]] edited in nvim",
      "  - Wired up logsvim.nvim",
      "  - ![screenshot.png](../assets/screenshot.png) (from the web)",
      "  - added in the browser",
      "",
      "# 2026_07_31",
    }, shown)

    -- A second save with no further edits writes nothing more: the merged
    -- result is now the day's baseline.
    local mtime = vim.fn.getftime(day_path("2026_08_01"))
    vim.cmd("write")
    assert.are.equal(mtime, vim.fn.getftime(day_path("2026_08_01")))

    close_journal_buf(bufnr)
  end)

  it("refuses to write a day that conflicts with a change on disk, until :w!", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    write_file(day_path("2026_08_01"), "- [[Neovim]] from the web\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n")

    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- [[Neovim]] from nvim" })
    -- Also edit another day, which has no conflict and must still be saved.
    local other = find_row(bufnr, "# 2026_07_31")
    vim.api.nvim_buf_set_lines(bufnr, other + 1, other + 1, false, { "- saved anyway" })

    local messages = capture_notify(function()
      vim.cmd("write")
    end)

    assert.are.equal(
      "- [[Neovim]] from the web\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n",
      helpers.read_file(day_path("2026_08_01"))
    )
    assert.truthy(helpers.read_file(day_path("2026_07_31")):find("^%- saved anyway\n"))
    assert.is_true(vim.bo[bufnr].modified)
    assert.are.equal(1, #messages)
    assert.truthy(messages[1]:find("journals/2026_08_01.md changed on disk", 1, true))

    vim.cmd("write!")
    assert.are.equal(
      "- [[Neovim]] from nvim\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n",
      helpers.read_file(day_path("2026_08_01"))
    )
    assert.is_false(vim.bo[bufnr].modified)

    close_journal_buf(bufnr)
  end)

  it("keeps the next batch's boundaries correct after a merge grows the last loaded day", function()
    config.setup({ root = root, journal_batch_size = 1 })
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()
    local st = journal._test.state[bufnr]

    -- today + 2026_08_01 loaded; 2026_08_01 is the last, open-ended day.
    journal._test.maybe_load_more(bufnr)
    assert.are.equal(3, st.next_index)

    write_file(
      day_path("2026_08_01"),
      "- [[Neovim]]\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n  - web 1\n  - web 2\n"
    )
    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- [[Neovim]] nvim" })
    vim.cmd("write")
    assert.are.equal(
      "- [[Neovim]] nvim\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n  - web 1\n  - web 2\n",
      helpers.read_file(day_path("2026_08_01"))
    )

    -- Load 2026_07_31 below it, then edit the end of 2026_08_01 and the
    -- start of 2026_07_31: each edit must land in its own file.
    journal._test.maybe_load_more(bufnr)
    local web2 = find_row(bufnr, "  - web 2")
    vim.api.nvim_buf_set_lines(bufnr, web2 + 1, web2 + 1, false, { "  - appended after merge" })
    local next_header = find_row(bufnr, "# 2026_07_31")
    vim.api.nvim_buf_set_lines(bufnr, next_header + 1, next_header + 1, false, { "- first in 07_31" })
    vim.cmd("write")

    assert.are.equal(
      "- [[Neovim]] nvim\n  - Wired up logsvim.nvim\n  - ![screenshot.png](../assets/screenshot.png)\n  - web 1\n  - web 2\n  - appended after merge\n",
      helpers.read_file(day_path("2026_08_01"))
    )
    assert.truthy(helpers.read_file(day_path("2026_07_31")):find("^%- first in 07_31\n%- %[%[Plugin Ideas%]%]"))

    close_journal_buf(bufnr)
  end)

  it("merges into an empty day", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()
    local today = graph.filename_display(graph.date_to_filename(os.time()))

    -- Both sides add different content to today's empty file.
    write_file(day_path(today), "- from the web\n")
    vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "- from nvim" })
    local messages = capture_notify(function()
      vim.cmd("write")
    end)

    -- Both inserted at the same spot: a conflict, so nothing is written.
    assert.are.equal("- from the web\n", helpers.read_file(day_path(today)))
    assert.are.equal(1, #messages)
    assert.is_true(vim.bo[bufnr].modified)

    close_journal_buf(bufnr)
  end)

  it(":LogsvimReload refreshes an unedited day and keeps an edited one", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    write_file(day_path("2026_07_30"), "- refreshed from disk\n")
    write_file(day_path("2026_08_01"), "- also changed on disk\n")

    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- my edit" })

    local messages = capture_notify(function()
      vim.cmd("LogsvimReload")
    end)

    row = find_row(bufnr, "# 2026_07_30")
    assert.are.same({ "- refreshed from disk" }, vim.api.nvim_buf_get_lines(bufnr, row + 1, -1, false))
    assert.truthy(find_row(bufnr, "- my edit"))
    assert.is_nil(find_row(bufnr, "- also changed on disk"))
    assert.is_true(vim.bo[bufnr].modified)
    assert.are.equal(1, #messages)
    assert.truthy(messages[1]:find("journals/2026_08_01.md changed on disk", 1, true))

    -- Notified once per disk version, not on every reload.
    messages = capture_notify(function()
      vim.cmd("LogsvimReload")
    end)
    assert.are.equal(0, #messages)

    close_journal_buf(bufnr)
  end)

  it(":LogsvimReload! discards edits and loads the file", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    write_file(day_path("2026_08_01"), "- changed on disk\n")
    local row = find_row(bufnr, "# 2026_08_01")
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 2, false, { "- my edit" })

    vim.cmd("LogsvimReload!")

    assert.is_nil(find_row(bufnr, "- my edit"))
    row = find_row(bufnr, "# 2026_08_01")
    assert.are.same({ "- changed on disk", "", "# 2026_07_31" }, vim.api.nvim_buf_get_lines(bufnr, row + 1, row + 4, false))
    assert.is_false(vim.bo[bufnr].modified)

    -- The reloaded version is the new baseline: saving writes nothing.
    local mtime = vim.fn.getftime(day_path("2026_08_01"))
    vim.cmd("write")
    assert.are.equal(mtime, vim.fn.getftime(day_path("2026_08_01")))

    close_journal_buf(bufnr)
  end)

  it("reloads on FocusGained without marking the buffer modified", function()
    journal.open(root)
    local bufnr = vim.api.nvim_get_current_buf()

    write_file(day_path("2026_07_30"), "- refreshed on focus\n")
    vim.api.nvim_exec_autocmds("FocusGained", {})

    assert.truthy(find_row(bufnr, "- refreshed on focus"))
    assert.is_false(vim.bo[bufnr].modified)

    close_journal_buf(bufnr)
  end)
end)

describe("graph.filename_display", function()
  it("strips the .md extension", function()
    assert.are.equal("2026_08_01", graph.filename_display("2026_08_01.md"))
  end)
end)
