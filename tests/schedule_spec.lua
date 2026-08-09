local helpers = require("tests.helpers")
local config = require("logsvim.config")
local schedule = require("logsvim.schedule")

local function write_file(path, content)
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

-- Fixed "now" for deterministic tests, independent of the real clock.
local NOW = os.time({ year = 2026, month = 8, day = 5, hour = 12 })

describe("schedule.due", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("includes a SCHEDULED block from a page that's overdue and not done", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.equal("Project", groups[1].name)
    assert.are.equal("page", groups[1].kind)
    assert.are.same({ "- TODO Ship v2", "  SCHEDULED: <2026-08-01 Sat>" }, groups[1].lines)
  end)

  it("includes a block scheduled for exactly today", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-05 Wed>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("excludes a block scheduled for a future date", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-10 Mon>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("excludes a DONE block even if overdue", function()
    write_file(root .. "/pages/Project.md", "- DONE Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("excludes a CANCELED block even if overdue", function()
    write_file(root .. "/pages/Project.md", "- CANCELED Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("includes overdue blocks with no task marker at all", function()
    write_file(root .. "/pages/Project.md", "- Renew passport\n  DEADLINE: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("includes DEADLINE the same way as SCHEDULED", function()
    write_file(root .. "/pages/Project.md", "- TODO File taxes\n  DEADLINE: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("finds overdue blocks written directly in a journal file, not just pages, tagged with kind = journal", function()
    write_file(root .. "/journals/2026_07_31.md", "- [[Plugin Ideas]]\n  - logsvim: journal quick-add\n\n- TODO Review PR\n  SCHEDULED: <2026-08-01 Sat>\n")
    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.equal("2026_07_31", groups[1].name)
    assert.are.equal("journal", groups[1].kind)
    assert.are.same({ "- TODO Review PR", "  SCHEDULED: <2026-08-01 Sat>" }, groups[1].lines)
  end)

  it("orders groups oldest-due first", function()
    write_file(root .. "/pages/A.md", "- TODO Newer\n  SCHEDULED: <2026-08-04 Tue>\n")
    write_file(root .. "/pages/B.md", "- TODO Older\n  SCHEDULED: <2026-07-20 Mon>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(2, #groups)
    assert.are.equal("B", groups[1].name)
    assert.are.equal("A", groups[2].name)
  end)

  it("defaults `now` to the real current time when not given", function()
    -- No fixture in the graph is scheduled anywhere near the real clock, so
    -- this should simply run without error and find nothing.
    assert.are.same({}, schedule.due(root))
  end)

  it("groups sibling tasks under their shared ancestor instead of repeating it", function()
    write_file(
      root .. "/pages/Project.md",
      "- Milestones\n\t- TODO Ship v2\n\t  SCHEDULED: <2026-07-20 Mon>\n\t- TODO Write docs\n\t  SCHEDULED: <2026-07-25 Fri>\n"
    )

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.same({
      "- Milestones",
      "\t- TODO Ship v2",
      "\t  SCHEDULED: <2026-07-20 Mon>",
      "\t- TODO Write docs",
      "\t  SCHEDULED: <2026-07-25 Fri>",
    }, groups[1].lines)

    local _, count = table.concat(groups[1].lines, "\n"):gsub("%- Milestones", "")
    assert.are.equal(1, count)
  end)

  it("corrects indentation to match ancestor depth instead of copying the source's raw indent", function()
    write_file(
      root .. "/pages/Notes.md",
      "- Notes\n  - Ideas\n    - TODO Investigate caching\n      SCHEDULED: <2026-07-01 Wed>\n"
    )

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.same({
      "- Notes",
      "\t- Ideas",
      "\t\t- TODO Investigate caching",
      "\t\t  SCHEDULED: <2026-07-01 Wed>",
    }, groups[1].lines)
  end)

  it("absorbs a due block nested inside another due block instead of rendering it a second time", function()
    write_file(
      root .. "/pages/Nested.md",
      "- TODO Parent task\n  SCHEDULED: <2026-07-10 Fri>\n\t- TODO Child task\n\t  SCHEDULED: <2026-07-12 Sun>\n"
    )

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.same({
      "- TODO Parent task",
      "  SCHEDULED: <2026-07-10 Fri>",
      "\t- TODO Child task",
      "\t  SCHEDULED: <2026-07-12 Sun>",
    }, groups[1].lines)

    local _, count = table.concat(groups[1].lines, "\n"):gsub("TODO Child task", "")
    assert.are.equal(1, count)
  end)

  it("keeps a DONE ancestor as plain context above a due child, without excluding the child", function()
    write_file(root .. "/pages/Old.md", "- DONE Old plan\n\t- TODO Ship v2\n\t  SCHEDULED: <2026-07-20 Mon>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.same({
      "- DONE Old plan",
      "\t- TODO Ship v2",
      "\t  SCHEDULED: <2026-07-20 Mon>",
    }, groups[1].lines)
  end)

  it("orders a group by the earliest due date among all its items, even one absorbed into another's subtree", function()
    -- The child (07-05) is earlier than its own rendering parent (07-15),
    -- but later than "Later"'s single item (07-10) -- the group's sort key
    -- must reflect the child's true date, not just what ends up rendered.
    write_file(
      root .. "/pages/Absorbed.md",
      "- TODO Parent task\n  SCHEDULED: <2026-07-15 Wed>\n\t- TODO Child task\n\t  SCHEDULED: <2026-07-05 Sun>\n"
    )
    write_file(root .. "/pages/Later.md", "- TODO Simple\n  SCHEDULED: <2026-07-10 Fri>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(2, #groups)
    assert.are.equal("Absorbed", groups[1].name)
    assert.are.equal("Later", groups[2].name)
  end)
end)

describe("schedule.by_marker", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("finds every block carrying the given marker, tagged with its source kind", function()
    write_file(root .. "/pages/Project.md", "- LATER Ship v2\n")
    write_file(root .. "/journals/2026_07_31.md", "- LATER Review PR\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(2, #groups)

    local by_name = {}
    for _, g in ipairs(groups) do
      by_name[g.name] = g
    end
    assert.are.equal("page", by_name["Project"].kind)
    assert.are.same({ "- LATER Ship v2" }, by_name["Project"].lines)
    assert.are.equal("journal", by_name["2026_07_31"].kind)
    assert.are.same({ "- LATER Review PR" }, by_name["2026_07_31"].lines)
  end)

  it("only matches the exact marker, not other statuses", function()
    write_file(root .. "/pages/Project.md", "- NOW Ship v2\n- LATER Write docs\n- DONE Old task\n")
    assert.are.equal(1, #schedule.by_marker(root, "NOW"))
    assert.are.equal(1, #schedule.by_marker(root, "LATER"))
    assert.are.equal(1, #schedule.by_marker(root, "DONE"))
    assert.are.equal(0, #schedule.by_marker(root, "WAITING"))
  end)

  it("does not date-filter -- DONE finds every completed block regardless of when", function()
    write_file(root .. "/pages/Project.md", "- DONE Ancient task\n  SCHEDULED: <2020-01-01 Wed>\n")
    assert.are.equal(1, #schedule.by_marker(root, "DONE"))
  end)

  it("groups siblings sharing a marker under their shared ancestor", function()
    write_file(root .. "/pages/Project.md", "- Milestones\n\t- LATER Ship v2\n\t- LATER Write docs\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(1, #groups)
    assert.are.same({ "- Milestones", "\t- LATER Ship v2", "\t- LATER Write docs" }, groups[1].lines)
  end)

  it("sorts groups by source name", function()
    write_file(root .. "/pages/Zebra.md", "- LATER Z task\n")
    write_file(root .. "/pages/Alpha.md", "- LATER A task\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(2, #groups)
    assert.are.equal("Alpha", groups[1].name)
    assert.are.equal("Zebra", groups[2].name)
  end)

  it("returns an empty list for a status with no matches", function()
    assert.are.same({}, schedule.by_marker(root, "WAITING"))
  end)
end)

describe("schedule.MARKERS", function()
  it("lists every Logseq task marker exactly once", function()
    local seen = {}
    for _, m in ipairs(schedule.MARKERS) do
      assert.is_nil(seen[m])
      seen[m] = true
    end
    assert.are.same({
      TODO = true,
      DOING = true,
      NOW = true,
      LATER = true,
      WAITING = true,
      ["IN-PROGRESS"] = true,
      DONE = true,
      CANCELED = true,
      CANCELLED = true,
    }, seen)
  end)
end)
