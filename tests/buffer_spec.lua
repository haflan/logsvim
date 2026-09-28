local helpers = require("tests.helpers")
local config = require("logsvim.config")
local graph = require("logsvim.graph")

describe("buffer auto-attach", function()
  local root, orig_cwd

  before_each(function()
    root = helpers.temp_graph()
    orig_cwd = vim.fn.getcwd()
    config.setup({ cache_dir = vim.fn.tempname() })
    graph._test.reset_resolved_root()
  end)

  after_each(function()
    vim.fn.chdir(orig_cwd)
    helpers.rmtree(root)
    graph._test.reset_resolved_root()
  end)

  it("attaches to a real page file opened directly, before any :Logsvim* command has resolved a root", function()
    -- cwd looks like the graph root, so graph.resolve_root() resolves it via
    -- its fast, non-interactive path -- but nothing has called resolve_root()
    -- yet, so config.options.root is still whatever the default snapshot
    -- was, not this test's root. Opening pages/Neovim.md directly (as if via
    -- a file explorer or quickfix) must still resolve the right root and
    -- attach, not silently rely on the stale default.
    vim.fn.chdir(root)

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(root .. "/pages/Neovim.md"))
    local bufnr = vim.api.nvim_get_current_buf()

    assert.is_true(vim.b[bufnr].logsvim_attached)
    -- So Neovim picks up changes made elsewhere (e.g. logsurf) on its own.
    assert.is_true(vim.bo[bufnr].autoread)

    vim.bo[bufnr].modified = false
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("doesn't notify when a markdown file outside any graph is opened", function()
    -- The BufEnter autocmd fires for every *.md buffer, including ones with
    -- no graph behind them at all, so it must resolve silently rather than
    -- nagging the user with resolve_root's usual "no graphs found" error.
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    local notified = false
    local original_notify = vim.notify
    vim.notify = function()
      notified = true
    end

    local path = empty .. "/notes.md"
    vim.fn.writefile({}, path)
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    vim.notify = original_notify
    assert.is_false(notified)
    assert.is_falsy(vim.b[bufnr].logsvim_attached)

    vim.bo[bufnr].modified = false
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    helpers.rmtree(empty)
  end)
end)
