local config = require("logsvim.config")
local graph = require("logsvim.graph")

local M = {}

local function leading_indent(line)
  return line:match("^[ \t]*") or ""
end

-- The text a new line should start with, given the line it's anchored below
-- (or above): that line's indentation, always followed by a fresh "- ".
function M.bullet_for(anchor_line)
  return leading_indent(anchor_line) .. "- "
end

-- Split the current line at the cursor into two, with the new second line
-- starting with a fresh bullet anchored to the (pre-split) line's
-- indentation. Done via the buffer API rather than simulating a <CR>
-- keypress, so it's immune to 'autoindent'/'smartindent' copying the same
-- indentation a second time on top of it.
local function split_line_with_bullet()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before, after = line:sub(1, col), line:sub(col + 1)
  local bullet = M.bullet_for(line)

  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { before, bullet .. after })
  vim.api.nvim_win_set_cursor(0, { row + 1, #bullet })
end

local function insert_bullet_line(before)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local anchor = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  local text = M.bullet_for(anchor)
  local at = before and (lnum - 1) or lnum
  vim.api.nvim_buf_set_lines(0, at, at, false, { text })
  vim.api.nvim_win_set_cursor(0, { at + 1, #text })
  vim.cmd("startinsert!")
end

-- One shiftwidth/tabstop/softtabstop per space-based indentation option;
-- "tab" (the default) isn't in here and falls through to noexpandtab below.
local SPACE_WIDTHS = { ["two-spaces"] = 2, ["four-spaces"] = 4, ["eight-spaces"] = 8 }

-- Buffer-local indent settings matching config.options.indentation, so
-- <Tab>/<< />> produce the same whitespace graph.sub_indent_for() would
-- write for a new bullet (one literal tab per level by default) regardless
-- of the user's own global 'expandtab'/'shiftwidth'.
function M.apply_indent_settings(bufnr)
  local width = SPACE_WIDTHS[config.options.indentation]
  if width then
    vim.bo[bufnr].expandtab = true
    vim.bo[bufnr].shiftwidth = width
    vim.bo[bufnr].tabstop = width
    vim.bo[bufnr].softtabstop = width
  else
    vim.bo[bufnr].expandtab = false
    vim.bo[bufnr].shiftwidth = 8
    vim.bo[bufnr].tabstop = 8
    vim.bo[bufnr].softtabstop = 0
  end
end

-- Add/remove one indentation unit (config.options.indentation's tab or N
-- spaces) at the start of the current line, keeping the cursor at the same
-- offset from the bullet text rather than letting it jump to the line's
-- first non-blank character the way a plain "<C-o>>>"/"<C-o><<" would.
-- Dedenting is a no-op if the line doesn't start with a full unit already.
local function shift_line(indent)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local unit = graph.sub_indent_for(config.options.indentation)

  local new_line, delta
  if indent then
    new_line, delta = unit .. line, #unit
  elseif line:sub(1, #unit) == unit then
    new_line, delta = line:sub(#unit + 1), -#unit
  else
    new_line, delta = line, 0
  end

  vim.api.nvim_set_current_line(new_line)
  vim.api.nvim_win_set_cursor(0, { row, math.max(0, math.min(col + delta, #new_line)) })
end

-- Buffer-local editing behavior:
-- - <CR> in insert mode, and o/O in normal mode, always start the new line
--   with the anchor line's indentation plus "- " (no attempt to
--   detect/continue existing bullets or prose).
-- - <Tab>/<S-Tab> in insert mode indent/dedent the current line, Logseq-
--   style, rather than inserting a character at the cursor.
-- - shiftwidth/tabstop/expandtab are set to match config.options.indentation,
--   so manual indenting (<<, >>) agrees with what new bullets get.
function M.attach(bufnr)
  M.apply_indent_settings(bufnr)

  vim.keymap.set("i", "<CR>", split_line_with_bullet, { buffer = bufnr, desc = "logsvim: new bulleted line" })
  vim.keymap.set("n", "o", function()
    insert_bullet_line(false)
  end, { buffer = bufnr, desc = "logsvim: new bulleted line below" })
  vim.keymap.set("n", "O", function()
    insert_bullet_line(true)
  end, { buffer = bufnr, desc = "logsvim: new bulleted line above" })

  vim.keymap.set("i", "<Tab>", function()
    shift_line(true)
  end, { buffer = bufnr, desc = "logsvim: indent line" })
  vim.keymap.set("i", "<S-Tab>", function()
    shift_line(false)
  end, { buffer = bufnr, desc = "logsvim: dedent line" })
end

M._test = { bullet_for = M.bullet_for, apply_indent_settings = M.apply_indent_settings, shift_line = shift_line }

return M
