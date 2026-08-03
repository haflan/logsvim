local M = {}

local fixture_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/test-graph"

-- Copy the fixture graph into a fresh temp directory so tests can freely
-- mutate files without touching the checked-in fixtures.
function M.temp_graph()
  local dst = vim.fn.tempname()
  vim.fn.mkdir(dst, "p")
  vim.fn.system({ "cp", "-r", fixture_root .. "/.", dst })
  -- graph.resolve_root() memoizes its result for the whole process; without
  -- this, whichever root the first test resolved would stick for every
  -- later test that calls journal.open()/pages.open() with no explicit root.
  require("logsvim.graph")._test.reset_resolved_root()
  return dst
end

function M.rmtree(path)
  vim.fn.system({ "rm", "-rf", path })
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

return M
