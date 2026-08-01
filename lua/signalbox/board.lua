local config = require("signalbox.config")
local state = require("signalbox.state")

local M = {}

local list_buffer
local list_window
local preview_buffer
local preview_window
local line_agents = {}
local help_visible = false
local show_all = false
local preview_enabled = true
local preview_generation = 0
local closing_windows = false
local origin_root
local augroup
local namespace = vim.api.nvim_create_namespace("signalbox-board")

local highlight_for = {
  blocked = "SignalboxBlocked",
  working = "SignalboxWorking",
  done = "SignalboxDone",
  idle = "SignalboxIdle",
  unknown = "SignalboxUnknown",
}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

function M.is_open()
  return valid_window(list_window)
end

local function dimension(value, total, minimum)
  local size = value < 1 and math.floor(total * value) or value
  return math.max(minimum, math.min(size, total - 4))
end

local function geometry()
  local board = config.get().board
  local total_width = dimension(board.width, vim.o.columns, 44)
  local height = dimension(board.height, vim.o.lines - vim.o.cmdheight, 10)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  if not preview_enabled then
    return { row = row, col = col, height = height, list_width = total_width }
  end
  local preview_width = math.floor((total_width - 2) * board.preview_ratio)
  return {
    row = row,
    col = col,
    height = height,
    list_width = total_width - preview_width - 2,
    preview_col = col + total_width - preview_width,
    preview_width = preview_width,
  }
end

local function truncate(value, width)
  value = tostring(value or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  local result = ""
  for index = 0, vim.fn.strchars(value) - 1 do
    local candidate = result .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(candidate .. "…") > width then
      break
    end
    result = candidate
  end
  return result .. "…"
end

local function pad(value, width)
  local result = truncate(value, width)
  return result .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(result)))
end

local function summary()
  local counts = state.counts()
  local markers = config.get().board.markers
  local parts = { "Signalbox" }
  for _, key in ipairs({ "blocked", "working", "done" }) do
    if counts[key] > 0 then
      table.insert(parts, markers[key] .. counts[key])
    end
  end
  if state.get().stale then
    table.insert(parts, "~stale")
  end
  return table.concat(parts, "  ")
end

local function selected_agent()
  if not M.is_open() then
    return nil
  end
  return line_agents[vim.api.nvim_win_get_cursor(list_window)[1]]
end

local function selected_id()
  local agent = selected_agent()
  return agent and agent.terminal_id or nil
end

local function set_lines(buffer, lines)
  if not valid_buffer(buffer) then
    return
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
end

local function preview_message(lines)
  set_lines(preview_buffer, lines)
end

function M.refresh_preview()
  if not preview_enabled or not valid_window(preview_window) then
    return
  end
  local agent = selected_agent()
  preview_generation = preview_generation + 1
  local generation = preview_generation
  if not agent then
    preview_message({
      "Select an agent to inspect its recent output.",
      "",
      "The preview is ephemeral and is never written to disk.",
    })
    return
  end
  preview_message({ string.format("Reading %s…", agent.name) })
  require("signalbox.client").read(agent.target, config.get().board.preview_lines, function(output, err)
    if generation ~= preview_generation or not valid_buffer(preview_buffer) then
      return
    end
    if err then
      preview_message({ "Preview unavailable", "", err.message or err.kind or tostring(err) })
      return
    end
    local lines = vim.split((output or ""):gsub("%s+$", ""), "\n", { plain = true })
    if #lines == 1 and lines[1] == "" then
      lines = { "No terminal output yet." }
    end
    set_lines(preview_buffer, lines)
    if valid_window(preview_window) then
      pcall(vim.api.nvim_win_set_config, preview_window, { title = " " .. agent.name .. " · recent output " })
    end
  end)
end

local function render_guidance(lines, err)
  if err.kind == "executable" then
    table.insert(lines, "Install Herdr: https://herdr.dev/")
    table.insert(lines, "Run :checkhealth signalbox")
  elseif err.kind == "server" then
    table.insert(lines, "Run: " .. config.get().herdr_cmd .. " server")
    table.insert(lines, "Press r to retry")
  elseif err.kind == "protocol" then
    table.insert(lines, "Update Herdr, then run :SignalboxHealth")
  else
    table.insert(lines, "Press r to retry; run :SignalboxHealth")
  end
end

function M.render()
  if not valid_buffer(list_buffer) then
    return
  end
  local selected = selected_id()
  local status = state.get()
  local width = valid_window(list_window) and vim.api.nvim_win_get_width(list_window) or 44
  local view_label = show_all and "all agents" or "this project + attention elsewhere"
  local lines = { " " .. view_label, "" }
  local highlights = {}
  line_agents = {}

  if not status.snapshot then
    if status.error then
      table.insert(lines, "Herdr unavailable")
      table.insert(lines, truncate(status.error.message or "unknown error", width - 2))
      render_guidance(lines, status.error)
    else
      table.insert(lines, "Loading Herdr agents…")
    end
  else
    if status.stale and status.error then
      table.insert(lines, truncate("Last refresh failed: " .. (status.error.message or status.error.kind), width - 2))
      table.insert(lines, "")
    end
    local groups = state.grouped_agents({ root = origin_root, all = show_all })
    if #groups == 0 then
      table.insert(lines, "No matching agents. Press a to start one.")
    end
    for _, group in ipairs(groups) do
      table.insert(lines, truncate(group.label, width - 2))
      for _, agent in ipairs(group.agents) do
        local marker = config.get().board.markers[agent.status]
        local line = string.format(" %s %s %s %s", marker, pad(agent.name, 15), pad(agent.kind, 7), agent.status)
        table.insert(lines, truncate(line, width - 1))
        line_agents[#lines] = agent
        highlights[#lines] = highlight_for[agent.status]
      end
      table.insert(lines, "")
    end
  end

  if help_visible then
    vim.list_extend(lines, {
      "",
      "<CR> attach   p prompt   a start",
      "g lazygit    d diff      v preview",
      "A all/view   r refresh   q close   ? help",
    })
  end

  set_lines(list_buffer, lines)
  vim.api.nvim_buf_clear_namespace(list_buffer, namespace, 0, -1)
  for line, group in pairs(highlights) do
    vim.api.nvim_buf_add_highlight(list_buffer, namespace, group, line - 1, 0, -1)
  end

  if valid_window(list_window) then
    pcall(vim.api.nvim_win_set_config, list_window, { title = " " .. summary() .. " " })
    local target_line
    if selected then
      for line, agent in pairs(line_agents) do
        if agent.terminal_id == selected then
          target_line = line
          break
        end
      end
    end
    if not target_line then
      for line = 1, #lines do
        if line_agents[line] then
          target_line = line
          break
        end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, list_window, { target_line or 1, 0 })
  end
  vim.schedule(M.refresh_preview)
end

local function map(lhs, callback, description)
  vim.keymap.set("n", lhs, callback, { buffer = list_buffer, silent = true, nowait = true, desc = description })
end

local function require_agent_row()
  local agent = selected_agent()
  if not agent then
    vim.notify("Select an agent row first", vim.log.levels.INFO, { title = "Signalbox" })
  end
  return agent
end

local function configure_list_buffer()
  vim.bo[list_buffer].buftype = "nofile"
  vim.bo[list_buffer].bufhidden = "hide"
  vim.bo[list_buffer].swapfile = false
  vim.bo[list_buffer].modifiable = false
  vim.bo[list_buffer].filetype = "signalbox"
  vim.bo[list_buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, list_buffer, "signalbox://board")

  map("<CR>", function()
    local agent = require_agent_row()
    if agent then
      M.close()
      require("signalbox").attach(agent.terminal_id)
    end
  end, "Attach to agent")
  map("p", function()
    local agent = require_agent_row()
    if agent then
      require("signalbox").prompt(agent.terminal_id)
    end
  end, "Prompt agent")
  map("s", function()
    local agent = require_agent_row()
    if agent then
      require("signalbox").prompt(agent.terminal_id)
    end
  end, "Prompt agent")
  map("a", function()
    require("signalbox").start(nil, { cwd = origin_root })
  end, "Start agent")
  map("g", function()
    local agent = selected_agent()
    M.close()
    require("signalbox.actions").lazygit(agent, origin_root)
  end, "Open Lazygit")
  map("d", function()
    local agent = selected_agent()
    M.close()
    require("signalbox.actions").diffview(agent, origin_root)
  end, "Open Diffview")
  map("v", function()
    preview_enabled = not preview_enabled
    M._reopen_windows()
  end, "Toggle preview")
  map("A", function()
    show_all = not show_all
    M.render()
  end, "Toggle all agents")
  map("r", function()
    require("signalbox").refresh()
  end, "Refresh agents")
  map("q", M.close, "Close Signalbox")
  map("?", function()
    help_visible = not help_visible
    M.render()
  end, "Toggle help")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = list_buffer,
    callback = function()
      vim.schedule(M.refresh_preview)
    end,
  })
end

local function configure_preview_buffer()
  vim.bo[preview_buffer].buftype = "nofile"
  vim.bo[preview_buffer].bufhidden = "hide"
  vim.bo[preview_buffer].swapfile = false
  vim.bo[preview_buffer].modifiable = false
  vim.bo[preview_buffer].filetype = "signalbox-preview"
  vim.bo[preview_buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, preview_buffer, "signalbox://preview")
end

local function open_windows()
  local layout = geometry()
  list_window = vim.api.nvim_open_win(list_buffer, true, {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.list_width,
    height = layout.height,
    style = "minimal",
    border = "rounded",
    title = " " .. summary() .. " ",
    title_pos = "center",
    zindex = 50,
  })
  vim.wo[list_window].wrap = false
  vim.wo[list_window].cursorline = true
  vim.wo[list_window].signcolumn = "no"

  if preview_enabled then
    preview_window = vim.api.nvim_open_win(preview_buffer, false, {
      relative = "editor",
      row = layout.row,
      col = layout.preview_col,
      width = layout.preview_width,
      height = layout.height,
      style = "minimal",
      border = "rounded",
      title = " recent output ",
      title_pos = "center",
      zindex = 50,
    })
    vim.wo[preview_window].wrap = true
    vim.wo[preview_window].signcolumn = "no"
  else
    preview_window = nil
  end
end

function M._reopen_windows()
  if not M.is_open() then
    return
  end
  closing_windows = true
  if valid_window(preview_window) then
    vim.api.nvim_win_close(preview_window, true)
  end
  if valid_window(list_window) then
    vim.api.nvim_win_close(list_window, true)
  end
  list_window = nil
  preview_window = nil
  open_windows()
  closing_windows = false
  M.render()
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(list_window)
    return
  end
  origin_root = require("signalbox.context").project_root(0)
  preview_enabled = config.get().board.preview
  if not valid_buffer(list_buffer) then
    list_buffer = vim.api.nvim_create_buf(false, true)
    configure_list_buffer()
  end
  if not valid_buffer(preview_buffer) then
    preview_buffer = vim.api.nvim_create_buf(false, true)
    configure_preview_buffer()
  end
  open_windows()
  state.set_board_visible(true)
  M.render()
end

function M.close()
  preview_generation = preview_generation + 1
  closing_windows = true
  if valid_window(preview_window) then
    vim.api.nvim_win_close(preview_window, true)
  end
  if valid_window(list_window) then
    vim.api.nvim_win_close(list_window, true)
  end
  list_window = nil
  preview_window = nil
  closing_windows = false
  state.set_board_visible(false)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.setup()
  vim.api.nvim_set_hl(0, "SignalboxBlocked", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "SignalboxWorking", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "SignalboxDone", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "SignalboxIdle", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "SignalboxUnknown", { default = true, link = "DiagnosticWarn" })
  augroup = vim.api.nvim_create_augroup("SignalboxBoard", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SignalboxUpdated",
    callback = function()
      if M.is_open() then
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if M.is_open() then
        M._reopen_windows()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closing_windows or (closed ~= list_window and closed ~= preview_window) then
        return
      end
      vim.schedule(function()
        if not closing_windows and (list_window ~= nil or preview_window ~= nil) then
          M.close()
        end
      end)
    end,
  })
end

function M._buffer()
  return list_buffer
end

function M._preview_buffer()
  return preview_buffer
end

function M._line_agents()
  return line_agents
end

function M._reset()
  M.close()
  for _, buffer in ipairs({ list_buffer, preview_buffer }) do
    if valid_buffer(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  list_buffer = nil
  preview_buffer = nil
  line_agents = {}
  help_visible = false
  show_all = false
  preview_enabled = true
  closing_windows = false
  origin_root = nil
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = nil
end

return M
