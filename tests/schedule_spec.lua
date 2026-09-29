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

  it("includes a SCHEDULED journal block that's overdue and not done", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.equal("2026_07_01", groups[1].name)
    assert.are.same({ "- TODO Ship v2", "  SCHEDULED: <2026-08-01 Sat>" }, groups[1].lines)
  end)

  it("includes a block scheduled for exactly today", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-05 Wed>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("excludes a block scheduled for a future date", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-10 Mon>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("excludes a DONE block even if overdue", function()
    write_file(root .. "/journals/2026_07_01.md", "- DONE Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("excludes a CANCELED block even if overdue", function()
    write_file(root .. "/journals/2026_07_01.md", "- CANCELED Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.equal(0, #schedule.due(root, NOW))
  end)

  it("includes overdue blocks with no task marker at all", function()
    write_file(root .. "/journals/2026_07_01.md", "- Renew passport\n  DEADLINE: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("includes DEADLINE the same way as SCHEDULED", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO File taxes\n  DEADLINE: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("is due if either SCHEDULED or DEADLINE is overdue when a block has both", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-20 Thu>\n  DEADLINE: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("does not misread prose starting with a marker-like word plus hyphen as an actual marker", function()
    write_file(root .. "/journals/2026_07_01.md", "- DONE-ish workaround for now\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.equal(1, #schedule.due(root, NOW))
  end)

  it("finds overdue blocks below other content in a journal file", function()
    write_file(root .. "/journals/2026_07_31.md", "- [[Plugin Ideas]]\n  - logsvim: journal quick-add\n\n- TODO Review PR\n  SCHEDULED: <2026-08-01 Sat>\n")
    local groups = schedule.due(root, NOW)
    assert.are.equal(1, #groups)
    assert.are.equal("2026_07_31", groups[1].name)
    assert.are.same({ "- TODO Review PR", "  SCHEDULED: <2026-08-01 Sat>" }, groups[1].lines)
  end)

  it("orders groups oldest-due first", function()
    write_file(root .. "/journals/2026_07_02.md", "- TODO Newer\n  SCHEDULED: <2026-08-04 Tue>\n")
    write_file(root .. "/journals/2026_07_03.md", "- TODO Older\n  SCHEDULED: <2026-07-20 Mon>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(2, #groups)
    assert.are.equal("2026_07_03", groups[1].name)
    assert.are.equal("2026_07_02", groups[2].name)
  end)

  it("ignores tasks in pages, which are plain Markdown documents", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.same({}, schedule.due(root, NOW))
  end)

  it("defaults `now` to the real current time when not given", function()
    -- No fixture in the graph is scheduled anywhere near the real clock, so
    -- this should simply run without error and find nothing.
    assert.are.same({}, schedule.due(root))
  end)

  it("groups sibling tasks under their shared ancestor instead of repeating it", function()
    write_file(
      root .. "/journals/2026_07_01.md",
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
      root .. "/journals/2026_07_01.md",
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
      root .. "/journals/2026_07_01.md",
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
    write_file(root .. "/journals/2026_07_01.md", "- DONE Old plan\n\t- TODO Ship v2\n\t  SCHEDULED: <2026-07-20 Mon>\n")

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
      root .. "/journals/2026_07_09.md",
      "- TODO Parent task\n  SCHEDULED: <2026-07-15 Wed>\n\t- TODO Child task\n\t  SCHEDULED: <2026-07-05 Sun>\n"
    )
    write_file(root .. "/journals/2026_07_04.md", "- TODO Simple\n  SCHEDULED: <2026-07-10 Fri>\n")

    local groups = schedule.due(root, NOW)
    assert.are.equal(2, #groups)
    assert.are.equal("2026_07_09", groups[1].name)
    assert.are.equal("2026_07_04", groups[2].name)
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

  it("finds every journal block carrying the given marker", function()
    write_file(root .. "/journals/2026_07_01.md", "- LATER Ship v2\n")
    write_file(root .. "/journals/2026_07_31.md", "- LATER Review PR\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(2, #groups)
    assert.are.equal("2026_07_01", groups[1].name)
    assert.are.same({ "- LATER Ship v2" }, groups[1].lines)
    assert.are.equal("2026_07_31", groups[2].name)
    assert.are.same({ "- LATER Review PR" }, groups[2].lines)
  end)

  it("ignores task markers in pages", function()
    write_file(root .. "/pages/Project.md", "- LATER Ship v2\n")
    assert.are.same({}, schedule.by_marker(root, "LATER"))
  end)

  it("only matches the exact marker, not other statuses", function()
    write_file(root .. "/journals/2026_07_01.md", "- NOW Ship v2\n- LATER Write docs\n- DONE Old task\n")
    assert.are.equal(1, #schedule.by_marker(root, "NOW"))
    assert.are.equal(1, #schedule.by_marker(root, "LATER"))
    assert.are.equal(1, #schedule.by_marker(root, "DONE"))
    assert.are.equal(0, #schedule.by_marker(root, "WAITING"))
  end)

  it("does not date-filter -- DONE finds every completed block regardless of when", function()
    write_file(root .. "/journals/2026_07_01.md", "- DONE Ancient task\n  SCHEDULED: <2020-01-01 Wed>\n")
    assert.are.equal(1, #schedule.by_marker(root, "DONE"))
  end)

  it("groups siblings sharing a marker under their shared ancestor", function()
    write_file(root .. "/journals/2026_07_01.md", "- Milestones\n\t- LATER Ship v2\n\t- LATER Write docs\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(1, #groups)
    assert.are.same({ "- Milestones", "\t- LATER Ship v2", "\t- LATER Write docs" }, groups[1].lines)
  end)

  it("sorts groups by source name", function()
    write_file(root .. "/journals/2026_07_09.md", "- LATER Z task\n")
    write_file(root .. "/journals/2026_07_08.md", "- LATER A task\n")

    local groups = schedule.by_marker(root, "LATER")
    assert.are.equal(2, #groups)
    assert.are.equal("2026_07_08", groups[1].name)
    assert.are.equal("2026_07_09", groups[2].name)
  end)

  it("returns an empty list for a status with no matches", function()
    assert.are.same({}, schedule.by_marker(root, "WAITING"))
  end)

  it("does not match a marker-like prefix that's part of a longer word", function()
    write_file(root .. "/journals/2026_07_01.md", "- DONE-ish task\n")
    assert.are.equal(0, #schedule.by_marker(root, "DONE"))
  end)

  it("doesn't treat other leading uppercase words as markers", function()
    write_file(root .. "/journals/2026_07_01.md", "- API design notes\n")
    assert.are.same({}, schedule.presence(root, NOW))
  end)
end)

describe("schedule.presence", function()
  local root

  before_each(function()
    root = helpers.temp_graph()
    config.setup({ root = root })
  end)

  after_each(function()
    helpers.rmtree(root)
  end)

  it("agrees with schedule.due/by_marker about which pseudo-pages have something to show", function()
    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n- LATER Someday\n")

    local present = schedule.presence(root, NOW)
    assert.is_true(present.Scheduled)
    assert.is_true(present.TODO)
    assert.is_true(present.LATER)
    assert.is_falsy(present.DOING)
    assert.is_falsy(present.DONE)
  end)

  it("excludes Scheduled when the only SCHEDULED block is done or not yet due", function()
    write_file(root .. "/journals/2026_07_01.md", "- DONE Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.is_falsy(schedule.presence(root, NOW).Scheduled)

    write_file(root .. "/journals/2026_07_01.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-10 Mon>\n")
    assert.is_falsy(schedule.presence(root, NOW).Scheduled)
  end)

  it("ignores scheduled and marked blocks in pages", function()
    write_file(root .. "/pages/Project.md", "- TODO Ship v2\n  SCHEDULED: <2026-08-01 Sat>\n")
    assert.are.same({}, schedule.presence(root, NOW))
  end)

  it("returns an empty table for a graph with no scheduled or marked blocks", function()
    assert.are.same({}, schedule.presence(root, NOW))
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
