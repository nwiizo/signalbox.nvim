local M = {}

local health = vim.health
local compatibility = require("signalbox.compatibility")
local manifest_stale_after_seconds = 7 * 24 * 60 * 60

local function json_optional(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

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

function M._parse_manifest_status(output)
  local ok, decoded = pcall(vim.json.decode, output or "")
  local result = ok and type(decoded) == "table" and decoded.result or nil
  if type(result) ~= "table" or type(result.manifests) ~= "table" or not vim.islist(result.manifests) then
    return nil, "Herdr returned an invalid agent manifest status"
  end
  local status = {
    last_check_unix = tonumber(json_optional(result.last_check_unix)),
    manifests = {},
  }
  for _, manifest in ipairs(result.manifests) do
    if type(manifest) == "table" and type(manifest.agent) == "string" then
      local normalized = {}
      for key, value in pairs(manifest) do
        normalized[key] = json_optional(value)
      end
      status.manifests[manifest.agent] = normalized
    end
  end
  return status
end

function M._manifest_check_age(status, manifest, now)
  local checked_at = tonumber(manifest.remote_last_checked_unix) or tonumber(status.last_check_unix)
  if not checked_at then
    return nil
  end
  return math.max(0, (now or os.time()) - checked_at)
end

function M._manifest_status_argv(command)
  return { command, "server", "agent-manifests", "--json" }
end

function M._manifest_update_argv(command)
  return { command, "server", "update-agent-manifests" }
end

function M._configured_agent_names(agents)
  local configured = {}
  local integrations = {}
  for name in pairs(agents) do
    table.insert(configured, name)
    if name == "codex" or name == "claude" then
      table.insert(integrations, name)
    end
  end
  table.sort(configured)
  table.sort(integrations)
  return configured, integrations
end

local function check_agent_manifests(command, agents)
  local ok, stdout, stderr = run(M._manifest_status_argv(command))
  if not ok then
    health.warn("could not inspect Herdr agent detection manifests: " .. stderr:gsub("%s+$", ""))
    return
  end
  local status, parse_err = M._parse_manifest_status(stdout)
  if not status then
    health.warn(parse_err)
    return
  end
  local update_command = table.concat(M._manifest_update_argv(command), " ")
  for _, name in ipairs(agents) do
    local manifest = status.manifests[name]
    if not manifest then
      health.warn("Herdr did not report the " .. name .. " detection manifest")
    else
      local version = tostring(manifest.active_version or "unknown version")
      local source = tostring(manifest.source_kind or "unknown source")
      local update = tostring(manifest.remote_update_result or "unknown update state")
      local check_age = M._manifest_check_age(status, manifest)
      local check_age_days = check_age and math.floor(check_age / 86400) or nil
      if manifest.local_override_shadowing_remote == true then
        health.info(string.format("Herdr %s detection manifest %s uses a local override", name, version))
      elseif manifest.remote_update_error or (update ~= "current" and update ~= "updated") then
        health.warn(string.format("Herdr %s detection manifest %s update is %s", name, version, update), {
          tostring(manifest.remote_update_error or manifest.warning or "Run a manual manifest update"),
          "Run: " .. update_command,
        })
      elseif check_age == nil then
        health.warn(string.format("Herdr %s detection manifest %s update age is unknown", name, version), {
          "Run: " .. update_command,
        })
      elseif check_age > manifest_stale_after_seconds then
        health.warn(
          string.format("Herdr %s detection manifest %s was last checked %d days ago", name, version, check_age_days),
          { "Run: " .. update_command }
        )
      elseif manifest.warning then
        health.warn(string.format("Herdr %s detection manifest %s: %s", name, version, manifest.warning))
      else
        health.ok(
          string.format(
            "Herdr %s detection manifest %s (%s, %s, checked %dd ago)",
            name,
            version,
            source,
            update,
            check_age_days
          )
        )
      end
    end
  end
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

  local configured_agents, configured_integrations = M._configured_agent_names(config.agents)
  for _, name in ipairs(configured_agents) do
    check_executable(name, name, false)
  end

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
    check_agent_manifests(config.herdr_cmd, configured_agents)
  end
end

return M
