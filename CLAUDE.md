# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim plugin for editing a Logseq-format graph directly on disk: daily journal files, `[[Page]]` links, and block-based bullets, following the same file layout and `config.edn` conventions (e.g. `:export/bullet-indentation`, `:journal/file-name-format`) that Logseq itself uses. `lua/logsvim/graph.lua` is the layer responsible for reading/writing that format correctly.

## Commands

Run the full test suite:

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Run a single test file:

```
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/edit_spec.lua"
```

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-style runner. `tests/minimal_init.lua` looks for plenary at `$PLENARY_PATH` or `~/.local/share/nvim/lazy/plenary.nvim`; set `PLENARY_PATH` if it's installed elsewhere. There is no separate lint/build step.

## Architecture

The plugin has no persistent daemon or server — everything runs synchronously in the Neovim process except the ripgrep-backed page index, which shells out via `vim.system`.

**Module map** (`lua/logsvim/`):
- `config.lua` — defaults + `setup()`. Tracks whether `root` was passed explicitly (`explicit_root`) vs. left to fall back to cwd, which `graph.resolve_root()` uses to decide whether to trust it outright. Also owns the `keymaps` table (action name -> key/list of keys/`false`) and `set_keymap(bufnr, name, rhs, desc)`, which `journal.lua`/`pages.lua` call instead of `vim.keymap.set` directly so mappings stay user-configurable.
- `graph.lua` — the graph-format layer: resolving which directory is "the graph" (`resolve_root`, memoized per-session), path helpers (`journal_dir`, `pages_dir`, `journal_path`), and the Logseq-format functions (`build_journal_block`, `append_block`, `sub_indent_for`, `guard_leading_dash`, `rename_page`).
- `index.lua` — the `[[Page Name]]` completion index: an in-memory table per root, backed by a JSON cache under `cache_dir` (filename = root path with `/` escaped to `%`) and refreshed asynchronously via `rg` scanning journals+pages for `[[...]]` plus `pages/*.md` filenames. `known_roots()` recovers previously-indexed graphs from cache filenames, used when cwd doesn't look like a graph root.
- `journal.lua` — the scrollable, editable journal view. Implements a virtual buffer under the `logsvim-journal://<root>` scheme (`BufReadCmd`/`BufWriteCmd` autocmds), lazy-loading batches of daily files newest-first as the user scrolls (`WinScrolled` → `maybe_load_more`). Each day's region is tracked by an extmark anchored to its `# <date>` header line; on write, only files whose region actually changed get rewritten to disk, and a background `index.refresh()` runs if anything changed.
- `pages.lua` — the editable page view + read-only "linked references" section (Logseq-style backlinks) under `logsvim-page://<root>/<name>`: renders the page's own `pages/<name>.md` contents (if any, editable) followed by every journal bullet block that references `[[name]]`, grouped by date (read-only). `goto_under_cursor` (bound to both `gd` and `<CR>` in journal and page buffers) follows either direction of reference: a `[[Page]]` link under the cursor opens that page (`open_under_cursor`); failing that, in a page's linked-references view, the nearest `### <date>` heading above the cursor jumps to that date in the journal (`goto_reference`). `rename_under_cursor` (bound to `<leader>rn`, on a `[[Page]]` link) drives `graph.rename_page()` and then reloads any open journal/page buffers that would otherwise show stale text.
- `buffer.lua` — auto-attaches `edit.lua` keymaps + nvim-cmp completion to any real file under the graph's `journal_dir`/`pages_dir` (e.g. opened via quickfix or `gd`), since those don't go through `journal.lua`'s virtual buffer.
- `edit.lua` — Logseq-style bullet editing: `<CR>` always starts a new line with the anchor line's indentation + `- ` (rather than trying to detect/continue bullets), and `<Tab>`/`<S-Tab>` in insert mode indent/dedent the current line using `config.options.indentation`'s unit.
- `cmp_source.lua` — nvim-cmp completion source for `[[Page]]` links, triggered on `[`, sourcing candidates from `index.names()`.

**Virtual buffer schemes**: `logsvim-journal://<root>` (editable, `acwrite`) and `logsvim-page://<root>/<name>` (read-only, `nofile`). Both are registered via `BufReadCmd` autocmds in `plugin/logsvim.lua`, which also defines the three user commands (`:LogsvimPage`, `:LogsvimJournal`, `:LogsvimReindex`).

**Root resolution order** (`graph.resolve_root`): explicit `setup({root=...})` → `$LOGSVIM_ROOT` → cwd → cwd's parent → prompt among cached known roots. Resolved once per session and memoized; tests must call `require("logsvim.graph")._test.reset_resolved_root()` between cases (see `tests/helpers.lua`'s `temp_graph()`).

**Testing conventions**: `tests/helpers.lua`'s `temp_graph()` copies `tests/fixtures/test-graph/` into a fresh tempdir so tests can mutate files freely, then resets the memoized root. Modules expose test-only internals via a `M._test = {...}` table (e.g. `edit._test.shift_line`, `journal._test.state`) rather than making everything public API.
