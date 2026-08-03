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
