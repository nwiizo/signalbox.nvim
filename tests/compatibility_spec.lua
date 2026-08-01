local h = require("tests.harness")
local compatibility = require("signalbox.compatibility")

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

h.test("Herdr verified version stays consistent across monitoring surfaces", function()
  local version = compatibility.verified_herdr_string
  for _, path in ipairs({
    "README.md",
    "docs/upstream-herdr.md",
    ".github/workflows/monitor-herdr.yml",
  }) do
    h.contains(read(path), version)
  end
end)
