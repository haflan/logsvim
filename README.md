# logsvim

A small Neovim plugin for editing a [Logseq](https://logseq.com)-format graph
directly on disk — daily journals with block-based bullet editing,
`[[Page]]` links, and pages as plain Markdown documents — without running
Logseq itself.

> [!WARNING]
> This project is heavily vibe-coded: it was built almost entirely with an AI
> coding assistant, for personal use, to cover the small slice of Logseq's
> features its author actually relies on day to day. It has not been
> extensively reviewed line-by-line, is not a full Logseq replacement (there's
> no query language, no block properties, no task clocking, and more — see
> "What this isn't" below), and comes with no warranty. Read the code before
> trusting it with data you care about.

## Features

- `:LogsvimJournal` — a single scrollable, editable buffer over all of your
  daily journal files, newest first, lazy-loaded as you scroll. Saving only
  rewrites the days you actually changed.
- `:LogsvimPage <name>` — a view of a page: its own editable content (if
  any), followed by every journal block that references `[[name]]`, grouped
  by date (Logseq's "linked references", read-only). A page is a plain
  Markdown document (headings, paragraphs, lists, code, tables; no bullets
  required) and is edited like any other Markdown file. Outline-style pages
  still work: they're just a Markdown list.
- Logseq-style bullet editing in journals: insert-mode `<CR>` and
  normal-mode `o`/`O` always start a fresh `- ` bullet at the anchor line's
  indentation, and `<Tab>`/`<S-Tab>` in insert mode indent/dedent the
  current line.
- Task cycling in journals: `<C-CR>` (normal or insert mode, configurable via
  `keymaps.cycle_task`) cycles the current block's marker like Logseq's
  Ctrl+Enter: `LATER` → `NOW` → `DONE` → none, or `TODO` → `DOING` → `DONE`
  → none with `workflow = "todo"`. Needs a terminal that sends `<C-CR>` as
  its own key (kitty, WezTerm, Ghostty, foot, or tmux with `extended-keys`);
  otherwise map it to something else.
- `gd` and normal-mode `<CR>` (configurable, see `keymaps.goto_reference`)
  follow whatever's under the cursor, in either direction: a `[[Page]]` link
  opens that page, and failing that, in a page's linked references, the
  nearest date heading jumps to that day in the journal.
- `[[Page]]` link completion via [nvim-cmp](https://github.com/hrsh7th/nvim-cmp),
  backed by an index of every page name mentioned anywhere in the graph,
  including in a page's `tags::`/`alias::` properties (kept up to date
  automatically on save).
- Page renaming (`<leader>rn` on a `[[Page]]` link, configurable via
  `keymaps.rename`, in the journal or in a page's linked references):
  rewrites every `[[old]]` reference across journals and pages, and renames
  the page's own file (and its `title::` property) if it has one. Not yet
  supported from within the page's own buffer.
- Safe alongside other editors of the same graph (Logseq, a web editor, `git
  pull`, another Neovim): every save checks that the file on disk is still
  the version you started from. If it changed, the two edits are three-way
  merged with `git merge-file`. If they conflict, that file isn't written and
  your edits stay in the buffer; `:w!` overwrites, and `:LogsvimReload!`
  discards your edits. Files are written atomically (temp file + rename).
  Open journal/page buffers pick up outside changes when you enter them or
  when Neovim regains focus.
- Matches Logseq's own file/config.edn conventions (journal filename format,
  bullet indentation styles) so files stay interoperable with Logseq itself.

## What this isn't

Deliberately out of scope, or just not built yet:

- The query language (`{{query ...}}`, advanced queries).
- An outliner for pages: pages are plain Markdown, so bullets, task markers
  and task cycling are journal-only (a `TODO` in a page is just text, not a
  task).
- Tags (`#tag`), block properties, block references/embeds. Of page
  properties (the `key:: value` lines at the very top of a page), only
  `tags::`/`alias::` (fed into completion) and `title::` (kept in sync on
  rename) are used; a page is still found by its file name, not its
  `title::`. Task markers are only cycled and listed, not clocked (no
  `:LOGBOOK:`).
- Deleting pages, or renaming a page from within its own buffer.
- Graph view, whiteboards, flashcards, or a plugin/marketplace API.

## Requirements

- Neovim 0.10+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) on your `$PATH` —
  used to build the `[[Page]]` link index
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) (optional) for `[[Page]]`
  completion

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'haflan/logsvim',
  config = function()
    require('logsvim').setup {}
  end,
}
```

## Configuration

Defaults, passed to `setup()`:

```lua
require('logsvim').setup {
  -- Graph root containing journals/, pages/, assets/. Auto-detected from
  -- cwd (or its parent) if not given; see graph.resolve_root().
  root = vim.fn.getcwd(),
  -- One of "tab" (default), "two-spaces", "four-spaces", "eight-spaces" —
  -- matches Logseq's :export/bullet-indentation config.edn values.
  indentation = "tab",
  -- Task cycling order for keymaps.cycle_task: "now" (LATER -> NOW -> DONE,
  -- Logseq's default :preferred-workflow) or "todo" (TODO -> DOING -> DONE).
  workflow = "now",
  journal_dir = "journals",
  pages_dir = "pages",
  assets_dir = "assets",
  -- Matches Logseq's default :journal/file-name-format.
  date_format = "%Y_%m_%d",
  -- Number of journal files loaded per batch in :LogsvimJournal.
  journal_batch_size = 14,
  -- Where the [[Page]] link index (used for completion) is cached on disk.
  cache_dir = "~/.cache/logsvim",
  -- Normal-mode keymaps set in journal/page buffers. Each value is a key or
  -- list of keys, or false to leave that action unbound.
  keymaps = {
    goto_reference = { "gd", "<CR>" },
    rename = "<leader>rn",
    cycle_task = "<C-CR>", -- normal and insert mode
  },
}
```

`$LOGSVIM_ROOT` overrides graph discovery if set.

## Commands

| Command           | Description                                          |
|-------------------|-------------------------------------------------------|
| `:LogsvimJournal` | Open the scrollable, editable journal buffer          |
| `:LogsvimPage {name}` | Show a page's contents and its journal backlinks  |
| `:LogsvimReindex` | Rebuild the `[[Page]]` link completion index          |
| `:LogsvimReload[!]` | Pick up changes made on disk in the journal/page buffer (or all of them); `!` also discards your unsaved edits |

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted-style runner:

```sh
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

`tests/minimal_init.lua` looks for plenary at `$PLENARY_PATH` or
`~/.local/share/nvim/lazy/plenary.nvim`.

## License

MIT — see [LICENSE](LICENSE).
