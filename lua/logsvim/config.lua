local M = {}

M.defaults = {
  -- Graph root containing journals/, pages/, assets/.
  root = vim.fn.getcwd(),
  -- One of "tab" (default), "two-spaces", "four-spaces", "eight-spaces" —
  -- matches Logseq's :export/bullet-indentation config.edn values exactly.
  indentation = "tab",
  journal_dir = "journals",
  pages_dir = "pages",
  assets_dir = "assets",
  -- Go's "2006_01_02" in Lua's os.date format.
  date_format = "%Y_%m_%d",
  -- Number of journal files loaded per batch in :LogsvimJournal.
  journal_batch_size = 14,
  -- Where the [[Page]] link index (used for completion) is cached on disk.
  cache_dir = "~/.cache/logsvim",
}

M.options = vim.deepcopy(M.defaults)

-- Whether `root` was explicitly passed to the most recent setup() call, as
-- opposed to falling back to defaults.root's cwd snapshot. graph.resolve_root()
-- trusts an explicit root outright, skipping cwd/parent/cache discovery.
M.explicit_root = false

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M.explicit_root = opts ~= nil and opts.root ~= nil
end

return M
