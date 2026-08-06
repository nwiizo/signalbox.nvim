local config = require("signalbox.config")

local M = {}

local valid_status = {
  blocked = true,
  working = true,
  done = true,
  idle = true,
  unknown = true,
}

local runner
local job_starter
local termopen
local defer = vim.defer_fn
local server_ready = false
local server_checking = false
local server_waiters = {}
local agent_shell_retry_ms = { 100, 300, 1000 }

local function trim(value)
  return ((value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local agent_name_error = table.concat({
  "agent name must start with a lowercase letter and contain only lowercase letters,",
  "digits, '-' or '_' (1-32 characters)",
}, " ")

function M.validate_agent_name(name)
  if type(name) ~= "string" or #name > 32 or not name:match("^[a-z][a-z0-9_-]*$") then
    return nil, { kind = "validation", message = agent_name_error }
  end
  return name
end

function M.default_agent_name(kind, project)
  local candidate = string.format("%s-%s", tostring(kind or "agent"), tostring(project or "agent")):lower()
  candidate = candidate:gsub("[^a-z0-9_-]+", "-"):gsub("^[-_0-9]+", ""):gsub("[-_]+$", "")
  if candidate == "" then
    candidate = "agent"
  elseif not candidate:match("^[a-z]") then
    candidate = "agent-" .. candidate
  end
  candidate = candidate:sub(1, 32):gsub("[-_]+$", "")
  return candidate ~= "" and candidate or "agent"
end

function M.next_agent_name(candidate, agents)
  local used = {}
  for _, agent in ipairs(agents or {}) do
    if type(agent.registered_name) == "string" then
      used[agent.registered_name] = true
    end
  end
  if not used[candidate] then
    return candidate
  end
  local index = 2
  while true do
    local suffix = "-" .. index
    local prefix = candidate:sub(1, 32 - #suffix):gsub("[-_]+$", "")
    local next_name = prefix .. suffix
    if not used[next_name] then
      return next_name
    end
    index = index + 1
  end
end

local function default_runner(command, opts, callback)
  local ok, spawn_err = pcall(vim.system, command, { text = true, timeout = opts.timeout_ms }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = 127, stdout = "", stderr = tostring(spawn_err), spawn_error = true })
    end)
  end
end

local function default_job_starter(command)
  local ok, result = pcall(vim.fn.jobstart, command, { detach = true })
  if not ok then
    return nil, tostring(result)
  end
  return result
end

local function executable_argv(args)
  local result = { config.get().herdr_cmd }
  vim.list_extend(result, args)
  return result
end

local function process_error(result, command)
  local decoded
  for _, output in ipairs({ result.stdout or "", result.stderr or "" }) do
    local json_ok, candidate = pcall(vim.json.decode, trim(output))
    if json_ok and type(candidate) == "table" and type(candidate.error) == "table" then
      decoded = candidate
      break
    end
  end
  if decoded then
    return {
      kind = "process",
      code = result.code,
      api_code = decoded.error.code,
      message = decoded.error.message or decoded.error.code or "Herdr API error",
    }
  end
  local detail = trim(result.stderr)
  if detail == "" then
    detail = trim(result.stdout)
  end
  if detail == "" then
    detail = string.format("%s exited with code %s", command, tostring(result.code))
  end
  return {
    kind = (result.spawn_error == true or detail:find("ENOENT", 1, true) ~= nil) and "executable" or "process",
    code = result.code,
    signal = result.signal,
    message = detail,
  }
end

local function run(args, opts, callback)
  opts = opts or {}
  opts.timeout_ms = opts.timeout_ms or config.get().refresh.timeout_ms
  local process_runner = runner or default_runner
  process_runner(executable_argv(args), opts, function(result)
    if type(result) ~= "table" then
      callback(nil, { kind = "internal", message = "process runner returned no result" })
      return
    end
    if result.code ~= 0 then
      local safe_command = table.concat(vim.list_slice(args, 1, math.min(#args, 2)), " ")
      callback(nil, process_error(result, safe_command))
      return
    end
    callback(result)
  end)
end

local function run_json(args, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  run(args, opts or {}, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout or "")
    if not ok or type(decoded) ~= "table" then
      callback(nil, { kind = "json", message = "Herdr returned invalid JSON" })
      return
    end
    if decoded.error ~= nil and decoded.error ~= vim.NIL then
      callback(nil, {
        kind = "api",
        message = decoded.error.message or decoded.error.code or "Herdr API error",
        code = decoded.error.code,
      })
      return
    end
    if type(decoded.result) ~= "table" then
      callback(nil, { kind = "json", message = "Herdr response is missing result" })
      return
    end
    callback(decoded.result)
  end)
end

local function nullable(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

local function required_string(value, field, index)
  if type(value) ~= "string" or value == "" then
    return nil, string.format("agent %d is missing required field %s", index, field)
  end
  return value
end

local function normalize_agent(agent, index)
  if type(agent) ~= "table" then
    return nil, string.format("agent %d is not an object", index)
  end
  local terminal_id, err = required_string(agent.terminal_id, "terminal_id", index)
  if not terminal_id then
    return nil, err
  end
  local workspace_id
  workspace_id, err = required_string(agent.workspace_id, "workspace_id", index)
  if not workspace_id then
    return nil, err
  end
  local tab_id
  tab_id, err = required_string(agent.tab_id, "tab_id", index)
  if not tab_id then
    return nil, err
  end
  local pane_id
  pane_id, err = required_string(agent.pane_id, "pane_id", index)
  if not pane_id then
    return nil, err
  end
  if type(agent.agent_status) ~= "string" then
    return nil, string.format("agent %d is missing required field agent_status", index)
  end

  local status = valid_status[agent.agent_status] and agent.agent_status or "unknown"
  local registered_name = nullable(agent.name)
  local name = registered_name or nullable(agent.display_agent) or nullable(agent.agent) or terminal_id
  local kind = nullable(agent.agent) or nullable(agent.display_agent) or "agent"
  local title = nullable(agent.title) or nullable(agent.terminal_title_stripped) or nullable(agent.terminal_title) or ""

  return {
    terminal_id = terminal_id,
    workspace_id = workspace_id,
    tab_id = tab_id,
    pane_id = pane_id,
    status = status,
    focused = agent.focused == true,
    revision = type(agent.revision) == "number" and agent.revision or 0,
    name = tostring(name),
    registered_name = type(registered_name) == "string" and registered_name or nil,
    kind = tostring(kind),
    title = tostring(title),
    cwd = nullable(agent.foreground_cwd) or nullable(agent.cwd),
    target = pane_id,
  }
end

function M._normalize_snapshot(result)
  if type(result) ~= "table" or result.type ~= "session_snapshot" or type(result.snapshot) ~= "table" then
    return nil, { kind = "schema", message = "Herdr response is not a session snapshot" }
  end
  local source = result.snapshot
  if type(source.protocol) ~= "number" then
    return nil, { kind = "schema", message = "Herdr snapshot is missing protocol" }
  end
  if type(source.agents) ~= "table" or not vim.islist(source.agents) then
    return nil, { kind = "schema", message = "Herdr snapshot is missing agents" }
  end
  if type(source.workspaces) ~= "table" or not vim.islist(source.workspaces) then
    return nil, { kind = "schema", message = "Herdr snapshot is missing workspaces" }
  end

  local agents = {}
  for index, agent in ipairs(source.agents) do
    local normalized, message = normalize_agent(agent, index)
    if not normalized then
      return nil, { kind = "schema", message = message }
    end
    table.insert(agents, normalized)
  end

  local workspaces = {}
  for index, workspace in ipairs(source.workspaces) do
    if type(workspace) ~= "table" or type(workspace.workspace_id) ~= "string" or workspace.workspace_id == "" then
      return nil, { kind = "schema", message = string.format("workspace %d is missing workspace_id", index) }
    end
    table.insert(workspaces, {
      workspace_id = workspace.workspace_id,
      label = tostring(nullable(workspace.label) or workspace.workspace_id),
      focused = workspace.focused == true,
    })
  end

  local panes = {}
  for _, pane in ipairs(source.panes or {}) do
    if type(pane) == "table" and type(pane.pane_id) == "string" and type(pane.workspace_id) == "string" then
      table.insert(panes, {
        pane_id = pane.pane_id,
        workspace_id = pane.workspace_id,
        cwd = nullable(pane.foreground_cwd) or nullable(pane.cwd),
      })
    end
  end

  return {
    agents = agents,
    workspaces = workspaces,
    panes = panes,
    version = source.version,
    protocol = source.protocol,
    focused_workspace_id = source.focused_workspace_id,
  }
end

function M.snapshot(callback)
  run_json({ "api", "snapshot" }, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    local snapshot, normalize_err = M._normalize_snapshot(result)
    callback(snapshot, normalize_err)
  end)
end

local function normalized_path(path)
  if not path then
    return nil
  end
  local expanded = vim.fn.fnamemodify(path, ":p")
  expanded = expanded:gsub("/$", "")
  return vim.fs.normalize(expanded)
end

local function project_path(path)
  for _, marker in ipairs({ ".git" }) do
    local ok, root = pcall(vim.fs.root, path, marker)
    if ok and root then
      return normalized_path(root)
    end
  end
  return normalized_path(path)
end

local function workspace_for_cwd(snapshot, cwd)
  local expected = project_path(cwd)
  for _, pane in ipairs(snapshot.panes or {}) do
    if pane.cwd and project_path(pane.cwd) == expected then
      return pane.workspace_id
    end
  end
  for _, agent in ipairs(snapshot.agents or {}) do
    if agent.cwd and project_path(agent.cwd) == expected then
      return agent.workspace_id
    end
  end
  return nil
end

local function create_agent_pane(cwd, label, callback)
  M.snapshot(function(snapshot, snapshot_err)
    if snapshot_err then
      callback(nil, snapshot_err)
      return
    end
    for _, agent in ipairs(snapshot.agents or {}) do
      if agent.registered_name == label then
        callback(nil, {
          kind = "validation",
          message = string.format("agent name %q is already in use; attach to it or choose another name", label),
        })
        return
      end
    end
    local workspace_id = workspace_for_cwd(snapshot, cwd)
    local args
    local resource_kind
    if workspace_id then
      resource_kind = "tab"
      args = { "tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", label, "--no-focus" }
    else
      resource_kind = "workspace"
      args = { "workspace", "create", "--cwd", cwd, "--label", vim.fn.fnamemodify(cwd, ":t"), "--no-focus" }
    end
    run_json(args, function(result, err)
      if err then
        callback(nil, err)
        return
      end
      local pane_id = result.root_pane and result.root_pane.pane_id
      if type(pane_id) ~= "string" or pane_id == "" then
        callback(nil, { kind = "schema", message = "Herdr did not return the new root pane" })
        return
      end
      local resource = resource_kind == "tab" and result.tab or result.workspace
      callback({
        pane_id = pane_id,
        resource_kind = resource_kind,
        resource_id = resource and (resource.tab_id or resource.workspace_id) or nil,
      })
    end)
  end)
end

local function launch_agent(kind, name, cwd, agent_args, callback)
  if not config.get().agents[kind] then
    callback(nil, { kind = "config", message = "unknown agent kind: " .. tostring(kind) })
    return
  end
  local _, name_err = M.validate_agent_name(name)
  if name_err then
    callback(nil, name_err)
    return
  end
  create_agent_pane(cwd, name, function(allocation, pane_err)
    if pane_err then
      callback(nil, pane_err)
      return
    end
    local start_timeout = config.get().agent_start_timeout_ms
    local args = {
      "agent",
      "start",
      name,
      "--kind",
      kind,
      "--pane",
      allocation.pane_id,
      "--timeout",
      tostring(start_timeout),
    }
    if #agent_args > 0 then
      table.insert(args, "--")
      vim.list_extend(args, agent_args)
    end
    local retry_index = 1
    local function start_in_allocated_pane()
      run_json(args, { timeout_ms = start_timeout + 5000 }, function(result, err)
        local retryable = err and (err.code == "agent_pane_busy" or err.api_code == "agent_pane_busy")
        if retryable and retry_index <= #agent_shell_retry_ms then
          local delay = agent_shell_retry_ms[retry_index]
          retry_index = retry_index + 1
          defer(start_in_allocated_pane, delay)
          return
        end
        if err then
          err.recovery = allocation
          err.message = string.format(
            "%s; Herdr kept the new %s%s at pane %s for inspection",
            err.message,
            allocation.resource_kind,
            allocation.resource_id and " " .. allocation.resource_id or "",
            allocation.pane_id
          )
          callback(nil, err)
          return
        end
        local started_agent
        if type(result.agent) == "table" then
          started_agent = normalize_agent(result.agent, 1)
        end
        callback(result, nil, allocation, started_agent)
      end)
    end
    start_in_allocated_pane()
  end)
end

function M.start_agent(kind, name, cwd, callback)
  local preset = config.get().agents[kind]
  launch_agent(kind, name, cwd, vim.deepcopy((preset and preset.args) or {}), callback)
end

function M.resume_agent(kind, name, cwd, callback)
  local resume_args = {
    claude = { "--resume" },
    codex = { "resume" },
  }
  if not resume_args[kind] then
    callback(nil, { kind = "config", message = "resume is not supported for agent kind: " .. tostring(kind) })
    return
  end
  local preset = config.get().agents[kind]
  local agent_args = vim.deepcopy((preset and preset.args) or {})
  vim.list_extend(agent_args, resume_args[kind])
  launch_agent(kind, name, cwd, agent_args, callback)
end

function M.prompt(target, text, callback)
  run_json({ "agent", "prompt", target, text }, callback)
end

function M.prompt_until_working(target, text, callback)
  run_json(
    { "agent", "prompt", target, text, "--wait", "--until", "working", "--timeout", "6000" },
    { timeout_ms = 8000 },
    callback
  )
end

function M.rename(target, name, callback)
  local _, name_err = M.validate_agent_name(name)
  if name_err then
    callback(nil, name_err)
    return
  end
  run_json({ "agent", "rename", target, name }, callback)
end

function M.explain(target, callback)
  run({ "agent", "explain", target, "--format", "text" }, {}, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    callback(result.stdout or "")
  end)
end

function M.read(target, lines, callback)
  local function finish(result, err)
    if err then
      callback(nil, err)
      return
    end
    callback(result.stdout or "")
  end

  run(
    { "agent", "read", target, "--source", "recent-unwrapped", "--lines", tostring(lines), "--format", "text" },
    {},
    function(result, err)
      if err and (err.code == "agent_not_idle" or err.api_code == "agent_not_idle") then
        run({ "agent", "read", target, "--source", "visible", "--format", "text" }, {}, finish)
        return
      end
      finish(result, err)
    end
  )
end

function M.attach(target, takeover, opts)
  local args = { "agent", "attach", target }
  if takeover then
    table.insert(args, "--takeover")
  end
  local ok, job_id = pcall(termopen or vim.fn.termopen, executable_argv(args), opts or {})
  if not ok then
    return nil, { kind = "process", message = tostring(job_id) }
  end
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, { kind = "process", message = "failed to start Herdr attach terminal" }
  end
  return job_id
end

function M.integration_status(callback)
  run({ "integration", "status" }, {}, function(result, err)
    callback(result and result.stdout or nil, err)
  end)
end

local function finish_server_check(ok, err)
  server_checking = false
  server_ready = ok == true
  local waiters = server_waiters
  server_waiters = {}
  for _, callback in ipairs(waiters) do
    callback(server_ready, err)
  end
end

local function check_server(callback)
  run({ "status", "server" }, {}, function(result, err)
    if err then
      callback(false, err)
      return
    end
    local output = result.stdout or ""
    if output:match("status:%s*not running") then
      callback(false, { kind = "server", message = "Herdr server is not running" })
      return
    end
    local protocol = tonumber(output:match("protocol:%s*(%d+)"))
    if not protocol or not output:match("compatible:%s*yes") then
      callback(false, {
        kind = "protocol",
        message = "Herdr did not report a compatible protocol; update Herdr and run :checkhealth signalbox",
      })
      return
    end
    callback(true)
  end)
end

local function retry_server(index, last_err)
  local delays = config.get().server_retry_ms
  if index > #delays then
    finish_server_check(false, {
      kind = "server",
      message = "Herdr server did not become ready: " .. (last_err and last_err.message or "no response"),
      cause = last_err,
    })
    return
  end
  defer(function()
    check_server(function(ok, err)
      if ok then
        finish_server_check(true)
      elseif err and (err.kind == "executable" or err.kind == "protocol") then
        finish_server_check(false, err)
      else
        retry_server(index + 1, err)
      end
    end)
  end, delays[index])
end

function M.ensure_server(callback)
  if server_ready then
    callback(true)
    return
  end
  table.insert(server_waiters, callback)
  if server_checking then
    return
  end
  server_checking = true
  check_server(function(ok, err)
    if ok then
      finish_server_check(true)
      return
    end
    if not config.get().auto_start_server or (err and (err.kind == "executable" or err.kind == "protocol")) then
      finish_server_check(false, err)
      return
    end
    local start_job = job_starter or default_job_starter
    local job_id, start_err = start_job(executable_argv({ "server" }))
    if type(job_id) ~= "number" or job_id <= 0 then
      finish_server_check(false, {
        kind = "server",
        message = "failed to start detached Herdr server" .. (start_err and ": " .. start_err or ""),
      })
      return
    end
    retry_server(1, err)
  end)
end

function M.mark_server_unavailable()
  server_ready = false
end

function M._set_runner(value)
  runner = value
end

function M._set_job_starter(value)
  job_starter = value
end

function M._set_termopen(value)
  termopen = value
end

function M._set_defer(value)
  defer = value or vim.defer_fn
end

function M._reset()
  runner = nil
  job_starter = nil
  termopen = nil
  defer = vim.defer_fn
  server_ready = false
  server_checking = false
  server_waiters = {}
end

return M
