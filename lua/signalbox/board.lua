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
local preview_mode = "output"
local preview_generation = 0
local preview_target
local preview_in_flight
local preview_last_read = 0
local preview_cache = {}
local closing_windows = false
local origin_root
local augroup
local namespace = vim.api.nvim_create_namespace("signalbox-board")
-- Stay below Snacks layout 30, picker preview 40, and the default modal layer 50.
local board_zindex = 25

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

function M.is_visible()
  return M.is_open() and vim.api.nvim_win_get_tabpage(list_window) == vim.api.nvim_get_current_tabpage()
end

local function dimension(value, total, minimum)
  local size = value < 1 and math.floor(total * value) or value
  return math.min(math.max(minimum, size), math.max(1, total - 4))
end

local function geometry()
  local board = config.get().board
  local total_width = dimension(board.width, vim.o.columns, 68)
  local height = dimension(board.height, vim.o.lines - vim.o.cmdheight, 10)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  if not preview_enabled then
    return { row = row, col = col, height = height, list_width = total_width }
  end
  local usable_width = total_width - 2
  local minimum_list_width = math.min(36, math.max(24, math.floor(usable_width * 0.6)))
  local maximum_preview_width = math.max(16, usable_width - minimum_list_width)
  local preview_width = math.min(math.floor(usable_width * board.preview_ratio), maximum_preview_width)
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

local function agent_line(agent, marker, width)
  if width >= 35 then
    return string.format(" %s %s %s %s", marker, pad(agent.name, 15), pad(agent.kind, 7), agent.status)
  end
  local status_width = vim.fn.strdisplaywidth(agent.status)
  local name_width = math.max(6, width - status_width - 5)
  return string.format(" %s %s %s", marker, pad(agent.name, name_width), agent.status)
end

local function summary_title()
  local counts = state.counts()
  local markers = config.get().board.markers
  local parts = { { " Signalbox ", "SignalboxTitle" } }
  for _, key in ipairs({ "blocked", "working", "done" }) do
    if counts[key] > 0 then
      table.insert(parts, { " " .. markers[key] .. counts[key] .. " ", highlight_for[key] })
    end
  end
  if state.get().stale then
    table.insert(parts, { " ~stale ", "SignalboxUnknown" })
  end
  return parts
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
    return false
  end
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), lines) then
    return false
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  return true
end

local function preview_message(lines)
  return set_lines(preview_buffer, lines)
end

local function set_title(window, title)
  if not valid_window(window) or vim.deep_equal(vim.api.nvim_win_get_config(window).title, title) then
    return
  end
  pcall(vim.api.nvim_win_set_config, window, { title = title })
end

local function preview_title(agent, suffix_group)
  local hint = preview_mode == "explain" and "· detection · e output · i attach "
    or "· read-only · e explain · i attach "
  return {
    { " " .. agent.name .. " ", highlight_for[agent.status] },
    { hint, suffix_group or "SignalboxMuted" },
  }
end

local function empty_preview_title()
  return { { " read-only · select agent · i attach ", "SignalboxMuted" } }
end

function M.refresh_preview(opts)
  opts = opts or {}
  if not preview_enabled or not valid_window(preview_window) then
    return
  end
  local agent = selected_agent()
  if not agent then
    if preview_target ~= false then
      preview_generation = preview_generation + 1
      preview_target = false
      preview_in_flight = nil
      preview_message({
        "Select an agent to inspect its recent output.",
        "",
        "This preview is read-only. Press i or <CR> to attach and type.",
        "Its contents are ephemeral and are never written to disk.",
      })
      set_title(preview_window, empty_preview_title())
    end
    return
  end
  local target = agent.terminal_id
  local cache_key = preview_mode .. ":" .. target
  local changed = preview_target ~= cache_key
  local now = vim.uv.now()
  local throttle_ms = math.max(500, config.get().refresh.board_ms)
  if preview_in_flight == cache_key or (not changed and not opts.force and now - preview_last_read < throttle_ms) then
    return
  end

  preview_target = cache_key
  preview_in_flight = cache_key
  preview_last_read = now
  preview_generation = preview_generation + 1
  local generation = preview_generation
  if changed then
    local cached = preview_cache[cache_key]
    local pending = preview_mode == "explain" and string.format("Explaining %s state…", agent.name)
      or string.format("Reading %s…", agent.name)
    preview_message(cached or { pending })
    set_title(preview_window, preview_title(agent))
  end
  local callback = function(output, err)
    if generation ~= preview_generation or not valid_buffer(preview_buffer) then
      return
    end
    preview_in_flight = nil
    if err then
      if not preview_cache[cache_key] then
        local label = preview_mode == "explain" and "Explanation unavailable" or "Preview unavailable"
        preview_message({ label, "", err.message or err.kind or tostring(err) })
      end
      set_title(preview_window, preview_title(agent, "SignalboxUnknown"))
      return
    end
    local lines = vim.split((output or ""):gsub("%s+$", ""), "\n", { plain = true })
    if #lines == 1 and lines[1] == "" then
      lines = { preview_mode == "explain" and "Herdr returned no detection explanation." or "No terminal output yet." }
    end
    preview_cache[cache_key] = lines
    set_lines(preview_buffer, lines)
    set_title(preview_window, preview_title(agent))
  end
  if preview_mode == "explain" then
    require("signalbox.client").explain(agent.target, callback)
  else
    require("signalbox.client").read(agent.target, config.get().board.preview_lines, callback)
  end
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

local function help_lines(width)
  local lines
  if width < 28 then
    lines = {
      "<CR>/i attach",
      "p/s prompt",
      "a start",
      "R resume",
      "n rename",
      "e explain",
      "v preview",
      "g lazygit",
      "d diff",
      "A all/view",
      "r refresh",
      "q close",
      "? help",
      "Tab preview",
      config.get().terminal.return_key .. " return",
    }
  else
    lines = {
      "<CR>/i attach   p/s prompt",
      "a start         n rename",
      "R resume session",
      "e explain       v preview",
      "g lazygit       d diff",
      "A all/view      r refresh",
      "q close         ? help",
      "Tab focus preview",
      config.get().terminal.return_key .. " return from terminal",
    }
  end
  return vim.tbl_map(function(line)
    return truncate(line, math.max(1, width - 1))
  end, lines)
end

function M.render()
  if not valid_buffer(list_buffer) then
    return
  end
  local selected = selected_id()
  local status = state.get()
  local width = valid_window(list_window) and vim.api.nvim_win_get_width(list_window) or 44
  local view_label = show_all and "all agents" or "this project + attention elsewhere"
  local lines = { truncate(" " .. view_label, width - 1), "" }
  local highlights = { [1] = "SignalboxMuted" }
  line_agents = {}

  if not status.snapshot then
    if status.error then
      table.insert(lines, "Herdr unavailable")
      highlights[#lines] = "SignalboxBlocked"
      table.insert(lines, truncate(status.error.message or "unknown error", width - 2))
      render_guidance(lines, status.error)
    else
      table.insert(lines, "Loading Herdr agents…")
      highlights[#lines] = "SignalboxWorking"
    end
  else
    if status.stale and status.error then
      table.insert(lines, truncate("Last refresh failed: " .. (status.error.message or status.error.kind), width - 2))
      table.insert(lines, "")
    end
    local groups = state.grouped_agents({ root = origin_root, all = show_all })
    if not show_all then
      local visible = {}
      for _, group in ipairs(groups) do
        for _, agent in ipairs(group.agents) do
          visible[agent.terminal_id] = true
        end
      end
      local hidden_working = 0
      for _, agent in ipairs(state.agents()) do
        if agent.status == "working" and not visible[agent.terminal_id] then
          hidden_working = hidden_working + 1
        end
      end
      if hidden_working > 0 then
        lines[2] = truncate(string.format(" A: %d working elsewhere", hidden_working), width - 1)
        highlights[2] = "SignalboxWorking"
      end
    end
    if #groups == 0 then
      table.insert(lines, "No matching agents. Press a to start one.")
    end
    for _, group in ipairs(groups) do
      table.insert(lines, truncate(group.label, width - 2))
      highlights[#lines] = "SignalboxWorkspace"
      for _, agent in ipairs(group.agents) do
        local marker = config.get().board.markers[agent.status]
        local line = agent_line(agent, marker, width)
        table.insert(lines, truncate(line, width - 1))
        line_agents[#lines] = agent
        highlights[#lines] = highlight_for[agent.status]
      end
      table.insert(lines, "")
    end
  end

  if help_visible then
    local first_help_line = #lines + 2
    table.insert(lines, "")
    vim.list_extend(lines, help_lines(width))
    for line = first_help_line, #lines do
      highlights[line] = "SignalboxHelp"
    end
  end

  local contents_changed = set_lines(list_buffer, lines)
  if contents_changed then
    vim.api.nvim_buf_clear_namespace(list_buffer, namespace, 0, -1)
    for line, group in pairs(highlights) do
      vim.api.nvim_buf_add_highlight(list_buffer, namespace, group, line - 1, 0, -1)
    end
  end

  if valid_window(list_window) then
    set_title(list_window, summary_title())
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
    target_line = target_line or 1
    if vim.api.nvim_win_get_cursor(list_window)[1] ~= target_line then
      pcall(vim.api.nvim_win_set_cursor, list_window, { target_line, 0 })
    end
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

local function attach_selected()
  local agent = require_agent_row()
  if agent then
    M.close()
    require("signalbox").attach(agent.terminal_id)
  end
end

local function prompt_selected()
  local agent = require_agent_row()
  if agent then
    require("signalbox").prompt(agent.terminal_id)
  end
end

local function rename_selected()
  local agent = require_agent_row()
  if agent then
    require("signalbox").rename(agent.terminal_id)
  end
end

local function toggle_explanation()
  if not require_agent_row() then
    return
  end
  preview_mode = preview_mode == "explain" and "output" or "explain"
  preview_target = nil
  M.refresh_preview({ force = true })
end

local function configure_list_buffer()
  vim.bo[list_buffer].buftype = "nofile"
  vim.bo[list_buffer].bufhidden = "hide"
  vim.bo[list_buffer].swapfile = false
  vim.bo[list_buffer].modifiable = false
  vim.bo[list_buffer].filetype = "signalbox"
  vim.bo[list_buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, list_buffer, "signalbox://board")

  map("<CR>", attach_selected, "Attach to agent")
  map("i", attach_selected, "Attach and type in agent")
  map("p", prompt_selected, "Prompt agent")
  map("s", prompt_selected, "Prompt agent")
  map("n", rename_selected, "Rename agent")
  map("e", toggle_explanation, "Toggle agent state explanation")
  map("a", function()
    require("signalbox").start(nil, { cwd = origin_root })
  end, "Start agent")
  map("R", function()
    require("signalbox").resume(nil, { cwd = origin_root })
  end, "Resume conversation in Herdr")
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
  map("<Tab>", function()
    if valid_window(preview_window) then
      vim.api.nvim_set_current_win(preview_window)
    end
  end, "Focus read-only preview")

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
  local opts = { buffer = preview_buffer, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", attach_selected, vim.tbl_extend("force", opts, { desc = "Attach to agent" }))
  vim.keymap.set("n", "i", attach_selected, vim.tbl_extend("force", opts, { desc = "Attach and type in agent" }))
  vim.keymap.set("n", "p", prompt_selected, vim.tbl_extend("force", opts, { desc = "Prompt agent" }))
  vim.keymap.set("n", "s", prompt_selected, vim.tbl_extend("force", opts, { desc = "Prompt agent" }))
  vim.keymap.set("n", "n", rename_selected, vim.tbl_extend("force", opts, { desc = "Rename agent" }))
  vim.keymap.set(
    "n",
    "e",
    toggle_explanation,
    vim.tbl_extend("force", opts, { desc = "Toggle agent state explanation" })
  )
  vim.keymap.set("n", "a", function()
    require("signalbox").start(nil, { cwd = origin_root })
  end, vim.tbl_extend("force", opts, { desc = "Start agent" }))
  vim.keymap.set("n", "R", function()
    require("signalbox").resume(nil, { cwd = origin_root })
  end, vim.tbl_extend("force", opts, { desc = "Resume conversation in Herdr" }))
  vim.keymap.set("n", "g", function()
    local agent = selected_agent()
    M.close()
    require("signalbox.actions").lazygit(agent, origin_root)
  end, vim.tbl_extend("force", opts, { desc = "Open Lazygit" }))
  vim.keymap.set("n", "d", function()
    local agent = selected_agent()
    M.close()
    require("signalbox.actions").diffview(agent, origin_root)
  end, vim.tbl_extend("force", opts, { desc = "Open Diffview" }))
  vim.keymap.set("n", "v", function()
    preview_enabled = not preview_enabled
    M._reopen_windows()
  end, vim.tbl_extend("force", opts, { desc = "Toggle preview" }))
  vim.keymap.set("n", "A", function()
    show_all = not show_all
    M.render()
  end, vim.tbl_extend("force", opts, { desc = "Toggle all agents" }))
  vim.keymap.set("n", "r", function()
    require("signalbox").refresh()
  end, vim.tbl_extend("force", opts, { desc = "Refresh agents" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "Close Signalbox" }))
  vim.keymap.set("n", "?", function()
    help_visible = not help_visible
    M.render()
  end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))
  vim.keymap.set("n", "<Tab>", function()
    if valid_window(list_window) then
      vim.api.nvim_set_current_win(list_window)
    end
  end, vim.tbl_extend("force", opts, { desc = "Focus agent list" }))
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
    title = summary_title(),
    title_pos = "center",
    zindex = board_zindex,
  })
  vim.wo[list_window].wrap = false
  vim.wo[list_window].cursorline = true
  vim.wo[list_window].signcolumn = "no"
  vim.wo[list_window].winhighlight = table.concat({
    "Normal:NormalFloat",
    "FloatBorder:SignalboxBorder",
    "FloatTitle:SignalboxTitle",
    "CursorLine:CursorLine",
  }, ",")

  if preview_enabled then
    preview_window = vim.api.nvim_open_win(preview_buffer, false, {
      relative = "editor",
      row = layout.row,
      col = layout.preview_col,
      width = layout.preview_width,
      height = layout.height,
      style = "minimal",
      border = "rounded",
      title = empty_preview_title(),
      title_pos = "center",
      zindex = board_zindex,
    })
    vim.wo[preview_window].wrap = true
    vim.wo[preview_window].signcolumn = "no"
    vim.wo[preview_window].winhighlight = table.concat({
      "Normal:NormalFloat",
      "FloatBorder:SignalboxBorder",
      "FloatTitle:SignalboxTitle",
    }, ",")
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
  preview_target = nil
  open_windows()
  closing_windows = false
  M.render()
end

function M._resize_windows()
  if not M.is_open() then
    return
  end
  local layout = geometry()
  vim.api.nvim_win_set_config(list_window, {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.list_width,
    height = layout.height,
  })
  if valid_window(preview_window) then
    vim.api.nvim_win_set_config(preview_window, {
      relative = "editor",
      row = layout.row,
      col = layout.preview_col,
      width = layout.preview_width,
      height = layout.height,
    })
  end
  M.render()
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(list_window)
    return
  end
  origin_root = require("signalbox.context").project_root(0)
  preview_enabled = config.get().board.preview
  preview_mode = "output"
  preview_target = nil
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
  preview_target = nil
  preview_in_flight = nil
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

local function apply_highlights()
  vim.api.nvim_set_hl(0, "SignalboxBlocked", { link = "ErrorMsg" })
  vim.api.nvim_set_hl(0, "SignalboxWorking", { link = "Function" })
  vim.api.nvim_set_hl(0, "SignalboxDone", { link = "String" })
  vim.api.nvim_set_hl(0, "SignalboxIdle", { link = "Comment" })
  vim.api.nvim_set_hl(0, "SignalboxUnknown", { link = "WarningMsg" })
  vim.api.nvim_set_hl(0, "SignalboxTitle", { link = "Title" })
  vim.api.nvim_set_hl(0, "SignalboxWorkspace", { link = "Function" })
  vim.api.nvim_set_hl(0, "SignalboxBorder", { link = "FloatBorder" })
  vim.api.nvim_set_hl(0, "SignalboxMuted", { link = "Comment" })
  vim.api.nvim_set_hl(0, "SignalboxHelp", { link = "Special" })
end

function M.setup()
  apply_highlights()
  augroup = vim.api.nvim_create_augroup("SignalboxBoard", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = apply_highlights,
  })
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
        M._resize_windows()
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
  preview_mode = "output"
  preview_target = nil
  preview_in_flight = nil
  preview_last_read = 0
  preview_cache = {}
  closing_windows = false
  origin_root = nil
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = nil
end

return M
