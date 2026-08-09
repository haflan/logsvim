local config = require("logsvim.config")
local outline = require("logsvim.outline")

describe("outline.ancestor_chain", function()
  it("returns empty for a top-level line", function()
    local lines = { "- A" }
    assert.are.same({}, outline._test.ancestor_chain(lines, 1))
  end)

  it("returns the full multi-level path, shallowest first", function()
    local lines = { "- A", "\t- B", "\t\t- C" }
    assert.are.same({ 1, 2 }, outline._test.ancestor_chain(lines, 3))
  end)

  it("skips blank lines while searching upward", function()
    local lines = { "- A", "", "\t- B" }
    assert.are.same({ 1 }, outline._test.ancestor_chain(lines, 3))
  end)
end)

describe("outline.collect_block", function()
  it("collects a bullet plus its more-indented descendants", function()
    local lines = { "- Milestones", "\t- TODO A", "\t  SCHEDULED: <2026-07-20 Mon>", "\t- TODO B" }
    local block, extent = outline._test.collect_block(lines, 2)
    assert.are.same({ "\t- TODO A", "\t  SCHEDULED: <2026-07-20 Mon>" }, block)
    assert.are.equal(4, extent)
  end)

  it("stops at a sibling with equal or shallower indent", function()
    local lines = { "- A", "\t- child", "- B" }
    local block, extent = outline._test.collect_block(lines, 1)
    assert.are.same({ "- A", "\t- child" }, block)
    assert.are.equal(3, extent)
  end)

  it("trims trailing blank lines but keeps internal ones", function()
    local trailing = { "- A", "\t- child1", "", "" }
    local block = outline._test.collect_block(trailing, 1)
    assert.are.same({ "- A", "\t- child1" }, block)

    local internal = { "- A", "\t- child1", "", "\t- child2" }
    local block2, extent2 = outline._test.collect_block(internal, 1)
    assert.are.same({ "- A", "\t- child1", "", "\t- child2" }, block2)
    assert.are.equal(5, extent2)
  end)
end)

describe("outline.group", function()
  before_each(function()
    config.setup({ indentation = "tab" })
  end)

  it("renders a single top-level header unchanged", function()
    local lines = { "- TODO Ship v2", "  SCHEDULED: <2026-07-20 Mon>" }
    assert.are.same(lines, outline.group(lines, { 1 }))
  end)

  it("dedupes duplicate header indices", function()
    local lines = { "- TODO Ship v2", "  SCHEDULED: <2026-07-20 Mon>" }
    assert.are.same(outline.group(lines, { 1 }), outline.group(lines, { 1, 1, 1 }))
  end)

  it("merges siblings sharing an ancestor, rendering it once", function()
    local lines = {
      "- Milestones",
      "\t- TODO Ship v2",
      "\t  SCHEDULED: <2026-07-20 Mon>",
      "\t- TODO Write docs",
      "\t  SCHEDULED: <2026-07-25 Fri>",
    }
    local result = outline.group(lines, { 2, 4 })
    assert.are.same(lines, result)

    local _, count = table.concat(result, "\n"):gsub("%- Milestones", "")
    assert.are.equal(1, count)
  end)

  it("normalizes indentation to the configured unit instead of copying the source's raw indent", function()
    local lines = {
      "- Notes",
      "  - Ideas", -- 2 spaces in source, despite indentation = tab
      "    - TODO Investigate caching", -- 4 spaces
      "      SCHEDULED: <2026-07-01 Wed>", -- 6 spaces
    }
    local result = outline.group(lines, { 3 })
    assert.are.same({
      "- Notes",
      "\t- Ideas",
      "\t\t- TODO Investigate caching",
      "\t\t  SCHEDULED: <2026-07-01 Wed>",
    }, result)
  end)

  it("absorbs a header nested inside another header's own subtree instead of duplicating it", function()
    local lines = {
      "- TODO Parent task",
      "  SCHEDULED: <2026-07-10 Fri>",
      "\t- TODO Child task",
      "\t  SCHEDULED: <2026-07-12 Sun>",
    }
    local result = outline.group(lines, { 1, 3 })
    assert.are.same(lines, result)

    local _, count = table.concat(result, "\n"):gsub("TODO Child task", "")
    assert.are.equal(1, count)
  end)

  it("blank-separates disjoint top-level roots but not a node from its children", function()
    local lines = { "- Milestones", "\t- TODO Ship v2", "- TODO Standalone" }
    local result = outline.group(lines, { 2, 3 })
    assert.are.same({
      "- Milestones",
      "\t- TODO Ship v2",
      "",
      "- TODO Standalone",
    }, result)
  end)
end)
