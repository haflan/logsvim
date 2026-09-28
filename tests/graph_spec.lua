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

describe("graph.rename_page", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("rewrites every [[old]] reference to [[new]] across journals and pages, and renames the page file", function()
    local updated = graph.rename_page(root, "Neovim", "Neovim Editor")
    assert.are.equal(2, updated)

    assert.truthy(helpers.read_file(root .. "/journals/2026_07_30.md"):find("[[Neovim Editor]]", 1, true))
    assert.is_falsy(helpers.read_file(root .. "/journals/2026_07_30.md"):find("[[Neovim]]", 1, true))
    assert.truthy(helpers.read_file(root .. "/journals/2026_08_01.md"):find("[[Neovim Editor]]", 1, true))

    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/Neovim.md"))
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim Editor.md"))
  end)

  it("leaves links to other pages with a similar name untouched", function()
    graph.rename_page(root, "Neovim", "Neovim Editor")
    assert.truthy(helpers.read_file(root .. "/journals/2026_07_31.md"):find("[[Plugin Ideas]]", 1, true))
  end)

  it("updates references without touching the filesystem for a page with no file of its own", function()
    local updated = graph.rename_page(root, "Plugin Ideas", "Ideas")
    assert.are.equal(2, updated)
    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/Plugin Ideas.md"))
    assert.are.equal(0, vim.fn.filereadable(root .. "/pages/Ideas.md"))
    assert.truthy(helpers.read_file(root .. "/journals/2026_07_31.md"):find("[[Ideas]]", 1, true))
  end)

  it("errors instead of clobbering an existing page with the new name", function()
    local f = io.open(root .. "/pages/Taken.md", "w")
    f:write("x\n")
    f:close()

    local updated, err = graph.rename_page(root, "Neovim", "Taken")
    assert.is_nil(updated)
    assert.truthy(err)
    assert.are.equal(1, vim.fn.filereadable(root .. "/pages/Neovim.md"))
  end)

  it("errors instead of merging a link-only page into an existing page with the new name", function()
    -- "Plugin Ideas" (per the fixture) has references but no pages/Plugin
    -- Ideas.md of its own; renaming it onto "Neovim", which does have a
    -- file, must still be treated as a collision even though the *old*
    -- name's own file check trivially passes (there's nothing to clobber
    -- on disk, but the two pages' references would otherwise be merged).
    local updated, err = graph.rename_page(root, "Plugin Ideas", "Neovim")
    assert.is_nil(updated)
    assert.truthy(err)
    assert.truthy(helpers.read_file(root .. "/journals/2026_07_31.md"):find("[[Plugin Ideas]]", 1, true))
  end)

  it("errors instead of merging two link-only pages that collide on the new name", function()
    -- Neither "Plugin Ideas" nor "Groceries" (per the fixture) has a
    -- pages/*.md file of its own, so the file-existence check alone can't
    -- catch this collision -- it must be caught by scanning for an existing
    -- "[[Groceries]]" reference instead.
    local updated, err = graph.rename_page(root, "Plugin Ideas", "Groceries")

    assert.is_nil(updated)
    assert.truthy(err)
    assert.truthy(helpers.read_file(root .. "/journals/2026_07_31.md"):find("[[Plugin Ideas]]", 1, true))
  end)

  it("errors on an empty or unchanged new name", function()
    local updated, err = graph.rename_page(root, "Neovim", "")
    assert.is_nil(updated)
    assert.truthy(err)

    updated, err = graph.rename_page(root, "Neovim", "Neovim")
    assert.is_nil(updated)
    assert.truthy(err)
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

  it("with opts.silent, calls back with nil instead of notifying when no graph can be found", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    local notified = false
    local original_notify = vim.notify
    vim.notify = function()
      notified = true
    end

    local got, called = "sentinel", false
    graph.resolve_root(function(r)
      got, called = r, true
    end, { silent = true })

    vim.notify = original_notify
    assert.is_true(called)
    assert.is_nil(got)
    assert.is_false(notified)
    helpers.rmtree(empty)
  end)

  it("with opts.silent, does not silently pin the session to the sole cached graph when cwd doesn't match", function()
    -- Regression case: unlike an explicit resolve, a silent probe (e.g. from
    -- buffer.lua's BufEnter, firing on every markdown buffer) must not fall
    -- back to a globally cached graph just because it's the only one known --
    -- that file may have nothing to do with any graph at all, and auto-
    -- picking here would permanently memoize the wrong root for the session.
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    seed_cache(root)

    local got, called = "sentinel", false
    graph.resolve_root(function(r)
      got, called = r, true
    end, { silent = true })

    assert.is_true(called)
    assert.is_nil(got)
    helpers.rmtree(empty)
  end)

  it("with opts.silent, calls back with nil instead of prompting when multiple cached graphs exist", function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    vim.fn.chdir(empty)

    local other = helpers.temp_graph()
    seed_cache(root)
    seed_cache(other)

    local prompted = false
    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      prompted = true
      on_choice(other)
    end

    local got, called = "sentinel", false
    graph.resolve_root(function(r)
      got, called = r, true
    end, { silent = true })

    vim.ui.select = original_select
    assert.is_true(called)
    assert.is_nil(got)
    assert.is_false(prompted)

    helpers.rmtree(empty)
    helpers.rmtree(other)
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

describe("graph.write_lines_atomic", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  local function tmp_leftovers(dir)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, ".logsvim-tmp-")
    end, vim.fn.readdir(dir))
  end

  it("replaces the file's content and leaves no temp files behind", function()
    local path = root .. "/journals/2026_07_30.md"
    graph.write_lines_atomic(path, { "- one", "- two" })
    assert.are.equal("- one\n- two\n", helpers.read_file(path))
    assert.are.same({}, tmp_leftovers(root .. "/journals"))
  end)

  it("writes an empty list as an empty file", function()
    local path = root .. "/journals/2026_07_30.md"
    graph.write_lines_atomic(path, {})
    assert.are.equal("", helpers.read_file(path))
  end)

  it("keeps the existing file's mode", function()
    local path = root .. "/journals/2026_07_30.md"
    vim.fn.setfperm(path, "rw-------")
    graph.write_lines_atomic(path, { "- changed" })
    assert.are.equal("rw-------", vim.fn.getfperm(path))
  end)

  it("creates the file and its parent dir when absent", function()
    local path = root .. "/pages/sub/New.md"
    graph.write_lines_atomic(path, { "hello" })
    assert.are.equal("hello\n", helpers.read_file(path))
  end)
end)

describe("graph.write_lines_checked", function()
  local root, path

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
    path = root .. "/journals/2026_07_30.md"
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("writes when the file still holds the expected lines", function()
    local expected = graph.read_lines(path)
    assert.is_true(graph.write_lines_checked(path, expected, { "- new" }))
    assert.are.equal("- new\n", helpers.read_file(path))
  end)

  it("refuses and returns the disk lines when the file changed", function()
    local before = helpers.read_file(path)
    local ok, current = graph.write_lines_checked(path, { "- stale" }, { "- new" })
    assert.is_false(ok)
    assert.are.same(graph.read_lines(path), current)
    assert.are.equal(before, helpers.read_file(path))
  end)

  it("treats a missing file as empty", function()
    local missing = root .. "/journals/2099_01_01.md"
    assert.is_true(graph.write_lines_checked(missing, {}, { "- created" }))
    assert.are.equal("- created\n", helpers.read_file(missing))

    local other = root .. "/journals/2099_01_02.md"
    assert.is_false(graph.write_lines_checked(other, { "- something" }, { "- x" }))
    assert.are.equal(0, vim.fn.filereadable(other))
  end)
end)

describe("graph.merge_lines", function()
  it("merges edits to different lines", function()
    local base = { "a", "b", "c", "d", "e" }
    local ours = { "A", "b", "c", "d", "e" }
    local theirs = { "a", "b", "c", "d", "E" }
    assert.are.same({ "A", "b", "c", "d", "E" }, graph.merge_lines(ours, base, theirs))
  end)

  it("returns nil on a conflict", function()
    assert.is_nil(graph.merge_lines({ "ours" }, { "base" }, { "theirs" }))
  end)

  it("handles empty versions", function()
    assert.are.same({}, graph.merge_lines({}, { "a" }, { "a" }))
    assert.are.same({ "added" }, graph.merge_lines({}, {}, { "added" }))
  end)
end)
