local edit = require("logsvim.edit")
local config = require("logsvim.config")

describe("edit.bullet_for", function()
  it("prefixes with '- ' and no indentation for a top-level anchor", function()
    assert.are.equal("- ", edit._test.bullet_for("- [[Neovim]]"))
  end)

  it("matches the anchor line's leading tabs", function()
    assert.are.equal("\t\t- ", edit._test.bullet_for("\t\tsome continuation prose"))
  end)

  it("matches the anchor line's leading spaces", function()
    assert.are.equal("    - ", edit._test.bullet_for("    - already a bullet"))
  end)

  it("treats a blank anchor as top-level", function()
    assert.are.equal("- ", edit._test.bullet_for(""))
  end)
end)

describe("edit.apply_indent_settings", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("uses a literal tab for the default 'tab' indentation", function()
    config.setup({ indentation = "tab" })
    edit._test.apply_indent_settings(bufnr)
    assert.is_false(vim.bo[bufnr].expandtab)
    assert.are.equal(8, vim.bo[bufnr].shiftwidth)
    assert.are.equal(8, vim.bo[bufnr].tabstop)
    assert.are.equal(0, vim.bo[bufnr].softtabstop)
  end)

  it("expands to spaces matching the configured width otherwise", function()
    config.setup({ indentation = "four-spaces" })
    edit._test.apply_indent_settings(bufnr)
    assert.is_true(vim.bo[bufnr].expandtab)
    assert.are.equal(4, vim.bo[bufnr].shiftwidth)
    assert.are.equal(4, vim.bo[bufnr].tabstop)
    assert.are.equal(4, vim.bo[bufnr].softtabstop)
  end)
end)

describe("edit.shift_line", function()
  local bufnr

  before_each(function()
    config.setup({ indentation = "tab" })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("indents the line, shifting the cursor right by one unit so it stays before the same character", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- right before "Neovim"

    edit._test.shift_line(true)

    assert.are.same({ "\t- [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.same({ 1, 5 }, vim.api.nvim_win_get_cursor(0)) -- still right before "Neovim"
  end)

  it("dedents the line, shifting the cursor left by one unit so it stays before the same character", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "\t- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- right before "Neovim"

    edit._test.shift_line(false)

    assert.are.same({ "- [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0)) -- still right before "Neovim"
  end)

  it("is a no-op when dedenting a line with no indentation to remove", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    edit._test.shift_line(false)

    assert.are.same({ "- [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("uses config.options.indentation's space width, not a literal tab, when configured", function()
    config.setup({ indentation = "four-spaces" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    edit._test.shift_line(true)

    assert.are.same({ "    - [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.same({ 1, 8 }, vim.api.nvim_win_get_cursor(0))
  end)
end)

describe("edit.attach", function()
  local bufnr

  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  before_each(function()
    config.setup({ indentation = "tab" })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    edit.attach(bufnr)
    -- Simulate the user's own global indent settings that reportedly
    -- doubled up with ours: autoindent copies the previous line's leading
    -- whitespace into any newly opened line on its own.
    vim.bo[bufnr].autoindent = true
  end)

  after_each(function()
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("<CR> starts the new line with exactly the anchor's indent, not doubled up by autoindent", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "\t- [[Neovim]]" })
    -- "A" enters insert mode at end-of-line in the same feedkeys call as the
    -- <CR>; issuing startinsert and feedkeys as separate calls doesn't
    -- reliably carry insert mode over in a headless run.
    feed("A<CR>text")

    assert.are.same({ "\t- [[Neovim]]", "\t- text" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("<Tab> is wired up to indent the current line in insert mode", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    feed("i<Tab>")

    assert.are.same({ "\t- [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("<S-Tab> is wired up to dedent the current line in insert mode", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "\t- [[Neovim]]" })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    feed("i<S-Tab>")

    assert.are.same({ "- [[Neovim]]" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("edit.cycle_marker", function()
  local function cycle(line, workflow, times)
    for _ = 1, times or 1 do
      line = edit._test.cycle_marker(line, workflow)
    end
    return line
  end

  it("cycles none -> LATER -> NOW -> DONE -> none in the now workflow", function()
    assert.are.equal("- LATER call Bob", cycle("- call Bob", "now"))
    assert.are.equal("- NOW call Bob", cycle("- call Bob", "now", 2))
    assert.are.equal("- DONE call Bob", cycle("- call Bob", "now", 3))
    assert.are.equal("- call Bob", cycle("- call Bob", "now", 4))
  end)

  it("cycles none -> TODO -> DOING -> DONE -> none in the todo workflow", function()
    assert.are.equal("- TODO call Bob", cycle("- call Bob", "todo"))
    assert.are.equal("- DOING call Bob", cycle("- call Bob", "todo", 2))
    assert.are.equal("- DONE call Bob", cycle("- call Bob", "todo", 3))
    assert.are.equal("- call Bob", cycle("- call Bob", "todo", 4))
  end)

  it("follows an existing marker's own cycle regardless of workflow", function()
    assert.are.equal("- DOING x", cycle("- TODO x", "now"))
    assert.are.equal("- NOW x", cycle("- LATER x", "todo"))
  end)

  it("restarts the cycle from other markers", function()
    assert.are.equal("- LATER x", cycle("- WAITING x", "now"))
    assert.are.equal("- TODO x", cycle("- CANCELED x", "todo"))
  end)

  it("keeps indentation and handles empty bullets", function()
    assert.are.equal("\t\t- LATER x", cycle("\t\t- x", "now"))
    assert.are.equal("    - DONE x", cycle("    - NOW x", "now"))
    assert.are.equal("- LATER", cycle("- ", "now"))
    assert.are.equal("- LATER", cycle("-", "now"))
    assert.are.equal("- ", cycle("- DONE", "now"))
  end)

  it("does not treat marker-like prose as a marker", function()
    assert.are.equal("- LATER DONE-ish workaround", cycle("- DONE-ish workaround", "now"))
  end)

  it("keeps a leading uppercase word that isn't a task marker", function()
    assert.are.equal("- LATER API design notes", cycle("- API design notes", "now"))
    assert.are.equal("- TODO I think so", cycle("- I think so", "todo"))
    assert.are.equal("- LATER PR 42 merged", cycle("- PR 42 merged", "now"))
  end)

  it("leaves non-bullet lines unchanged", function()
    assert.are.equal("\t  continuation", cycle("\t  continuation", "now"))
  end)
end)

describe("edit.cycle_task", function()
  local bufnr

  before_each(function()
    config.setup({ workflow = "todo" })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    config.setup({})
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("cycles the bullet a continuation line belongs to", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- first", "\t- call Bob", "\t  about lunch" })
    vim.api.nvim_win_set_cursor(0, { 3, 5 })
    edit._test.cycle_task()

    assert.are.same({ "- first", "\t- TODO call Bob", "\t  about lunch" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.are.same({ 3, 5 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("keeps the cursor on the same text as the marker changes length", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- call Bob" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- on "B"
    edit._test.cycle_task()
    assert.are.equal("- TODO call Bob", vim.api.nvim_get_current_line())
    assert.are.same({ 1, 12 }, vim.api.nvim_win_get_cursor(0))

    edit._test.cycle_task() -- TODO -> DOING
    assert.are.same({ 1, 13 }, vim.api.nvim_win_get_cursor(0))

    edit._test.cycle_task() -- DOING -> DONE
    edit._test.cycle_task() -- DONE -> none
    assert.are.equal("- call Bob", vim.api.nvim_get_current_line())
    assert.are.same({ 1, 7 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("does nothing without a bullet above the cursor", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# 2026_09_29", "prose" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    edit._test.cycle_task()
    assert.are.same({ "# 2026_09_29", "prose" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
