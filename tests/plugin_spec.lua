local h = require("tests.harness")

h.test("plugin registers the approved user commands", function()
  vim.g.loaded_signalbox_nvim = nil
  vim.cmd("runtime plugin/signalbox.lua")
  for _, command in ipairs({
    "Signalbox",
    "SignalboxRefresh",
    "SignalboxStart",
    "SignalboxResume",
    "SignalboxAttach",
    "SignalboxPrompt",
    "SignalboxRename",
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
    registered_name = name,
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

h.test("rename prompts with the current role and refreshes after Herdr accepts it", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local originals = {
    state_start = state.start,
    state_stop = state.stop,
    state_refresh = state.refresh,
    ensure_server = client.ensure_server,
    snapshot = client.snapshot,
    rename = client.rename,
    input = vim.ui.input,
    notify = vim.notify,
  }
  h.defer(function()
    state.start = originals.state_start
    state.stop = originals.state_stop
    state.refresh = originals.state_refresh
    client.ensure_server = originals.ensure_server
    client.snapshot = originals.snapshot
    client.rename = originals.rename
    vim.ui.input = originals.input
    vim.notify = originals.notify
    signalbox._reset()
    state._reset()
    client._reset()
    config._reset()
  end)
  local renamed
  local refreshes = 0
  state.start = function() end
  state.stop = function() end
  state.refresh = function()
    refreshes = refreshes + 1
  end
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    local current = vim.deepcopy(state.agents()[1])
    current.status = "done"
    current.revision = current.revision + 1
    callback({ agents = { current } })
  end
  client.rename = function(target, name, callback)
    renamed = { target = target, name = name }
    callback({ type = "agent_info" })
  end
  vim.ui.input = function(opts, callback)
    h.eq("worker", opts.default)
    callback("reviewer")
  end
  vim.notify = function() end

  signalbox.setup()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = { agent("term_1", "worker") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  signalbox.rename("term_1")
  h.eq({ target = "term_1:pane", name = "reviewer" }, renamed)
  h.eq(1, refreshes)
end)

h.test("rename aborts when the selected agent changes while the input is open", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local originals = {
    state_start = state.start,
    state_stop = state.stop,
    state_refresh = state.refresh,
    ensure_server = client.ensure_server,
    snapshot = client.snapshot,
    rename = client.rename,
    input = vim.ui.input,
    notify = vim.notify,
  }
  h.defer(function()
    state.start = originals.state_start
    state.stop = originals.state_stop
    state.refresh = originals.state_refresh
    client.ensure_server = originals.ensure_server
    client.snapshot = originals.snapshot
    client.rename = originals.rename
    vim.ui.input = originals.input
    vim.notify = originals.notify
    signalbox._reset()
    state._reset()
    client._reset()
    config._reset()
  end)
  local input_callback
  local rename_called = false
  local notifications = {}
  state.start = function() end
  state.stop = function() end
  state.refresh = function() end
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    callback({ agents = state.agents() })
  end
  client.rename = function()
    rename_called = true
  end
  vim.ui.input = function(_, callback)
    input_callback = callback
  end
  vim.notify = function(message)
    table.insert(notifications, message)
  end

  signalbox.setup()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = { agent("term_1", "worker") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  signalbox.rename("term_1")
  h.truthy(input_callback ~= nil)
  local replacement = agent("term_2", "replacement")
  replacement.pane_id = "term_1:pane"
  replacement.target = "term_1:pane"
  state._accept({
    agents = { replacement },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  input_callback("reviewer")
  h.eq(false, rename_called)
  h.contains(table.concat(notifications, "\n"), "agent changed")
end)

h.test("rename aborts when the selected agent is renamed elsewhere while the input is open", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local originals = {
    state_start = state.start,
    state_stop = state.stop,
    state_refresh = state.refresh,
    ensure_server = client.ensure_server,
    snapshot = client.snapshot,
    rename = client.rename,
    input = vim.ui.input,
    notify = vim.notify,
  }
  h.defer(function()
    state.start = originals.state_start
    state.stop = originals.state_stop
    state.refresh = originals.state_refresh
    client.ensure_server = originals.ensure_server
    client.snapshot = originals.snapshot
    client.rename = originals.rename
    vim.ui.input = originals.input
    vim.notify = originals.notify
    signalbox._reset()
    state._reset()
    client._reset()
    config._reset()
  end)

  local rename_called = false
  local notifications = {}
  state.start = function() end
  state.stop = function() end
  state.refresh = function() end
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    local current = vim.deepcopy(state.agents()[1])
    current.name = "reviewer"
    current.registered_name = "reviewer"
    callback({ agents = { current } })
  end
  client.rename = function()
    rename_called = true
  end
  vim.ui.input = function(_, callback)
    callback("tests")
  end
  vim.notify = function(message)
    table.insert(notifications, message)
  end

  signalbox.setup()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = { agent("term_1", "worker") },
    workspaces = { { workspace_id = "w1", label = "repo" } },
  })
  signalbox.rename("term_1")
  h.eq(false, rename_called)
  h.contains(table.concat(notifications, "\n"), "agent changed")
end)

h.test("starting an agent collects an initial instruction and attaches its live terminal", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local terminal = require("signalbox.terminal")
  local board = require("signalbox.board")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local originals = {
    state_start = state.start,
    state_stop = state.stop,
    state_refresh = state.refresh,
    ensure_server = client.ensure_server,
    snapshot = client.snapshot,
    start_agent = client.start_agent,
    prompt = client.prompt,
    prompt_until_working = client.prompt_until_working,
    attach = terminal.attach,
    board_is_open = board.is_open,
    board_close = board.close,
    input = vim.ui.input,
    notify = vim.notify,
  }
  local prompts = {}
  local started
  local prompted
  local attached
  local board_closed = false
  local refreshes = 0
  local notifications = {}
  state.start = function() end
  state.stop = function() end
  state.refresh = function(...)
    refreshes = refreshes + 1
    return originals.state_refresh(...)
  end
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    callback({
      agents = { agent("term_1", "codex-signalbox-nvim", "idle") },
      workspaces = { { workspace_id = "w1", label = "signalbox.nvim" } },
    })
  end
  client.start_agent = function(kind, name, cwd, callback)
    started = { kind = kind, name = name, cwd = cwd }
    callback({ type = "agent_started" }, nil, { pane_id = "w1:p2" }, agent("term_2", name, "idle"))
  end
  client.prompt_until_working = function(target, instruction, callback)
    prompted = { target = target, instruction = instruction }
    callback({ type = "agent_prompted" })
  end
  terminal.attach = function(value)
    attached = value
    return 12
  end
  board.is_open = function()
    return true
  end
  board.close = function()
    board_closed = true
  end
  vim.ui.input = function(opts, callback)
    table.insert(prompts, opts)
    callback(opts.prompt == "Agent name: " and opts.default or "review the current diff")
  end
  vim.notify = function(message)
    table.insert(notifications, message)
  end

  signalbox.setup()
  signalbox.start("codex", { cwd = "/tmp/signalbox.nvim" })
  h.eq("codex-signalbox-nvim-2", prompts[1].default)
  h.eq("Initial instruction (empty to skip, cancel to abort): ", prompts[2].prompt)
  h.eq({ kind = "codex", name = "codex-signalbox-nvim-2", cwd = "/tmp/signalbox.nvim" }, started)
  h.eq({ target = "term_2:pane", instruction = "review the current diff" }, prompted)
  h.eq("term_2", attached.terminal_id)
  h.truthy(board_closed)
  h.eq(2, refreshes)
  h.eq(nil, signalbox._pending_instruction("term_2"))

  client.start_agent = function(kind, name, cwd, callback)
    started = { kind = kind, name = name, cwd = cwd }
    callback({ type = "agent_started" }, nil, { pane_id = "w1:p3" }, agent("term_3", name, "idle"))
  end
  client.prompt_until_working = function(_, _, callback)
    callback(nil, {
      kind = "api",
      code = "agent_prompt_stalled",
      message = "agent did not start working after prompt submission",
    })
  end
  signalbox.start("codex", {
    cwd = "/tmp/signalbox.nvim",
    name = "stalled-instruction",
    instruction = "retry this instruction",
  })
  h.eq("retry this instruction", signalbox._pending_instruction("term_3"))
  h.contains(table.concat(notifications, "\n"), "press p to retry the saved draft")

  state._accept({
    agents = {
      agent("term_1", "codex-signalbox-nvim", "idle"),
      agent("term_3", "stalled-instruction", "idle"),
    },
    workspaces = { { workspace_id = "w1", label = "signalbox.nvim" } },
  })
  local retry_defaults = {}
  vim.ui.input = function(opts, callback)
    if opts.prompt == "Instruction: " then
      table.insert(retry_defaults, opts.default == nil and vim.NIL or opts.default)
    end
    callback(nil)
  end
  signalbox.prompt("term_3")
  h.eq("retry this instruction", retry_defaults[1])

  local retry_prompted
  client.prompt_until_working = function(target, instruction, callback)
    retry_prompted = { target = target, instruction = instruction }
    callback({ type = "agent_prompted" })
  end
  vim.ui.input = function(opts, callback)
    if opts.prompt == "Instruction: " then
      table.insert(retry_defaults, opts.default == nil and vim.NIL or opts.default)
    end
    callback(opts.default)
  end
  signalbox.prompt("term_3")
  h.eq({ target = "term_3:pane", instruction = "retry this instruction" }, retry_prompted)
  h.eq(nil, signalbox._pending_instruction("term_3"))

  client.prompt_until_working = function(_, _, callback)
    callback(nil, {
      kind = "process",
      api_code = "agent_prompt_stalled",
      message = "agent did not start working after prompt submission",
    })
  end
  signalbox.start("codex", {
    cwd = "/tmp/signalbox.nvim",
    name = "stalled-instruction",
    instruction = "retry this instruction",
  })
  h.eq("retry this instruction", signalbox._pending_instruction("term_3"))

  state._accept({
    agents = {
      agent("term_1", "codex-signalbox-nvim", "idle"),
      agent("term_3", "stalled-instruction", "working"),
    },
    workspaces = { { workspace_id = "w1", label = "signalbox.nvim" } },
  })
  h.eq(nil, signalbox._pending_instruction("term_3"))
  signalbox.prompt("term_3")
  h.eq(vim.NIL, retry_defaults[3])
  vim.ui.input = function(opts, callback)
    callback(opts.default)
  end

  started = nil
  signalbox.start("codex", {
    cwd = "/tmp/signalbox.nvim",
    name = "oversized-instruction",
    instruction = string.rep("x", 65537),
  })
  h.eq(nil, started)

  board_closed = false
  attached = nil
  client.start_agent = function(_, _, _, callback)
    callback({ type = "agent_started" }, nil, { pane_id = "w1:p3" }, nil)
  end
  signalbox.start("codex", {
    cwd = "/tmp/signalbox.nvim",
    name = "missing-identity",
    instruction = "",
  })
  h.eq(false, board_closed)
  h.eq(nil, attached)
  h.eq(5, refreshes)

  state.start = originals.state_start
  state.stop = originals.state_stop
  state.refresh = originals.state_refresh
  client.ensure_server = originals.ensure_server
  client.snapshot = originals.snapshot
  client.start_agent = originals.start_agent
  client.prompt = originals.prompt
  client.prompt_until_working = originals.prompt_until_working
  terminal.attach = originals.attach
  board.is_open = originals.board_is_open
  board.close = originals.board_close
  vim.ui.input = originals.input
  vim.notify = originals.notify
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()
end)

h.test("resuming an agent confirms handoff and attaches directly to its picker", function()
  local signalbox = require("signalbox")
  local state = require("signalbox.state")
  local client = require("signalbox.client")
  local terminal = require("signalbox.terminal")
  local board = require("signalbox.board")
  local config = require("signalbox.config")
  signalbox._reset()
  state._reset()
  client._reset()
  config._reset()

  local originals = {
    state_start = state.start,
    state_stop = state.stop,
    state_refresh = state.refresh,
    ensure_server = client.ensure_server,
    snapshot = client.snapshot,
    resume_agent = client.resume_agent,
    attach = terminal.attach,
    board_is_open = board.is_open,
    board_close = board.close,
    input = vim.ui.input,
    select = vim.ui.select,
    notify = vim.notify,
  }
  h.defer(function()
    state.start = originals.state_start
    state.stop = originals.state_stop
    state.refresh = originals.state_refresh
    client.ensure_server = originals.ensure_server
    client.snapshot = originals.snapshot
    client.resume_agent = originals.resume_agent
    terminal.attach = originals.attach
    board.is_open = originals.board_is_open
    board.close = originals.board_close
    vim.ui.input = originals.input
    vim.ui.select = originals.select
    vim.notify = originals.notify
    signalbox._reset()
    state._reset()
    client._reset()
    config._reset()
  end)

  local selections = {}
  local inputs = {}
  local resumed
  local attached
  local board_closed = false
  local refreshes = 0
  local notifications = {}
  state.start = function() end
  state.stop = function() end
  state.refresh = function(...)
    refreshes = refreshes + 1
    return originals.state_refresh(...)
  end
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback)
    callback({
      agents = { agent("term_1", "codex-signalbox-nvim", "idle") },
      workspaces = { { workspace_id = "w1", label = "signalbox.nvim" } },
    })
  end
  client.resume_agent = function(kind, name, cwd, callback)
    resumed = { kind = kind, name = name, cwd = cwd }
    callback({ type = "agent_started" }, nil, { pane_id = "w1:p2" }, agent("term_2", name, "idle"))
  end
  terminal.attach = function(value)
    attached = value
    return 12
  end
  board.is_open = function()
    return true
  end
  board.close = function()
    board_closed = true
  end
  vim.ui.select = function(items, opts, callback)
    table.insert(selections, { items = items, opts = opts })
    callback("Continue")
  end
  vim.ui.input = function(opts, callback)
    table.insert(inputs, opts)
    callback(opts.default)
  end
  vim.notify = function(value)
    table.insert(notifications, value)
  end

  signalbox.setup()
  signalbox.resume("codex", { cwd = "/tmp/signalbox.nvim" })
  h.contains(selections[1].opts.prompt, "Stop the existing codex client")
  h.eq({ "Continue", "Cancel" }, selections[1].items)
  h.eq(1, #inputs)
  h.eq("codex-signalbox-nvim-2", inputs[1].default)
  h.eq({ kind = "codex", name = "codex-signalbox-nvim-2", cwd = "/tmp/signalbox.nvim" }, resumed)
  h.eq("term_2", attached.terminal_id)
  h.truthy(board_closed)
  h.eq(2, refreshes)
  h.contains(table.concat(notifications, "\n"), "resume picker")

  resumed = nil
  attached = nil
  vim.ui.select = function(_, _, callback)
    callback("Cancel")
  end
  signalbox.resume("codex", { cwd = "/tmp/signalbox.nvim" })
  h.eq(nil, resumed)
  h.eq(nil, attached)
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
