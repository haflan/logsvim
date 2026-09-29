local config = require("logsvim.config")
local graph = require("logsvim.graph")

local M = {}

-- root -> list of known [[Page Name]] names (in-memory, refreshed async).
local mem = {}

local function cache_dir()
  return vim.fn.expand(config.options.cache_dir)
end

local function cache_file(root)
  local slug = root:gsub("[/\\]", "%%")
  return cache_dir() .. "/" .. slug .. ".json"
end

local function read_cache(root)
  local f = io.open(cache_file(root), "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function write_cache(root, names)
  -- Best-effort: a failed cache write only costs a slower next startup.
  pcall(graph.write_lines_atomic, cache_file(root), { vim.json.encode(names) })
end

-- Merge ripgrep's raw "[[Name]]" match lines with existing pages/*.md
-- filenames and page names from `tags::`/`alias::` properties into a
-- sorted, deduplicated list of page names. Pure/testable: takes no io
-- beyond its arguments.
function M._parse_names(rg_stdout, page_filenames, property_names)
  local seen = {}
  for _, line in ipairs(vim.split(rg_stdout or "", "\n", { trimempty = true })) do
    local name = line:match("^%[%[(.+)%]%]$")
    if name then
      seen[name] = true
    end
  end
  for _, fname in ipairs(page_filenames or {}) do
    seen[(fname:gsub("%.md$", ""))] = true
  end
  for _, name in ipairs(property_names or {}) do
    seen[name] = true
  end

  local names = {}
  for name in pairs(seen) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

local function page_filenames(root)
  local ok, entries = pcall(vim.fn.readdir, graph.pages_dir(root))
  if not ok or not entries then
    return {}
  end
  local files = {}
  for _, fname in ipairs(entries) do
    if fname:match("%.md$") then
      table.insert(files, fname)
    end
  end
  return files
end

-- Page names referenced from pages' leading tags::/alias:: properties (see
-- graph.property_page_names), which count as references just like [[Name]].
local function property_names(root)
  local names = {}
  for _, fname in ipairs(page_filenames(root)) do
    vim.list_extend(names, graph.property_page_names(graph.read_lines(graph.pages_dir(root) .. "/" .. fname)))
  end
  return names
end

-- Names currently known for `root` (may be empty until the first refresh
-- completes). Non-blocking.
function M.names(root)
  return mem[root or graph.root()] or {}
end

-- Root paths for every graph that has ever been indexed, recovered from the
-- cache filenames written by write_cache() (path separators escaped as
-- "%"). Used to offer known graphs when cwd doesn't look like one.
function M.known_roots()
  local roots = {}
  local ok, entries = pcall(vim.fn.readdir, cache_dir())
  if ok and entries then
    for _, fname in ipairs(entries) do
      local slug = fname:match("^(.+)%.json$")
      if slug then
        table.insert(roots, (slug:gsub("%%", "/")))
      end
    end
  end
  table.sort(roots)
  return roots
end

-- Kick off an async rg scan of journal_dir + pages_dir for "[[Name]]"
-- references, merge with pages/*.md filenames and tags::/alias:: names, update the in-memory table
-- and disk cache, and invoke `on_done(names)` (if given) once finished.
function M.refresh(root, on_done)
  root = root or graph.root()

  local dirs = { graph.journal_dir(root), graph.pages_dir(root) }
  local args = { "rg", "--no-filename", "--only-matching", "--no-line-number", [=[\[\[[^\[\]]+\]\]]=] }
  for _, d in ipairs(dirs) do
    if vim.fn.isdirectory(d) == 1 then
      table.insert(args, d)
    end
  end

  vim.system(args, { text = true }, function(result)
    -- exit code 1 from ripgrep means "no matches", not a failure
    local stdout = (result.code == 0 or result.code == 1) and result.stdout or ""

    vim.schedule(function()
      local names = M._parse_names(stdout, page_filenames(root), property_names(root))
      mem[root] = names
      write_cache(root, names)
      if on_done then
        on_done(names)
      end
    end)
  end)
end

-- Load the on-disk cache synchronously (if any) so completion has something
-- to serve immediately, then kick off an async refresh to catch up.
function M.ensure_loaded(root)
  root = root or graph.root()
  if mem[root] then
    return
  end
  mem[root] = read_cache(root) or {}
  M.refresh(root)
end

return M
