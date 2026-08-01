local h = require("tests.harness")

h.test("plugin registers the approved user commands", function()
  vim.g.loaded_signalbox_nvim = nil
  vim.cmd("runtime plugin/signalbox.lua")
  for _, command in ipairs({
    "Signalbox",
    "SignalboxRefresh",
    "SignalboxStart",
    "SignalboxAttach",
    "SignalboxPrompt",
    "SignalboxSendVisual",
    "SignalboxSendFile",
    "SignalboxSendDiagnostics",
    "SignalboxHealth",
  }) do
    h.eq(2, vim.fn.exists(":" .. command), command .. " should exist")
  end
  local commands = vim.api.nvim_get_commands({})
  h.eq(true, commands.SignalboxAttach.bang)
  h.truthy(commands.SignalboxPrompt.range ~= nil)
  h.truthy(commands.SignalboxSendVisual.range ~= nil)
end)

h.test("line and visual send commands use separate unambiguous paths", function()
  local signalbox = require("signalbox")
  local original_range = signalbox._send_range
  local original_visual = signalbox._send_visual
  local calls = {}
  signalbox._send_range = function(target, _, line1, line2)
    table.insert(calls, { kind = "range", target = target, line1 = line1, line2 = line2 })
  end
  signalbox._send_visual = function(target, _, line1, line2)
    table.insert(calls, { kind = "visual", target = target, line1 = line1, line2 = line2 })
  end
  vim.cmd("1,1SignalboxPrompt term_1")
  vim.cmd("1,1SignalboxSendVisual term_1")
  signalbox._send_range = original_range
  signalbox._send_visual = original_visual
  h.eq({
    { kind = "range", target = "term_1", line1 = 1, line2 = 1 },
    { kind = "visual", target = "term_1", line1 = 1, line2 = 1 },
  }, calls)
end)

local function agent(id, name, status)
  return {
    terminal_id = id,
    target = id .. ":pane",
    pane_id = id .. ":pane",
    status = status or "working",
    workspace_id = "w1",
    tab_id = "t1",
    focused = false,
    revision = 1,
    name = name,
    kind = "codex",
    title = "",
    cwd = vim.fn.getcwd(),
  }
end

h.test("cold-start prompt waits for the initial Herdr snapshot", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local original_ensure = client.ensure_server
  local original_snapshot = client.snapshot
  local original_prompt = client.prompt
  local snapshots = 0
  local prompted
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    snapshots = snapshots + 1
    callback({
      agents = { agent("term_1", "worker") },
      workspaces = { { workspace_id = "w1", label = "repo" } },
    })
  end
  client.prompt = function(target, text, callback)
    prompted = { target = target, text = text }
    callback({ type = "agent_prompted" })
  end

  signalbox.setup()
  signalbox.prompt("term_1", "hello")
  h.eq(1, snapshots)
  h.eq({ target = "term_1:pane", text = "hello" }, prompted)

  signalbox._reset()
  state._reset()
  config._reset()
  client.ensure_server = original_ensure
  client.snapshot = original_snapshot
  client.prompt = original_prompt
  client._reset()
end)

h.test("cold-start context freezes the invoked buffer before snapshot completion", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local original_ensure = client.ensure_server
  local original_snapshot = client.snapshot
  local original_prompt = client.prompt
  local snapshot_callback
  local prompted
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    snapshot_callback = callback
  end
  client.prompt = function(target, text, callback)
    prompted = { target = target, text = text }
    callback({ type = "agent_prompted" })
  end

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "original context" })
  vim.bo[source].filetype = "lua"
  vim.api.nvim_set_current_buf(source)

  signalbox.setup()
  signalbox._send_range("term_1", source, 1, 1)
  h.truthy(snapshot_callback ~= nil)
  h.eq(nil, prompted)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "changed after invocation" })
  snapshot_callback({
    agents = { agent("term_1", "worker") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  h.eq("term_1:pane", prompted.target)
  h.contains(prompted.text, "original context")
  h.truthy(not prompted.text:find("changed after invocation", 1, true))

  signalbox._reset()
  state._reset()
  config._reset()
  client.ensure_server = original_ensure
  client.snapshot = original_snapshot
  client.prompt = original_prompt
  client._reset()
  if vim.api.nvim_buf_is_valid(source) then
    vim.api.nvim_buf_delete(source, { force = true })
  end
end)

h.test("agent command targets use stable IDs and reject ambiguous names", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  state._reset()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = { agent("term_1", "worker"), agent("term_2", "worker") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  h.eq({ "term_1", "term_2" }, signalbox._complete_agents())
  h.eq("term_2", signalbox._find_agent("term_2").terminal_id)
  local resolved, err = signalbox._find_agent("worker")
  h.eq(nil, resolved)
  h.contains(err, "ambiguous")
end)

h.test("statusline is healthy, stale, and empty when Herdr is missing", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  config._reset()
  local original_start = state.start
  local original_stop = state.stop
  state.start = function() end
  state.stop = function() end
  signalbox.setup({ herdr_cmd = vim.v.progpath })
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = { agent("term_1", "worker", "blocked") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  h.eq("SB !1", signalbox.statusline())
  state._fail({ kind = "process", message = "offline" })
  h.eq("SB !1 ~", signalbox.statusline())
  config.setup({ herdr_cmd = "definitely-not-a-real-herdr-command" })
  h.eq("", signalbox.statusline())
  state.start = original_start
  state.stop = original_stop
  signalbox._reset()
  state._reset()
  config._reset()
end)

h.test("invalid reconfiguration does not stop a working instance", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  config._reset()
  local stops = 0
  local original_start = state.start
  local original_stop = state.stop
  state.start = function() end
  state.stop = function()
    stops = stops + 1
  end
  signalbox.setup({ board = { width = 50 } })
  h.raises("refresh.board_ms", function()
    signalbox.setup({ refresh = { board_ms = 0 } })
  end)
  h.eq(0, stops)
  h.eq(50, config.get().board.width)
  state.start = original_start
  state.stop = original_stop
  signalbox._reset()
  state._reset()
  config._reset()
end)

h.test("only the latest setup lifecycle may start background state", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  config._reset()
  local original_start = state.start
  local original_stop = state.stop
  local starts = 0
  state.start = function()
    starts = starts + 1
  end
  state.stop = function() end
  signalbox.setup()
  signalbox.setup()
  h.truthy(vim.wait(1000, function()
    return starts == 1
  end))
  h.eq(1, starts)
  signalbox._reset()
  state.start = original_start
  state.stop = original_stop
  state._reset()
  config._reset()
end)
