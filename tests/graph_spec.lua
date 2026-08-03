local helpers = require("tests.helpers")
local config = require("logsvim.config")
local graph = require("logsvim.graph")

describe("graph.build_journal_block", function()
  before_each(function()
    config.setup({ indentation = "two-spaces" })
  end)

  it("marks only the first content line as a bullet; later lines continue it", function()
    local lines = graph.build_journal_block("Neovim", "line one\nline two", { "shot.png" })
    assert.are.same({
      "- [[Neovim]]",
      "  - line one",
      "    line two",
      "  - ![shot.png](../assets/shot.png)",
    }, lines)
  end)

  it("preserves blank lines within contents as truly blank", function()
    local lines = graph.build_journal_block("Topic", "a\n\nb")
    assert.are.same({ "- [[Topic]]", "  - a", "", "    b" }, lines)
  end)

  it("escapes a leading dash so it isn't misread as a new bullet", function()
    local lines = graph.build_journal_block("Topic", "- pasted list item\n- another")
    assert.are.same({ "- [[Topic]]", "  - \\- pasted list item", "    \\- another" }, lines)
  end)

  it("works with just a topic", function()
    assert.are.same({ "- [[Topic]]" }, graph.build_journal_block("Topic"))
  end)

  it("defaults to tab indentation", function()
    config.setup({ indentation = "tab" })
    local lines = graph.build_journal_block("Topic", "hi")
    assert.are.same({ "- [[Topic]]", "\t- hi" }, lines)
  end)
end)

describe("graph.date_to_filename", function()
  it("matches Logseq's default journal filename format (yyyy_MM_dd)", function()
    -- 2026-08-02 12:00:00 UTC
    local t = os.time({ year = 2026, month = 8, day = 2, hour = 12 })
    assert.are.equal("2026_08_02.md", graph.date_to_filename(t))
  end)
end)

describe("graph.append_block", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root, indentation = "two-spaces" })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("creates the file and parent dir when absent", function()
    local path = root .. "/journals/2099_01_01.md"
    graph.append_block(path, { "- [[New]]", "  hello" })
    assert.are.equal("- [[New]]\n  hello\n", helpers.read_file(path))
  end)

  it("appends with a blank-line separator when the file has content", function()
    local path = root .. "/journals/2026_07_30.md"
    local before = helpers.read_file(path)
    graph.append_block(path, { "- [[More]]", "  stuff" })
    local after = helpers.read_file(path)
    assert.are.equal(before:gsub("\n$", "") .. "\n\n- [[More]]\n  stuff\n", after)
  end)
end)

describe("graph.ensure_journal_file", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("creates an empty file and parent dir when absent", function()
    local t = os.time({ year = 2099, month = 1, day = 1, hour = 12 })
    local path = graph.ensure_journal_file(root, t)
    assert.are.equal(root .. "/journals/2099_01_01.md", path)
    assert.are.equal("", helpers.read_file(path))
  end)

  it("leaves an existing file untouched", function()
    local path = root .. "/journals/2026_07_30.md"
    local before = helpers.read_file(path)
    local t = os.time({ year = 2026, month = 7, day = 30, hour = 12 })
    graph.ensure_journal_file(root, t)
    assert.are.equal(before, helpers.read_file(path))
  end)
end)

describe("graph.looks_like_root", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("is true for a directory with a journals or pages subdir", function()
    assert.is_true(graph.looks_like_root(root))
  end)

  it("is false for a directory with neither", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    assert.is_false(graph.looks_like_root(empty))
    helpers.rmtree(empty)
  end)
end)

describe("graph.resolve_root", function()
  local root, orig_cwd

  -- Seed the (isolated) cache dir with a dummy cache file, so known_roots()
  -- reports `for_root` as a known graph without needing a real async
  -- index.refresh().
  local function seed_cache(for_root)
    local cache_dir = vim.fn.expand(config.options.cache_dir)
    vim.fn.mkdir(cache_dir, "p")
    local slug = for_root:gsub("[/\\]", "%%")
    vim.fn.writefile({ "[]" }, cache_dir .. "/" .. slug .. ".json")
  end

  before_each(function()
    root = helpers.temp_graph()
    orig_cwd = vim.fn.getcwd()
    -- Deliberately not passing `root` here: that would mark it explicit and
    -- short-circuit resolve_root's cwd/parent/cache discovery entirely.
    config.setup({ cache_dir = vim.fn.tempname() })
    graph._test.reset_resolved_root()
  end)

  after_each(function()
    vim.env.LOGSVIM_ROOT = nil
    vim.fn.chdir(orig_cwd)
    helpers.rmtree(root)
    graph._test.reset_resolved_root()
  end)

  it("uses $LOGSVIM_ROOT when set", function()
    vim.env.LOGSVIM_ROOT = root
    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(root, got)
  end)

  it("uses cwd when it looks like a graph root", function()
    vim.fn.chdir(root)
    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(root, got)
  end)

  it("falls back to the parent directory when cwd itself isn't a root", function()
    local sub = root .. "/subdir"
    vim.fn.mkdir(sub, "p")
    vim.fn.chdir(sub)
    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(root, got)
  end)

  it("falls back to the sole cached graph when cwd and its parent aren't roots", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)
    seed_cache(root)

    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(root, got)
    helpers.rmtree(empty)
  end)

  it("lets the user pick when multiple cached graphs exist", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    local other = helpers.temp_graph()
    seed_cache(root)
    seed_cache(other)

    local original_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      on_choice(other)
    end

    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(other, got)

    vim.ui.select = original_select
    helpers.rmtree(empty)
    helpers.rmtree(other)
  end)

  it("notifies and calls back with nil when no graph can be found", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    local message, level
    local original_notify = vim.notify
    vim.notify = function(msg, lvl)
      message, level = msg, lvl
    end

    local got, called = "sentinel", false
    graph.resolve_root(function(r)
      got, called = r, true
    end)

    vim.notify = original_notify
    assert.is_true(called)
    assert.is_nil(got)
    assert.truthy(message:find("No graphs found", 1, true))
    assert.are.equal(vim.log.levels.ERROR, level)
    helpers.rmtree(empty)
  end)

  it("memoizes the resolved root, ignoring a later cwd change", function()
    vim.fn.chdir(root)
    graph.resolve_root(function() end)

    local elsewhere = vim.fn.tempname()
    vim.fn.mkdir(elsewhere, "p")
    vim.fn.chdir(elsewhere)

    local got
    graph.resolve_root(function(r)
      got = r
    end)
    assert.are.equal(root, got)
    helpers.rmtree(elsewhere)
  end)
end)
