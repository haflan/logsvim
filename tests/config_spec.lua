local config = require("logsvim.config")

describe("config.setup keymaps", function()
  it("defaults to gd/<CR> for goto_reference and <leader>rn for rename", function()
    config.setup({})
    assert.are.same({ "gd", "<CR>" }, config.options.keymaps.goto_reference)
    assert.are.same("<leader>rn", config.options.keymaps.rename)
  end)

  it("overrides a single action without disturbing the other's default", function()
    config.setup({ keymaps = { rename = "<leader>R" } })
    assert.are.same({ "gd", "<CR>" }, config.options.keymaps.goto_reference)
    assert.are.same("<leader>R", config.options.keymaps.rename)
  end)

  it("replaces a list action wholesale rather than merging by index", function()
    config.setup({ keymaps = { goto_reference = { "<CR>" } } })
    assert.are.same({ "<CR>" }, config.options.keymaps.goto_reference)
  end)

  it("disables an action with false", function()
    config.setup({ keymaps = { rename = false } })
    assert.is_false(config.options.keymaps.rename)
  end)
end)

describe("config.set_keymap", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  local function lhs_set(bufnr_)
    local set = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr_, "n")) do
      set[map.lhs] = true
    end
    return set
  end

  it("binds every key configured for the action", function()
    config.setup({ keymaps = { goto_reference = { "gd", "<CR>" } } })
    config.set_keymap(bufnr, "goto_reference", function() end, "test")
    local maps = lhs_set(bufnr)
    assert.is_true(maps["gd"])
    assert.is_true(maps["<CR>"])
  end)

  it("binds a single string key", function()
    -- Avoid <leader> here: vim.keymap.set stores lhs post-expansion, and
    -- mapleader isn't necessarily set in the test environment.
    config.setup({ keymaps = { rename = "zr" } })
    config.set_keymap(bufnr, "rename", function() end, "test")
    assert.is_true(lhs_set(bufnr)["zr"])
  end)

  it("does nothing when the action is disabled", function()
    config.setup({ keymaps = { rename = false } })
    config.set_keymap(bufnr, "rename", function() end, "test")
    assert.is_false(lhs_set(bufnr)["<leader>rn"] or false)
  end)

  it("binds in the given modes", function()
    config.setup({ keymaps = { cycle_task = "zt" } })
    config.set_keymap(bufnr, "cycle_task", function() end, "test", { "n", "i" })
    assert.is_true(lhs_set(bufnr)["zt"])
    local insert = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
      insert[map.lhs] = true
    end
    assert.is_true(insert["zt"])
  end)
end)
