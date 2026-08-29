local config = require("logsvim.config")

local M = {}

function M.root()
  return config.options.root
end

-- Whether `dir` looks like a graph root: does it have a journals/ or pages/
-- subdirectory?
function M.looks_like_root(dir)
  return vim.fn.isdirectory(dir .. "/" .. config.options.journal_dir) == 1
    or vim.fn.isdirectory(dir .. "/" .. config.options.pages_dir) == 1
end

-- resolve_root() found (and possibly asked the user to pick) a root for the
-- session; memoized so later calls don't redo the filesystem checks or
-- re-prompt.
local resolved_root

-- Find the graph root to use, calling `callback(root)` once resolved (nil if
-- none could be found). Tries, in order: an explicit setup({ root = ... }),
-- $LOGSVIM_ROOT, the cwd, the cwd's parent, and finally the set of graphs
-- with a cached index (letting the user pick if there's more than one).
-- Notifies an error if nothing works.
function M.resolve_root(callback)
  if resolved_root then
    callback(resolved_root)
    return
  end

  local function use(root)
    resolved_root = root
    config.options.root = root
    callback(root)
  end

  if config.explicit_root then
    use(config.options.root)
    return
  end

  if vim.env.LOGSVIM_ROOT then
    use(vim.env.LOGSVIM_ROOT)
    return
  end

  local cwd = vim.fn.getcwd()
  if M.looks_like_root(cwd) then
    use(cwd)
    return
  end

  local parent = vim.fn.fnamemodify(cwd, ":h")
  if parent ~= cwd and M.looks_like_root(parent) then
    use(parent)
    return
  end

  local candidates = require("logsvim.index").known_roots()
  if #candidates == 0 then
    vim.notify("logsvim: No graphs found", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  if #candidates == 1 then
    use(candidates[1])
    return
  end

  vim.ui.select(candidates, { prompt = "logsvim: select a graph" }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    use(choice)
  end)
end

function M.journal_dir(root)
  return (root or M.root()) .. "/" .. config.options.journal_dir
end

function M.pages_dir(root)
  return (root or M.root()) .. "/" .. config.options.pages_dir
end

function M.date_to_filename(date)
  return os.date(config.options.date_format, date) .. ".md"
end

-- Strip the .md extension for display (journal buffer headings, quickfix titles).
function M.filename_display(filename)
  return (filename:gsub("%.md$", ""))
end

function M.journal_path(root, date)
  return M.journal_dir(root) .. "/" .. M.date_to_filename(date or os.time())
end

-- Create today's (or `date`'s) journal file and parent dir if it doesn't
-- exist yet, without writing any content. Returns the path either way.
function M.ensure_journal_file(root, date)
  local path = M.journal_path(root, date)
  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = io.open(path, "w")
    if f then
      f:close()
    end
  end
  return path
end

-- Literal whitespace for one nesting level, matching Logseq's
-- :export/bullet-indentation config.edn values.
local SUB_INDENT = {
  ["two-spaces"] = string.rep(" ", 2),
  ["four-spaces"] = string.rep(" ", 4),
  ["eight-spaces"] = string.rep(" ", 8),
}

function M.sub_indent_for(indentation)
  return SUB_INDENT[indentation] or "\t" -- tab is Logseq's default
end

-- A line starting with "-" (after leading whitespace) would otherwise be
-- misread as a new sibling bullet by Logseq's own outliner parser,
-- regardless of indent depth.
local function guard_leading_dash(line)
  local trimmed = (line:gsub("^[ \t]+", ""))
  if trimmed:sub(1, 1) == "-" then
    return line:sub(1, #line - #trimmed) .. "\\" .. trimmed
  end
  return line
end

-- Build a journal block for a topic + free-text contents + optional asset
-- names: "- [[Topic]]" header, then contents as one sub-bullet (its first
-- line gets the "- " marker; further non-blank lines are continuation prose
-- indented to align under it; blank lines stay blank), then one "- ![]()"
-- bullet per asset.
function M.build_journal_block(topic, contents, assets)
  local sub_indent = M.sub_indent_for(config.options.indentation)
  local cont_indent = sub_indent .. "  " -- +2 spaces for the "- " marker width

  local lines = { "- [[" .. topic .. "]]" }

  if contents and contents ~= "" then
    for i, line in ipairs(vim.split(contents, "\n", { plain = true })) do
      if i == 1 then
        table.insert(lines, sub_indent .. "- " .. guard_leading_dash(line))
      elseif line == "" then
        table.insert(lines, "")
      else
        table.insert(lines, cont_indent .. guard_leading_dash(line))
      end
    end
  end

  for _, name in ipairs(assets or {}) do
    table.insert(lines, sub_indent .. "- ![" .. name .. "](../" .. config.options.assets_dir .. "/" .. name .. ")")
  end

  return lines
end

function M.read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  return lines
end

-- Append a block to `path`, creating the file (and parent dir) if absent.
-- Blank-line separator when the file already has content.
function M.append_block(path, block_lines)
  local out = M.read_lines(path)

  vim.fn.mkdir(vim.fs.dirname(path), "p")

  if #out > 0 then
    table.insert(out, "")
  end
  for _, line in ipairs(block_lines) do
    table.insert(out, line)
  end

  local f, err = io.open(path, "w")
  if not f then
    error("logsvim: failed to write " .. path .. ": " .. tostring(err))
  end
  f:write(table.concat(out, "\n") .. "\n")
  f:close()
end

-- Every "*.md" filename directly inside `dir` (not recursive), sorted.
function M.list_md_files(dir)
  local files = {}
  local ok, entries = pcall(vim.fn.readdir, dir)
  if ok and entries then
    for _, fname in ipairs(entries) do
      if fname:match("%.md$") then
        table.insert(files, fname)
      end
    end
  end
  table.sort(files)
  return files
end

-- Every journal filename for `root`, newest-first. "YYYY_MM_DD.md" sorts
-- chronologically as a plain string, so descending string order works.
function M.list_journal_files(root)
  local files = M.list_md_files(M.journal_dir(root))
  table.sort(files, function(a, b)
    return a > b
  end)
  return files
end

-- Rewrite every "[[old_name]]" occurrence on `line` to "[[new_name]]",
-- leaving other links untouched. Uses a match callback rather than a
-- pattern-string replacement so neither name needs Lua-pattern escaping.
local function replace_links_in_line(line, old_name, new_name)
  local changed = false
  local result = line:gsub("%[%[([^%[%]]+)%]%]", function(name)
    if name == old_name then
      changed = true
      return "[[" .. new_name .. "]]"
    end
    return "[[" .. name .. "]]"
  end)
  return result, changed
end

-- Rename a page: rewrite every "[[old_name]]" reference to "[[new_name]]"
-- across every journal and page file, then rename pages/<old_name>.md to
-- pages/<new_name>.md if it exists (a page referenced only via [[links]],
-- with no file of its own, has nothing to rename on disk). Returns the
-- number of files whose content was rewritten, or nil + an error message if
-- the rename can't proceed.
function M.rename_page(root, old_name, new_name)
  if not new_name or new_name == "" or new_name == old_name then
    return nil, "logsvim: invalid new page name"
  end

  local old_path = M.pages_dir(root) .. "/" .. old_name .. ".md"
  local new_path = M.pages_dir(root) .. "/" .. new_name .. ".md"
  if vim.fn.filereadable(new_path) == 1 then
    return nil, "logsvim: a page named " .. new_name .. " already exists"
  end

  local updated = 0
  for _, dir in ipairs({ M.journal_dir(root), M.pages_dir(root) }) do
    for _, fname in ipairs(M.list_md_files(dir)) do
      local path = dir .. "/" .. fname
      local lines = M.read_lines(path)
      local file_changed = false
      for i, line in ipairs(lines) do
        local new_line, changed = replace_links_in_line(line, old_name, new_name)
        if changed then
          lines[i] = new_line
          file_changed = true
        end
      end
      if file_changed then
        local f, err = io.open(path, "w")
        if not f then
          error("logsvim: failed to write " .. path .. ": " .. tostring(err))
        end
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        updated = updated + 1
      end
    end
  end

  if vim.fn.filereadable(old_path) == 1 then
    vim.fn.rename(old_path, new_path)
  end

  return updated
end

-- Internal accessor for the test suite only; not part of the public API.
M._test = {
  reset_resolved_root = function()
    resolved_root = nil
  end,
}

return M
