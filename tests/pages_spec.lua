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
    assert.are.same({ "- [[Neovim]]", "  - Wired up logsvim.nvim", "  - ![screenshot.png](../assets/screenshot.png)" }, groups[1].blocks[1])
  end)

  it("finds a reference buried in a continuation line, not just block headers", function()
    local groups = pages.find_references(root, "Plugin Ideas")
    assert.are.equal(2, #groups)
    -- 2026_07_31: "[[Plugin Ideas]]" is the block header itself
    local by_date = {}
    for _, g in ipairs(groups) do
      by_date[g.date] = g
    end
    assert.are.same({ "- [[Plugin Ideas]]", "  - logsvim: journal quick-add", "  - logsvim: page backlinks" }, by_date["2026_07_31"].blocks[1])
    -- 2026_07_30: referenced mid-block, under "- [[Neovim]]"
    assert.are.same({ "  - Started reading the [[Plugin Ideas]] notes" }, by_date["2026_07_30"].blocks[1])
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
