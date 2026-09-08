local h = require("tests.harness")
local health = require("signalbox.health")

for _, endpoint in ipairs({ "yes", "no", "unknown" }) do
  h.test("health respects endpoint compatibility " .. endpoint .. " over private protocol compatibility", function()
    local original_system = vim.system
    local original_health = {}
    local reports = {}
    h.defer(function()
      vim.system = original_system
      for name, handler in pairs(original_health) do
        vim.health[name] = handler
      end
      require("signalbox.config")._reset()
    end)
    for _, name in ipairs({ "start", "ok", "warn", "error", "info" }) do
      original_health[name] = vim.health[name]
      vim.health[name] = function(message)
        reports[message] = name
      end
    end
    require("signalbox.config").setup({ herdr_cmd = vim.v.progpath })
    vim.system = function(argv)
      local output = ""
      if argv[2] == "--version" then
        output = "herdr " .. require("signalbox.compatibility").verified_herdr_string
      elseif argv[2] == "status" then
        output = "status: running\nendpoint_compatible: "
          .. endpoint
          .. "\nprivate_protocol: 22\nprivate_protocol_compatible: yes\n"
      elseif argv[2] == "server" then
        output = '{"result":{"manifests":[]}}'
      end
      return {
        wait = function()
          return { code = 0, stdout = output, stderr = "" }
        end,
      }
    end
    health.check()
    if endpoint == "yes" then
      h.eq("ok", reports["Herdr server is running and compatible with this client"])
    else
      h.eq(nil, reports["Herdr server is running and compatible with this client"])
      h.eq("warn", reports["Herdr server responded but did not report compatibility with this client"])
    end
  end)
end

h.test("health parses configured Herdr detection manifest status", function()
  local manifests, err = health._parse_manifest_status(vim.json.encode({
    id = "cli:server:agent-manifests",
    result = {
      type = "agent_manifest_status",
      last_check_unix = 1785597737,
      manifests = {
        {
          agent = "codex",
          active_version = "2026.07.18.1",
          source_kind = "remote",
          remote_update_result = "current",
        },
      },
    },
  }))
  h.eq(nil, err)
  h.eq("2026.07.18.1", manifests.manifests.codex.active_version)
  h.eq("current", manifests.manifests.codex.remote_update_result)
  h.eq(86400, health._manifest_check_age(manifests, manifests.manifests.codex, 1785684137))
end)

h.test("health rejects malformed Herdr detection manifest status", function()
  local manifests, err = health._parse_manifest_status('{"result":{"manifests":{}}}')
  h.eq(nil, manifests)
  h.contains(err, "invalid agent manifest status")
end)

h.test("health normalizes nullable Herdr manifest fields", function()
  local status, err = health._parse_manifest_status([[{
    "result": {
      "last_check_unix": 100,
      "manifests": [{
        "agent": "codex",
        "active_version": "2026.07.18.1",
        "source_kind": "remote",
        "remote_update_result": "current",
        "remote_last_checked_unix": null,
        "remote_update_error": null,
        "warning": null,
        "local_override_shadowing_remote": false
      }]
    }
  }]])
  h.eq(nil, err)
  h.eq(nil, status.manifests.codex.remote_update_error)
  h.eq(nil, status.manifests.codex.warning)
  h.eq(false, status.manifests.codex.local_override_shadowing_remote)
  h.eq(60, health._manifest_check_age(status, status.manifests.codex, 160))
end)

h.test("health reports missing and stale Herdr manifest check times", function()
  local status = { manifests = {} }
  h.eq(nil, health._manifest_check_age(status, {}))
  status.last_check_unix = 100
  h.eq(8 * 86400, health._manifest_check_age(status, {}, 100 + 8 * 86400))
  h.eq(60, health._manifest_check_age(status, { remote_last_checked_unix = 200 }, 260))
end)

h.test("health pins the current Herdr manifest status and update argv", function()
  h.eq({ "herdr", "server", "agent-manifests", "--json" }, health._manifest_status_argv("herdr"))
  h.eq({ "herdr", "server", "update-agent-manifests" }, health._manifest_update_argv("herdr"))
end)

h.test("health checks manifests for every configured agent but integrations only where supported", function()
  local agents, integrations = health._configured_agent_names({ codex = {}, claude = {}, pi = {}, opencode = {} })
  h.eq({ "claude", "codex", "opencode", "pi" }, agents)
  h.eq({ "claude", "codex" }, integrations)
end)
