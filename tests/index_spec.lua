local helpers = require("tests.helpers")
local config = require("logsvim.config")
local index = require("logsvim.index")

describe("index._parse_names", function()
  it("extracts unique page names from ripgrep's raw match lines", function()
    local stdout = "[[Neovim]]\n[[Project]]\n[[Neovim]]\n"
    local names = index._parse_names(stdout, {})
    assert.are.same({ "Neovim", "Project" }, names)
  end)

  it("merges in pages/*.md filenames, stripping the extension", function()
    local names = index._parse_names("[[Neovim]]\n", { "Neovim.md", "Untouched.md" })
    assert.are.same({ "Neovim", "Untouched" }, names)
  end)

  it("returns an empty list for empty input", function()
    assert.are.same({}, index._parse_names("", {}))
  end)

  it("ignores blank lines", function()
    local names = index._parse_names("[[A]]\n\n[[B]]\n", {})
    assert.are.same({ "A", "B" }, names)
  end)
end)

describe("index.known_roots", function()
  local cache_dir

  before_each(function()
    cache_dir = vim.fn.tempname()
    config.setup({ cache_dir = cache_dir })
  end)

  after_each(function()
    helpers.rmtree(cache_dir)
  end)

  it("returns an empty list when the cache dir doesn't exist yet", function()
    assert.are.same({}, index.known_roots())
  end)

  it("recovers root paths from cache filenames, unescaping the slug", function()
    vim.fn.mkdir(cache_dir, "p")
    vim.fn.writefile({ "[]" }, cache_dir .. "/%home%alice%graph.json")
    vim.fn.writefile({ "[]" }, cache_dir .. "/%home%bob%notes.json")
    vim.fn.writefile({ "ignored" }, cache_dir .. "/not-a-cache-file.txt")

    assert.are.same({ "/home/alice/graph", "/home/bob/notes" }, index.known_roots())
  end)
end)
