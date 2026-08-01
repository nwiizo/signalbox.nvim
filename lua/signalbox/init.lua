local M = {}

local initialized = false
local cleanup_group
local lifecycle_generation = 0

local function message(err)
  if type(err) == "table" then
    return err.message or err.kind or vim.inspect(err)
  end
  return tostring(err)
end

local function notify_error(err)
  vim.notify(message(err), vim.log.levels.ERROR, { title = "Signalbox" })
end

local function ensure_setup()
  if not initialized then
    M.setup()
  end
end

local function configured_agent_kinds()
  local agents = require("signalbox.config").get().agents
  local result = {}
  for _, preferred in ipairs({ "codex", "claude" }) do
    if agents[preferred] then
      table.insert(result, preferred)
    end
  end
  local rest = {}
  for kind in pairs(agents) do
    if kind ~= "codex" and kind ~= "claude" then
      table.insert(rest, kind)
    end
  end
  table.sort(rest)
  vim.list_extend(result, rest)
  return result
end

local function with_agent_kind(kind, callback)
  if kind and kind ~= "" then
    callback(kind)
    return
  end
  local kinds = configured_agent_kinds()
  vim.ui.select(kinds, { prompt = "Start agent:" }, callback)
end

local function find_agent(target)
  local matches = {}
  for _, agent in ipairs(require("signalbox.state").agents()) do
    if target == agent.terminal_id or target == agent.pane_id then
      return agent
    end
    if target == agent.name then
      table.insert(matches, agent)
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    local ids = vim.tbl_map(function(agent)
      return agent.terminal_id
    end, matches)
    return nil, string.format("agent name %q is ambiguous; use a terminal ID: %s", target, table.concat(ids, ", "))
  end
  return nil, string.format("unknown Herdr agent %q; run :SignalboxRefresh", target)
end

local function with_target(target, callback)
  local state = require("signalbox.state")
  state.ensure_snapshot(function(ok, snapshot_err)
    if not ok then
      notify_error(snapshot_err)
      return
    end
    if target and target ~= "" then
      local agent, err = find_agent(target)
      if not agent then
        notify_error(err)
        return
      end
      callback(agent)
      return
    end
    local agents = state.agents()
    if #agents == 0 then
      notify_error("no Herdr agents; run :SignalboxStart codex or :SignalboxStart claude")
    elseif #agents == 1 then
      callback(agents[1])
    else
      vim.ui.select(agents, {
        prompt = "Signalbox agent:",
        format_item = function(agent)
          return string.format("%-12s %-8s %s  [%s]", agent.name, agent.status, agent.cwd or "", agent.terminal_id)
        end,
      }, callback)
    end
  end)
end

local function with_server(callback)
  require("signalbox.client").ensure_server(function(ok, err)
    if not ok then
      notify_error(err)
      return
    end
    callback()
  end)
end

function M.setup(opts)
  require("signalbox.config").setup(opts)
  if initialized then
    require("signalbox.state").stop()
  end
  lifecycle_generation = lifecycle_generation + 1
  local setup_generation = lifecycle_generation
  require("signalbox.client").mark_server_unavailable()
  require("signalbox.board").setup()
  require("signalbox.notifier")._reset()
  initialized = true

  cleanup_group = vim.api.nvim_create_augroup("SignalboxCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = cleanup_group,
    callback = function()
      require("signalbox.state").stop()
      require("signalbox.terminal").cleanup()
    end,
  })
  vim.schedule(function()
    if initialized and lifecycle_generation == setup_generation then
      require("signalbox.state").start()
    end
  end)
  return M
end

function M.toggle()
  ensure_setup()
  require("signalbox.board").toggle()
end

function M.refresh()
  ensure_setup()
  require("signalbox.state").refresh({ explicit = true }, function(ok, result)
    if not ok then
      notify_error(result)
    end
  end)
end

function M.start(kind, opts)
  ensure_setup()
  opts = opts or {}
  with_agent_kind(kind, function(selected_kind)
    if not selected_kind then
      return
    end
    if not require("signalbox.config").get().agents[selected_kind] then
      notify_error("unknown agent kind: " .. selected_kind)
      return
    end
    local context = require("signalbox.context")
    local cwd = opts.cwd or context.project_root(0)
    local project = vim.fn.fnamemodify(cwd, ":t")
    local default_name = string.format("%s-%s", selected_kind, project ~= "" and project or "agent")
    vim.ui.input({ prompt = "Agent name: ", default = opts.name or default_name }, function(name)
      if not name or name == "" then
        return
      end
      with_server(function()
        require("signalbox.client").start_agent(selected_kind, name, cwd, function(_, err)
          if err then
            notify_error(err)
            return
          end
          vim.notify(
            string.format("started %s agent %s", selected_kind, name),
            vim.log.levels.INFO,
            { title = "Signalbox" }
          )
          require("signalbox.state").refresh({ explicit = true })
        end)
      end)
    end)
  end)
end

function M.attach(target, opts)
  ensure_setup()
  opts = opts or {}
  with_target(target, function(agent)
    if not agent then
      return
    end
    with_server(function()
      require("signalbox.terminal").attach(agent, opts)
    end)
  end)
end

local function prompt_agent(agent, text)
  if not text or text == "" then
    return
  end
  if #text > require("signalbox.config").get().context.max_bytes then
    notify_error("instruction exceeds context.max_bytes")
    return
  end
  with_server(function()
    require("signalbox.client").prompt(agent.target, text, function(_, err)
      if err then
        notify_error(err)
        return
      end
      vim.notify("prompted " .. agent.name, vim.log.levels.INFO, { title = "Signalbox" })
    end)
  end)
end

local function prompt_text(target, text)
  if not text or text == "" then
    return
  end
  with_target(target, function(agent)
    prompt_agent(agent, text)
  end)
end

local function concrete_buffer(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function send_frozen_context(target, builder)
  local text, err = builder()
  if not text then
    local level = err == "buffer has no diagnostics" and vim.log.levels.INFO or vim.log.levels.ERROR
    vim.notify(err, level, { title = "Signalbox" })
    return
  end
  prompt_text(target, text)
end

function M.prompt(target, text)
  ensure_setup()
  if text ~= nil then
    prompt_text(target, text)
    return
  end
  vim.ui.input({ prompt = "Instruction: " }, function(input)
    prompt_text(target, input)
  end)
end

function M._send_range(target, bufnr, line1, line2)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function()
    return require("signalbox.context").range(captured_buffer, line1, line2, { target_cwd = false })
  end)
end

function M._send_visual(target, bufnr, line1, line2)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function()
    return require("signalbox.context").range_from_marks(captured_buffer, line1, line2, { target_cwd = false })
  end)
end

function M._send_file(target, bufnr)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function()
    return require("signalbox.context").file(captured_buffer, { target_cwd = false })
  end)
end

function M._send_diagnostics(target, bufnr)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function()
    return require("signalbox.context").diagnostics(captured_buffer, { target_cwd = false })
  end)
end

function M.statusline()
  local ok, result = pcall(function()
    if not initialized then
      return ""
    end
    local configured = require("signalbox.config").get()
    if vim.fn.executable(configured.herdr_cmd) ~= 1 then
      return ""
    end
    local status = require("signalbox.state").get()
    if not status.snapshot then
      return ""
    end
    local counts = require("signalbox.state").counts()
    local parts = {}
    for _, key in ipairs({ "blocked", "done" }) do
      if counts[key] > 0 then
        table.insert(parts, configured.board.markers[key] .. counts[key])
      end
    end
    if status.stale then
      table.insert(parts, "~")
    end
    return #parts > 0 and "SB " .. table.concat(parts, " ") or ""
  end)
  return ok and result or ""
end

M.send = M.prompt

function M._complete_agents()
  local result = {}
  for _, agent in ipairs(require("signalbox.state").agents()) do
    table.insert(result, agent.terminal_id)
  end
  return result
end

function M._find_agent(target)
  return find_agent(target)
end

function M._complete_agent_kinds()
  ensure_setup()
  return configured_agent_kinds()
end

function M._reset()
  lifecycle_generation = lifecycle_generation + 1
  initialized = false
  if cleanup_group then
    pcall(vim.api.nvim_del_augroup_by_id, cleanup_group)
  end
  cleanup_group = nil
end

return M
