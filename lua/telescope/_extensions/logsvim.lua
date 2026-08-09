-- Optional telescope.nvim integration, mirroring :LogsvimPage's own
-- command-line completion (see plugin/logsvim.lua): lists pseudo-pages that
-- currently have something to show first, then every known real page (see
-- pages.completion_names), and opens whichever one is selected. Not
-- required by the rest of logsvim -- only loaded if the user calls
-- require("telescope").load_extension("logsvim").
local telescope = require("telescope")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local graph = require("logsvim.graph")
local pages = require("logsvim.pages")

-- Preview a page/pseudo-page's rendered contents, reusing pages.render() so
-- both a real page's own content + backlinks and a pseudo-page's live
-- aggregation preview exactly like opening it with pages.open() would show.
local function page_previewer(root)
  return previewers.new_buffer_previewer({
    title = "Page preview",
    define_preview = function(self, entry)
      local lines = pages.render(root, entry.value)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "markdown"
    end,
  })
end

local function pages_picker(opts)
  opts = opts or {}
  graph.resolve_root(function(root)
    if not root then
      return
    end

    pickers
      .new(opts, {
        prompt_title = "Logsvim Pages",
        finder = finders.new_table({ results = pages.completion_names(root) }),
        sorter = conf.generic_sorter(opts),
        previewer = page_previewer(root),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection then
              pages.open(selection[1])
            end
          end)
          return true
        end,
      })
      :find()
  end)
end

return telescope.register_extension({
  exports = {
    pages = pages_picker,
  },
})
