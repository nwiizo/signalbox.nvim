local h = require("tests.harness")
local config = require("signalbox.config")
local client = require("signalbox.client")

local function reset()
  config._reset()
  client._reset()
end

h.test("config deep merges defaults without mutating caller options", function()
  reset()
  local opts = { board = { width = 52 }, agents = { codex = { args = { "--profile", "work" } } } }
  local result = config.setup(opts)
  h.eq(52, result.board.width)
  h.eq(0.9, result.board.height)
  h.eq("<C-g>", result.terminal.return_key)
  h.eq({ "--profile", "work" }, result.agents.codex.args)
  h.eq({}, result.agents.claude.args)
  result.agents.codex.args[1] = "changed"
  h.eq("--profile", opts.agents.codex.args[1])
end)

h.test("config rejects invalid values with a precise path", function()
  reset()
  h.raises("refresh.board_ms", function()
    config.setup({ refresh = { board_ms = 0 } })
  end)
  h.raises("terminal.side", function()
    config.setup({ terminal = { side = "center" } })
  end)
  h.raises("terminal.return_key", function()
    config.setup({ terminal = { return_key = "" } })
  end)
  h.raises("agents.codex.args", function()
    config.setup({ agents = { codex = { args = "--unsafe" } } })
  end)
  h.raises("refresh must be a table", function()
    config.setup({ refresh = false })
  end)
  h.raises("board.markers must be a table", function()
    config.setup({ board = { markers = false } })
  end)
end)

h.test("config publishes only fully validated updates", function()
  reset()
  config.setup({ board = { width = 52 } })
  h.raises("refresh.board_ms", function()
    config.setup({ refresh = { board_ms = 0 } })
  end)
  h.eq(52, config.get().board.width)
  h.eq(1000, config.get().refresh.board_ms)
end)

local function raw_snapshot(agent)
  return {
    type = "session_snapshot",
    snapshot = {
      version = "0.7.5",
      protocol = 17,
      agents = { agent },
      workspaces = { { workspace_id = "w1", label = "repo", focused = true, extra = "ignored" } },
      panes = { { pane_id = "w1:p1", workspace_id = "w1", cwd = "/repo" } },
      extra = "ignored",
    },
  }
end

local function raw_agent(overrides)
  return vim.tbl_extend("force", {
    terminal_id = "term_1",
    agent_status = "working",
    workspace_id = "w1",
    tab_id = "w1:t1",
    pane_id = "w1:p1",
    focused = false,
    revision = 3,
    name = "api",
    agent = "codex",
    cwd = "/repo",
    unknown_future_field = true,
  }, overrides or {})
end

h.test("client normalizes documented snapshot fields and ignores unknown fields", function()
  reset()
  config.setup()
  local result, err = client._normalize_snapshot(raw_snapshot(raw_agent()))
  h.eq(nil, err)
  h.eq("term_1", result.agents[1].terminal_id)
  h.eq("working", result.agents[1].status)
  h.eq("api", result.agents[1].name)
  h.eq("api", result.agents[1].registered_name)
  h.eq("repo", result.workspaces[1].label)
end)

h.test("client maps future statuses to unknown but rejects missing required fields", function()
  reset()
  config.setup()
  local future = client._normalize_snapshot(raw_snapshot(raw_agent({ agent_status = "paused" })))
  h.eq("unknown", future.agents[1].status)

  local result, err = client._normalize_snapshot(raw_snapshot(raw_agent({ terminal_id = false })))
  h.eq(nil, result)
  h.contains(err.message, "terminal_id")
end)

h.test("client normalizes nullable display fields before applying fallbacks", function()
  reset()
  config.setup()
  local result = client._normalize_snapshot(raw_snapshot(raw_agent({
    name = vim.NIL,
    display_agent = vim.NIL,
    title = vim.NIL,
    foreground_cwd = vim.NIL,
    cwd = "/repo",
  })))
  h.eq("codex", result.agents[1].name)
  h.eq(nil, result.agents[1].registered_name)
  h.eq("", result.agents[1].title)
  h.eq("/repo", result.agents[1].cwd)

  local with_null_label = raw_snapshot(raw_agent())
  with_null_label.snapshot.workspaces[1].label = vim.NIL
  result = client._normalize_snapshot(with_null_label)
  h.eq("w1", result.workspaces[1].label)
end)

h.test("client derives and validates Herdr-compatible agent names before allocation", function()
  reset()
  config.setup()
  h.eq("codex-signalbox-nvim", client.default_agent_name("codex", "signalbox.nvim"))
  h.eq("agent", client.default_agent_name("123", "日本語"))
  h.eq("worker_2", client.validate_agent_name("worker_2"))

  local result, err
  client._set_runner(function()
    error("invalid names must not invoke Herdr")
  end)
  client.start_agent("codex", "Codex.signalbox.nvim", "/repo", function(value, value_err)
    result, err = value, value_err
  end)
  h.eq(nil, result)
  h.eq("validation", err.kind)
  h.contains(err.message, "lowercase letter")
end)

h.test("client rejects duplicate agent names before creating a pane", function()
  reset()
  config.setup()
  local calls = {}
  local result, err
  client._set_runner(function(argv, _, callback)
    table.insert(calls, vim.deepcopy(argv))
    callback({ code = 0, stdout = vim.json.encode({ id = "1", result = raw_snapshot(raw_agent()) }), stderr = "" })
  end)
  client.start_agent("codex", "api", "/repo", function(value, value_err)
    result, err = value, value_err
  end)
  h.eq(nil, result)
  h.eq("validation", err.kind)
  h.contains(err.message, "already in use")
  h.eq(1, #calls)
  h.eq({ "herdr", "api", "snapshot" }, calls[1])
end)

h.test("client does not treat a fallback display label as a registered duplicate name", function()
  reset()
  config.setup()
  local calls = {}
  local result
  client._set_runner(function(argv, _, callback)
    table.insert(calls, vim.deepcopy(argv))
    if argv[2] == "api" then
      callback({
        code = 0,
        stdout = vim.json.encode({ id = "1", result = raw_snapshot(raw_agent({ name = vim.NIL })) }),
        stderr = "",
      })
    elseif argv[2] == "tab" then
      callback({
        code = 0,
        stdout = vim.json.encode({ id = "1", result = { type = "tab_created", root_pane = { pane_id = "w1:p2" } } }),
        stderr = "",
      })
    else
      callback({
        code = 0,
        stdout = vim.json.encode({ id = "1", result = { type = "agent_started" } }),
        stderr = "",
      })
    end
  end)
  client.start_agent("codex", "codex", "/repo", function(value)
    result = value
  end)
  h.eq("agent_started", result.type)
  h.eq(3, #calls)
end)

h.test("client rejects object-shaped lists and malformed workspaces", function()
  reset()
  config.setup()
  local invalid = raw_snapshot(raw_agent())
  invalid.snapshot.agents = { named = raw_agent() }
  local result, err = client._normalize_snapshot(invalid)
  h.eq(nil, result)
  h.eq("schema", err.kind)

  invalid = raw_snapshot(raw_agent())
  invalid.snapshot.workspaces = { { label = "missing id" } }
  result, err = client._normalize_snapshot(invalid)
  h.eq(nil, result)
  h.contains(err.message, "workspace_id")
end)

h.test("client uses current Herdr argv contracts for snapshot, start, prompt, and read", function()
  reset()
  config.setup()
  local calls = {}
  local call_opts = {}
  local started_agent
  client._set_runner(function(argv, opts, callback)
    table.insert(calls, vim.deepcopy(argv))
    table.insert(call_opts, vim.deepcopy(opts))
    local payload
    if argv[2] == "api" then
      payload = { id = "1", result = raw_snapshot(raw_agent()) }
    elseif argv[2] == "tab" then
      payload = { id = "1", result = { type = "tab_created", root_pane = { pane_id = "w1:p2" } } }
    elseif argv[2] == "agent" and argv[3] == "start" then
      payload = {
        id = "1",
        result = {
          type = "agent_started",
          agent = raw_agent({ name = "worker", pane_id = "w1:p2", terminal_id = "term_2" }),
        },
      }
    elseif argv[2] == "agent" and argv[3] == "prompt" then
      payload = { id = "1", result = { type = "agent_prompted" } }
    else
      callback({ code = 0, stdout = "recent output\n", stderr = "" })
      return
    end
    callback({ code = 0, stdout = vim.json.encode(payload), stderr = "" })
  end)

  client.snapshot(function(result)
    h.eq("term_1", result.agents[1].terminal_id)
  end)
  client.start_agent("codex", "worker", "/repo", function(result, _, _, agent)
    h.eq("agent_started", result.type)
    started_agent = agent
  end)
  client.prompt("w1:p2", "review `$(unsafe)`\nnext", function(result)
    h.eq("agent_prompted", result.type)
  end)
  client.read("w1:p2", 80, function(output)
    h.eq("recent output\n", output)
  end)

  h.eq({ "herdr", "api", "snapshot" }, calls[1])
  h.eq({ "herdr", "api", "snapshot" }, calls[2])
  h.eq({ "herdr", "tab", "create", "--workspace", "w1", "--cwd", "/repo", "--label", "worker", "--no-focus" }, calls[3])
  h.eq({ "herdr", "agent", "start", "worker", "--kind", "codex", "--pane", "w1:p2", "--timeout", "30000" }, calls[4])
  h.eq(35000, call_opts[4].timeout_ms)
  h.eq("term_2", started_agent.terminal_id)
  h.eq("w1:p2", started_agent.target)
  h.eq({ "herdr", "agent", "prompt", "w1:p2", "review `$(unsafe)`\nnext" }, calls[5])
  h.eq(
    { "herdr", "agent", "read", "w1:p2", "--source", "recent-unwrapped", "--lines", "80", "--format", "text" },
    calls[6]
  )
end)

h.test("client creates a workspace when no pane belongs to the project", function()
  reset()
  config.setup({ agents = { codex = { args = { "--profile", "work" } } } })
  local calls = {}
  client._set_runner(function(argv, _, callback)
    table.insert(calls, vim.deepcopy(argv))
    local result
    if argv[2] == "api" then
      local snapshot = raw_snapshot(raw_agent())
      snapshot.snapshot.panes = {}
      snapshot.snapshot.agents = {}
      result = snapshot
    elseif argv[2] == "workspace" then
      result = { type = "workspace_created", root_pane = { pane_id = "w2:p1" } }
    else
      result = { type = "agent_started" }
    end
    callback({ code = 0, stdout = vim.json.encode({ id = "1", result = result }), stderr = "" })
  end)
  client.start_agent("codex", "worker", "/new-repo", function(result)
    h.eq("agent_started", result.type)
  end)
  h.eq({ "herdr", "workspace", "create", "--cwd", "/new-repo", "--label", "new-repo", "--no-focus" }, calls[2])
  h.eq({
    "herdr",
    "agent",
    "start",
    "worker",
    "--kind",
    "codex",
    "--pane",
    "w2:p1",
    "--timeout",
    "30000",
    "--",
    "--profile",
    "work",
  }, calls[3])
end)

h.test("client reports the retained pane when agent startup fails", function()
  reset()
  config.setup()
  local calls = {}
  client._set_runner(function(argv, _, callback)
    table.insert(calls, vim.deepcopy(argv))
    if argv[2] == "api" then
      local snapshot = raw_snapshot(raw_agent())
      snapshot.snapshot.panes = {}
      snapshot.snapshot.agents = {}
      callback({ code = 0, stdout = vim.json.encode({ id = "1", result = snapshot }), stderr = "" })
    elseif argv[2] == "workspace" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          id = "1",
          result = {
            type = "workspace_created",
            root_pane = { pane_id = "w3:p1" },
            workspace = { workspace_id = "w3" },
          },
        }),
        stderr = "",
      })
    else
      callback({ code = 1, stdout = "", stderr = "agent failed readiness" })
    end
  end)
  client.start_agent("codex", "worker", "/failed-repo", function(result, err)
    h.eq(nil, result)
    h.eq("w3:p1", err.recovery.pane_id)
    h.eq("w3", err.recovery.resource_id)
    h.contains(err.message, "kept the new workspace w3")
  end)
  h.eq(3, #calls)
end)

h.test("client retries a newly created pane until its shell is ready", function()
  reset()
  config.setup()
  local starts = 0
  local delays = {}
  local result
  local final_err
  client._set_defer(function(callback, delay)
    table.insert(delays, delay)
    callback()
  end)
  client._set_runner(function(argv, _, callback)
    if argv[2] == "api" then
      local snapshot = raw_snapshot(raw_agent())
      snapshot.snapshot.panes = {}
      snapshot.snapshot.agents = {}
      callback({ code = 0, stdout = vim.json.encode({ id = "1", result = snapshot }), stderr = "" })
    elseif argv[2] == "workspace" then
      callback({
        code = 0,
        stdout = vim.json.encode({
          id = "1",
          result = {
            type = "workspace_created",
            root_pane = { pane_id = "w4:p1" },
            workspace = { workspace_id = "w4" },
          },
        }),
        stderr = "",
      })
    else
      starts = starts + 1
      if starts < 3 then
        callback({
          code = 1,
          stdout = vim.json.encode({
            id = "cli:agent:start",
            error = { code = "agent_pane_busy", message = "agent target pane is not an available shell" },
          }),
          stderr = "",
        })
      else
        callback({
          code = 0,
          stdout = vim.json.encode({ id = "1", result = { type = "agent_started" } }),
          stderr = "",
        })
      end
    end
  end)
  client.start_agent("codex", "worker", "/new-repo", function(value, value_err)
    result = value
    final_err = value_err
  end)
  h.eq(nil, final_err)
  h.eq(3, starts)
  h.eq({ 100, 300 }, delays)
  h.eq("agent_started", result.type)
end)

h.test("structured nonzero errors retain process recovery semantics", function()
  reset()
  config.setup()
  client._set_runner(function(_, _, callback)
    callback({
      code = 1,
      stdout = vim.json.encode({
        id = "cli:api:snapshot",
        error = { code = "server_unavailable", message = "server is unavailable" },
      }),
      stderr = "",
    })
  end)
  client.snapshot(function(result, err)
    h.eq(nil, result)
    h.eq("process", err.kind)
    h.eq(1, err.code)
    h.eq("server_unavailable", err.api_code)
  end)
end)

h.test("client rejects malformed JSON atomically", function()
  reset()
  config.setup()
  client._set_runner(function(_, _, callback)
    callback({ code = 0, stdout = "not-json", stderr = "" })
  end)
  client.snapshot(function(result, err)
    h.eq(nil, result)
    h.eq("json", err.kind)
  end)
end)

h.test("client process errors never echo instruction bodies", function()
  reset()
  config.setup()
  client._set_runner(function(_, _, callback)
    callback({ code = 9, stdout = "", stderr = "" })
  end)
  client.prompt("w1:p1", "SECRET PROMPT BODY", function(result, err)
    h.eq(nil, result)
    h.contains(err.message, "agent prompt")
    h.truthy(not err.message:find("SECRET PROMPT BODY", 1, true))
  end)
end)

h.test("client reads preview output without JSON decoding", function()
  reset()
  config.setup()
  client._set_runner(function(argv, _, callback)
    h.eq(
      { "herdr", "agent", "read", "w1:p1", "--source", "recent-unwrapped", "--lines", "40", "--format", "text" },
      argv
    )
    callback({ code = 0, stdout = "plain output\n", stderr = "" })
  end)
  client.read("w1:p1", 40, function(result, err)
    h.eq(nil, err)
    h.eq("plain output\n", result)
  end)
end)

h.test("client shares one bounded server start among concurrent callers", function()
  reset()
  config.setup({ server_retry_ms = { 1 } })
  local status_calls = 0
  local starts = 0
  client._set_runner(function(argv, _, callback)
    if argv[2] == "status" then
      status_calls = status_calls + 1
      if status_calls == 1 then
        callback({ code = 0, stdout = "status: not running\nsocket: /tmp/herdr.sock\n", stderr = "" })
      else
        callback({ code = 0, stdout = "status: running\nprotocol: 16\ncompatible: yes\n", stderr = "" })
      end
    end
  end)
  client._set_job_starter(function(argv)
    starts = starts + 1
    h.eq({ "herdr", "server" }, argv)
    return 42
  end)
  client._set_defer(function(callback)
    callback()
  end)

  local results = {}
  client.ensure_server(function(ok)
    table.insert(results, ok)
  end)
  client.ensure_server(function(ok)
    table.insert(results, ok)
  end)
  h.eq(1, starts)
  h.eq({ true, true }, results)
end)

h.test("client reports a missing Herdr executable asynchronously", function()
  reset()
  config.setup({ herdr_cmd = "definitely-not-a-real-herdr-command", auto_start_server = false })
  local result
  client.ensure_server(function(ok, err)
    result = { ok = ok, err = err }
  end)
  h.truthy(vim.wait(1000, function()
    return result ~= nil
  end))
  h.eq(false, result.ok)
  h.eq("executable", result.err.kind)
  h.contains(result.err.message, "ENOENT")
end)

h.test("client rejects a reachable but incompatible Herdr server", function()
  reset()
  config.setup({ auto_start_server = false })
  client._set_runner(function(_, _, callback)
    callback({ code = 0, stdout = "status: running\nprotocol: 99\ncompatible: no\n", stderr = "" })
  end)
  client.ensure_server(function(ok, err)
    h.eq(false, ok)
    h.eq("protocol", err.kind)
  end)
end)
