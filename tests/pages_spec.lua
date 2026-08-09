local helpers = require("tests.helpers")
local config = require("logsvim.config")
local graph = require("logsvim.graph")
local pages = require("logsvim.pages")
local journal = require("logsvim.journal")

local function close_buf(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].modified = false
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

describe("pages.find_references", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("finds a block whose header references the page, grouped by date, newest first", function()
    local groups = pages.find_references(root, "Neovim")
    assert.are.equal(2, #groups)
    assert.are.equal("2026_08_01", groups[1].date)
    assert.are.equal("2026_07_30", groups[2].date)
    assert.are.same({ "- [[Neovim]]", "  - Wired up logsvim.nvim", "  - ![screenshot.png](../assets/screenshot.png)" }, groups[1].lines)
  end)

  it("includes the enclosing bullet as context for a reference buried in a continuation line, re-indented under it", function()
    local groups = pages.find_references(root, "Plugin Ideas")
    assert.are.equal(2, #groups)
    local by_date = {}
    for _, g in ipairs(groups) do
      by_date[g.date] = g
    end
    -- 2026_07_31: "[[Plugin Ideas]]" is the block header itself, so no
    -- ancestor context is needed -- unchanged from the source.
    assert.are.same({ "- [[Plugin Ideas]]", "  - logsvim: journal quick-add", "  - logsvim: page backlinks" }, by_date["2026_07_31"].lines)
    -- 2026_07_30: referenced mid-block, under "- [[Neovim]]" -- that
    -- enclosing bullet is now included as context, and the reference's
    -- indentation is corrected relative to it rather than copied raw.
    assert.are.same({ "- [[Neovim]]", "\t- Started reading the [[Plugin Ideas]] notes" }, by_date["2026_07_30"].lines)
  end)

  it("merges two references sharing a parent within the same day, rendering the parent once", function()
    local f = io.open(root .. "/journals/2026_07_29.md", "w")
    f:write("- Parent\n\t- mentions [[TestPage]] once\n\t- mentions [[TestPage]] again\n")
    f:close()

    local groups = pages.find_references(root, "TestPage")
    assert.are.equal(1, #groups)
    assert.are.equal("2026_07_29", groups[1].date)
    assert.are.same({
      "- Parent",
      "\t- mentions [[TestPage]] once",
      "\t- mentions [[TestPage]] again",
    }, groups[1].lines)
  end)

  it("returns no groups for a page with no references", function()
    assert.are.same({}, pages.find_references(root, "NoSuchPage"))
  end)
end)

describe("pages.render", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("shows the page's own contents before its linked references", function()
    local lines = pages.render(root, "Neovim")
    local text = table.concat(lines, "\n")
    assert.are.equal("# Neovim", lines[1])
    assert.truthy(text:find("Text editor extensible with Lua.", 1, true))
    assert.truthy(text:find("## Linked references", 1, true))
    assert.truthy(text:find("### 2026_08_01", 1, true))
  end)

  it("omits page contents entirely for a page that only exists as a [[link]]", function()
    local lines = pages.render(root, "Plugin Ideas")
    assert.are.equal("# Plugin Ideas", lines[1])
    assert.are.equal("", lines[2])
    assert.are.equal("## Linked references", lines[3])
  end)

  it("omits the linked references section for a page with no references", function()
    local lines = pages.render(root, "NoSuchPage")
    local text = table.concat(lines, "\n")
    assert.is_falsy(text:find("Linked references", 1, true))
  end)
end)

describe("pages.render for a pseudo-page", function()
  local root

  local function write_file(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
  end

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("renders the Scheduled pseudo-page with no editable content region", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2020-01-01 Wed>\n")

    local lines, content_end = pages.render(root, "Scheduled")
    assert.are.equal("# Scheduled", lines[1])
    assert.are.equal("", lines[2])
    assert.are.equal(2, content_end)
    assert.are.equal("### Project", lines[3])
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("TODO Ship v2", 1, true))
  end)

  it("renders a task-status pseudo-page listing every block with that marker", function()
    write_file(root .. "/pages/Groceries.md", "- LATER Buy milk\n")

    local lines = pages.render(root, "LATER")
    assert.are.equal("# LATER", lines[1])
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("### Groceries", 1, true))
    assert.truthy(text:find("LATER Buy milk", 1, true))
  end)

  it("renders just the header when a status has no matches", function()
    local lines, content_end = pages.render(root, "WAITING")
    assert.are.same({ "# WAITING", "" }, lines)
    assert.are.equal(2, content_end)
  end)

  it("ignores a real pages/<name>.md file that happens to collide with a pseudo-page name", function()
    write_file(root .. "/pages/DONE.md", "Some unrelated personal notes.\n")

    local lines = pages.render(root, "DONE")
    local text = table.concat(lines, "\n")
    assert.is_falsy(text:find("unrelated personal notes", 1, true))
  end)
end)

describe("pages.open buffer", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("opens an editable acwrite buffer rendering the page", function()
    pages.open("Neovim")
    local bufnr = vim.api.nvim_get_current_buf()

    assert.are.equal("acwrite", vim.bo[bufnr].buftype)
    assert.is_true(vim.bo[bufnr].modifiable)
    assert.is_false(vim.bo[bufnr].modified)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.equal("# Neovim", lines[1])

    close_buf(bufnr)
  end)

  it("saving edited content updates pages/<name>.md", function()
    pages.open("Neovim")
    local bufnr = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "Updated description." })
    vim.cmd("write")

    assert.are.equal("Updated description.\n", helpers.read_file(root .. "/pages/Neovim.md"))
    assert.is_false(vim.bo[bufnr].modified)

    close_buf(bufnr)
  end)

  it("saving a brand-new page creates pages/<name>.md", function()
    pages.open("NoSuchPage")
    local bufnr = vim.api.nvim_get_current_buf()

    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/NoSuchPage.md"))

    vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "Freshly created content." })
    vim.cmd("write")

    assert.are.equal("Freshly created content.\n", helpers.read_file(root .. "/pages/NoSuchPage.md"))

    close_buf(bufnr)
  end)

  it("discards edits made to the linked references section on save", function()
    pages.open("Neovim")
    local bufnr = vim.api.nvim_get_current_buf()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ref_lnum
    for i, l in ipairs(lines) do
      if l == "## Linked references" then
        ref_lnum = i
        break
      end
    end
    assert.truthy(ref_lnum)

    vim.api.nvim_buf_set_lines(bufnr, ref_lnum, ref_lnum, false, { "tampered reference text" })
    vim.cmd("write")

    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_falsy(text:find("tampered reference text", 1, true))
    assert.is_falsy(helpers.read_file(root .. "/pages/Neovim.md"):find("tampered", 1, true))

    close_buf(bufnr)
  end)

  it("re-reads from disk on repeated opens instead of showing stale content", function()
    pages.open("Neovim")
    local first = vim.api.nvim_get_current_buf()
    close_buf(first)

    -- add a fresh reference after the first open
    local path = root .. "/journals/2026_08_01.md"
    local f = io.open(path, "a")
    f:write("\n- [[Neovim]]\n  - second mention\n")
    f:close()

    pages.open("Neovim")
    local second = vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(second, 0, -1, false), "\n")
    assert.truthy(text:find("second mention", 1, true))

    close_buf(second)
  end)

  it("goto_reference jumps to the referencing date in the journal", function()
    pages.open("Neovim")
    local page_buf = vim.api.nvim_get_current_buf()

    local lnum
    local lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == "### 2026_07_30" then
        lnum = i
        break
      end
    end
    assert.truthy(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })

    pages.goto_reference(page_buf)

    local journal_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("acwrite", vim.bo[journal_buf].buftype)
    local cursor_line = vim.api.nvim_get_current_line()
    assert.are.equal("# 2026_07_30", cursor_line)

    close_buf(page_buf)
    close_buf(journal_buf)
  end)
end)

describe("pages.open buffer for a pseudo-page", function()
  local root

  local function write_file(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
  end

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("opens like any other page, via :LogsvimPage or a [[Name]] link", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2020-01-01 Wed>\n")

    pages.open("Scheduled")
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("acwrite", vim.bo[bufnr].buftype)
    assert.are.equal("# Scheduled", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])

    close_buf(bufnr)
  end)

  it("never writes a real pages/<name>.md file, even if the buffer is edited before saving", function()
    pages.open("LATER")
    local bufnr = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "tampered text" })
    vim.cmd("write")

    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/LATER.md"))
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_falsy(text:find("tampered text", 1, true))

    close_buf(bufnr)
  end)

  it("re-renders against the current graph state on save, like a live query", function()
    pages.open("LATER")
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_falsy(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("Buy milk", 1, true))

    write_file(root .. "/pages/Groceries.md", "- LATER Buy milk\n")
    vim.cmd("write")

    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("Buy milk", 1, true))

    close_buf(bufnr)
  end)

  it("goto_reference opens the source page for a page-sourced group", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2020-01-01 Wed>\n")

    pages.open("Scheduled")
    local sched_buf = vim.api.nvim_get_current_buf()

    local lnum
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sched_buf, 0, -1, false)) do
      if l == "### Project" then
        lnum = i
        break
      end
    end
    assert.truthy(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })

    pages.goto_reference(sched_buf)

    local project_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("# Project", vim.api.nvim_buf_get_lines(project_buf, 0, 1, false)[1])

    close_buf(sched_buf)
    close_buf(project_buf)
  end)

  it("goto_reference jumps to the journal date for a journal-sourced group", function()
    local path = root .. "/journals/2026_07_30.md"
    local before = helpers.read_file(path)
    write_file(path, before:gsub("\n$", "") .. "\n\n- TODO Old task\n  SCHEDULED: <2020-01-01 Wed>\n")

    pages.open("Scheduled")
    local sched_buf = vim.api.nvim_get_current_buf()

    local lnum
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sched_buf, 0, -1, false)) do
      if l == "### 2026_07_30" then
        lnum = i
        break
      end
    end
    assert.truthy(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })

    pages.goto_reference(sched_buf)

    local journal_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("acwrite", vim.bo[journal_buf].buftype)
    assert.are.equal("# 2026_07_30", vim.api.nvim_get_current_line())

    close_buf(sched_buf)
    close_buf(journal_buf)
  end)

  it("rejects renaming a pseudo-page name", function()
    local message
    local original_notify = vim.notify
    vim.notify = function(msg)
      message = msg
    end

    pages.rename(root, "Scheduled", "MyScheduled")

    vim.notify = original_notify
    assert.truthy(message and message:find("built%-in page"))
  end)
end)

describe("pages.open_under_cursor", function()
  local root, bufnr

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  - see [[Neovim]] for details" })
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    helpers.rmtree(root)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("opens the page whose [[link]] the cursor is inside", function()
    vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- inside "Neovim"
    pages.open_under_cursor()
    local page_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("# Neovim", vim.api.nvim_buf_get_lines(page_buf, 0, 1, false)[1])
    close_buf(page_buf)
  end)
end)

describe("pages.goto_under_cursor", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("opens the page whose [[link]] the cursor is on, same as open_under_cursor", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  - see [[Neovim]] for details" })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- inside "Neovim"

    pages.goto_under_cursor()

    local page_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("# Neovim", vim.api.nvim_buf_get_lines(page_buf, 0, 1, false)[1])
    close_buf(page_buf)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("falls back to jumping to the referencing date when the cursor isn't on a [[link]]", function()
    pages.open("Neovim")
    local page_buf = vim.api.nvim_get_current_buf()

    local lnum
    local lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == "### 2026_07_30" then
        lnum = i
        break
      end
    end
    assert.truthy(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })

    pages.goto_under_cursor()

    local journal_buf = vim.api.nvim_get_current_buf()
    assert.are.equal("acwrite", vim.bo[journal_buf].buftype)
    assert.are.equal("# 2026_07_30", vim.api.nvim_get_current_line())

    close_buf(page_buf)
    close_buf(journal_buf)
  end)

  it("warns instead of erroring outside a page buffer when there's no [[link]] under the cursor", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "just some text" })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local message
    local original_notify = vim.notify
    vim.notify = function(msg)
      message = msg
    end

    pages.goto_under_cursor()

    vim.notify = original_notify
    assert.truthy(message and message:find("no %[%[Page%]%] link under cursor"))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

describe("pages.rename", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("renames a page's file and updates every reference", function()
    pages.rename(root, "Neovim", "Neovim Editor")

    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/Neovim.md"))
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim Editor.md"))
    assert.truthy(helpers.read_file(root .. "/journals/2026_08_01.md"):find("[[Neovim Editor]]", 1, true))
  end)

  it("closes the renamed page's own buffer and reopens it under the new name", function()
    pages.open("Neovim")
    local old_bufnr = vim.api.nvim_get_current_buf()

    pages.rename(root, "Neovim", "Neovim Editor")

    assert.is_false(vim.api.nvim_buf_is_valid(old_bufnr))
    local new_bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("# Neovim Editor", vim.api.nvim_buf_get_lines(new_bufnr, 0, 1, false)[1])

    close_buf(new_bufnr)
  end)

  it("reloads an unrelated, unmodified page buffer whose references quote the renamed page", function()
    pages.open("Neovim")
    local neovim_buf = vim.api.nvim_get_current_buf()

    pages.rename(root, "Plugin Ideas", "Ideas")

    local text = table.concat(vim.api.nvim_buf_get_lines(neovim_buf, 0, -1, false), "\n")
    assert.truthy(text:find("[[Ideas]]", 1, true))
    assert.is_falsy(text:find("[[Plugin Ideas]]", 1, true))

    close_buf(neovim_buf)
  end)

  it("leaves a modified buffer alone and warns instead of silently discarding its edits", function()
    pages.open("Neovim")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "unsaved edit" })

    local messages = {}
    local original_notify = vim.notify
    vim.notify = function(msg)
      table.insert(messages, msg)
    end

    pages.rename(root, "Neovim", "Neovim Editor")

    vim.notify = original_notify
    local warned = false
    for _, msg in ipairs(messages) do
      if msg:find("unsaved changes", 1, true) then
        warned = true
      end
    end
    assert.is_true(warned)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    -- the underlying file was still renamed even though this buffer is stale
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim Editor.md"))

    close_buf(bufnr)
  end)

  it("errors instead of clobbering an existing page with the new name", function()
    local f = io.open(root .. "/pages/Taken.md", "w")
    f:write("x\n")
    f:close()

    local message
    local original_notify = vim.notify
    vim.notify = function(msg)
      message = msg
    end

    pages.rename(root, "Neovim", "Taken")

    vim.notify = original_notify
    assert.truthy(message)
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim.md"))
  end)
end)

describe("pages.rename_under_cursor", function()
  local root, bufnr

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  - see [[Neovim]] for details" })
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    helpers.rmtree(root)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("prompts for a new name and renames the [[Page]] link under the cursor", function()
    vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- inside "Neovim"

    local original_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("Neovim Editor")
    end

    pages.rename_under_cursor()

    vim.ui.input = original_input

    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/Neovim.md"))
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim Editor.md"))
  end)

  it("does nothing when there is no [[Page]] link under the cursor", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local called = false
    local original_input = vim.ui.input
    vim.ui.input = function()
      called = true
    end

    pages.rename_under_cursor()

    vim.ui.input = original_input
    assert.is_false(called)
  end)

  it("does nothing when the prompt is cancelled", function()
    vim.api.nvim_win_set_cursor(0, { 1, 12 })

    local original_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm(nil)
    end

    pages.rename_under_cursor()

    vim.ui.input = original_input
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim.md"))
  end)
end)
