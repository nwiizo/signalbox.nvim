local h = require("tests.harness")
local health = require("signalbox.health")

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

h.test("health pins the Herdr 0.7.5 manifest status and update argv", function()
  h.eq({ "herdr", "server", "agent-manifests", "--json" }, health._manifest_status_argv("herdr"))
  h.eq({ "herdr", "server", "update-agent-manifests" }, health._manifest_update_argv("herdr"))
end)

h.test("health checks manifests for every configured agent but integrations only where supported", function()
  local agents, integrations = health._configured_agent_names({ codex = {}, claude = {}, pi = {}, opencode = {} })
  h.eq({ "claude", "codex", "opencode", "pi" }, agents)
  h.eq({ "claude", "codex" }, integrations)
end)
