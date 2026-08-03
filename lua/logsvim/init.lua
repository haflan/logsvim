local config = require("logsvim.config")

local M = {}

-- Public setup entrypoint, e.g. require("logsvim").setup({ root = "~/graph" }).
-- See lua/logsvim/config.lua for available options.
function M.setup(opts)
  config.setup(opts)
end

return M
