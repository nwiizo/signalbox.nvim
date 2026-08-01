local M = {}

local health = vim.health
local compatibility = require("signalbox.compatibility")

local function run(argv)
  local ok, process = pcall(vim.system, argv, { text = true })
  if not ok then
    return false, "", tostring(process)
  end
  local result = process:wait(3000)
  return result.code == 0, result.stdout or "", result.stderr or ""
end

local function supported_herdr_version(output)
  local version = output:match("(%d+%.%d+%.%d+)")
  if not version then
    return false
  end
  local parsed = vim.version.parse(version)
  return parsed ~= nil and vim.version.ge(parsed, compatibility.minimum_herdr)
end

local function newer_than_verified(output)
  local version = output:match("(%d+%.%d+%.%d+)")
  local parsed = version and vim.version.parse(version) or nil
  return parsed ~= nil
    and vim.version.ge(parsed, compatibility.verified_herdr)
    and not compatibility.same_version(parsed, compatibility.verified_herdr)
end

local function check_executable(command, label, required)
  local path = vim.fn.exepath(command)
  if path ~= "" then
    health.ok(string.format("%s: %s", label, path))
    return true
  end
  if required then
    health.error(label .. " is not executable")
  else
    health.warn(string.format("%s is not executable (%s); its launch preset will not work", label, command))
  end
  return false
end

function M.check()
  health.start("signalbox.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10 or newer")
  else
    health.error("Neovim 0.10 or newer is required")
  end

  local config = require("signalbox.config").get()
  local herdr_path = vim.fn.exepath(config.herdr_cmd)
  if herdr_path == "" then
    health.error("Herdr is not executable", { "Install Herdr from https://herdr.dev/" })
  else
    local ok, stdout, stderr = run({ config.herdr_cmd, "--version" })
    if ok then
      local version_line = stdout:gsub("%s+$", "")
      if newer_than_verified(version_line) then
        health.warn(
          version_line
            .. " is newer than the latest Signalbox compatibility audit ("
            .. compatibility.verified_herdr_string
            .. ")",
          {
            "Check the Herdr upgrade issue before relying on unverified behavior",
          }
        )
      elseif supported_herdr_version(version_line) then
        health.ok(version_line)
      else
        health.error(
          version_line .. " is unsupported; Herdr " .. compatibility.minimum_herdr_string .. " or newer is required"
        )
      end
    else
      health.error("failed to run Herdr: " .. (stderr:gsub("%s+$", "")))
    end

    ok, stdout, stderr = run({ config.herdr_cmd, "status", "server" })
    if ok then
      if stdout:match("status:%s*not running") then
        health.warn("Herdr server is not running", {
          "Run: " .. config.herdr_cmd .. " server",
        })
      elseif stdout:find("compatible: yes", 1, true) then
        health.ok("Herdr server is running with a compatible protocol")
      else
        health.warn("Herdr server responded but did not report protocol compatibility")
      end
    else
      health.warn("Herdr server is not reachable: " .. stderr:gsub("%s+$", ""), {
        "Run: " .. config.herdr_cmd .. " server",
      })
    end
  end

  local configured_integrations = {}
  for name in pairs(config.agents) do
    check_executable(name, name, false)
    if name == "codex" or name == "claude" then
      table.insert(configured_integrations, name)
    end
  end
  table.sort(configured_integrations)

  if herdr_path ~= "" then
    local ok, stdout, stderr = run({ config.herdr_cmd, "integration", "status" })
    if not ok then
      health.warn("could not inspect Herdr integrations: " .. stderr)
    else
      for _, name in ipairs(configured_integrations) do
        local line = stdout:match("[\n^]" .. name .. ": ([^\n]+)") or stdout:match("^" .. name .. ": ([^\n]+)")
        if line and line:match("^current") then
          health.ok(string.format("Herdr %s integration is %s", name, line))
        elseif line then
          health.warn(string.format("Herdr %s integration is %s", name, line), {
            string.format("Run: herdr integration install %s", name),
          })
        else
          health.warn("Herdr did not report the " .. name .. " integration")
        end
      end
    end
  end
end

return M
