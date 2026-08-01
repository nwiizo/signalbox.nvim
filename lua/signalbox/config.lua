local M = {}

local defaults = {
  herdr_cmd = "herdr",
  auto_start_server = true,
  agent_start_timeout_ms = 30000,
  server_retry_ms = { 100, 300, 1000 },
  agents = {
    codex = { args = {} },
    claude = { args = {} },
  },
  refresh = {
    board_ms = 1000,
    background_ms = 5000,
    timeout_ms = 3000,
  },
  board = {
    width = 0.9,
    height = 0.9,
    preview = true,
    preview_ratio = 0.58,
    preview_lines = 80,
    markers = {
      blocked = "!",
      working = "*",
      done = "✓",
      idle = "·",
      unknown = "?",
    },
  },
  terminal = {
    side = "right",
    width = 0.4,
    auto_insert = true,
    return_key = "<C-g>",
  },
  notifications = {
    blocked = true,
    done = true,
  },
  context = {
    max_lines = 500,
    max_bytes = 65536,
  },
}

local values

local function fail(path, expected)
  error(string.format("signalbox.nvim: %s must be %s", path, expected), 3)
end

local function validate_string(value, path)
  if type(value) ~= "string" or value == "" then
    fail(path, "a non-empty string")
  end
end

local function validate_positive_integer(value, path)
  if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then
    fail(path, "a positive integer")
  end
end

local function validate_ratio_or_integer(value, path)
  if type(value) ~= "number" or value <= 0 then
    fail(path, "a positive number")
  end
  if value >= 1 and value % 1 ~= 0 then
    fail(path, "a fraction below 1 or an integer")
  end
end

local function validate_list(value, path)
  if type(value) ~= "table" or not vim.islist(value) then
    fail(path, "an argv list")
  end
  for index, item in ipairs(value) do
    validate_string(item, string.format("%s[%d]", path, index))
  end
end

local function validate(config)
  if type(config) ~= "table" then
    fail("setup options", "a table")
  end
  validate_string(config.herdr_cmd, "herdr_cmd")
  if type(config.auto_start_server) ~= "boolean" then
    fail("auto_start_server", "a boolean")
  end
  validate_positive_integer(config.agent_start_timeout_ms, "agent_start_timeout_ms")
  if config.agent_start_timeout_ms > 300000 then
    fail("agent_start_timeout_ms", "at most 300000")
  end
  if
    type(config.server_retry_ms) ~= "table"
    or not vim.islist(config.server_retry_ms)
    or #config.server_retry_ms == 0
  then
    fail("server_retry_ms", "a non-empty list of positive integers")
  end
  for index, delay in ipairs(config.server_retry_ms) do
    validate_positive_integer(delay, string.format("server_retry_ms[%d]", index))
  end

  if type(config.agents) ~= "table" or vim.islist(config.agents) or next(config.agents) == nil then
    fail("agents", "a non-empty table")
  end
  for kind, agent in pairs(config.agents) do
    validate_string(kind, "agents key")
    if type(agent) ~= "table" then
      fail("agents." .. kind, "a table")
    end
    validate_list(agent.args or {}, "agents." .. kind .. ".args")
  end

  if type(config.refresh) ~= "table" then
    fail("refresh", "a table")
  end
  for _, key in ipairs({ "board_ms", "background_ms", "timeout_ms" }) do
    validate_positive_integer(config.refresh[key], "refresh." .. key)
  end

  if type(config.board) ~= "table" then
    fail("board", "a table")
  end
  validate_ratio_or_integer(config.board.width, "board.width")
  validate_ratio_or_integer(config.board.height, "board.height")
  if type(config.board.preview) ~= "boolean" then
    fail("board.preview", "a boolean")
  end
  if
    type(config.board.preview_ratio) ~= "number"
    or config.board.preview_ratio <= 0.25
    or config.board.preview_ratio >= 0.8
  then
    fail("board.preview_ratio", "a number above 0.25 and below 0.8")
  end
  validate_positive_integer(config.board.preview_lines, "board.preview_lines")
  if type(config.board.markers) ~= "table" then
    fail("board.markers", "a table")
  end
  for _, status in ipairs({ "blocked", "working", "done", "idle", "unknown" }) do
    validate_string(config.board.markers[status], "board.markers." .. status)
  end

  if type(config.terminal) ~= "table" then
    fail("terminal", "a table")
  end
  if config.terminal.side ~= "left" and config.terminal.side ~= "right" then
    fail("terminal.side", '"left" or "right"')
  end
  validate_ratio_or_integer(config.terminal.width, "terminal.width")
  if type(config.terminal.auto_insert) ~= "boolean" then
    fail("terminal.auto_insert", "a boolean")
  end
  validate_string(config.terminal.return_key, "terminal.return_key")

  if type(config.notifications) ~= "table" then
    fail("notifications", "a table")
  end
  for _, status in ipairs({ "blocked", "done" }) do
    if type(config.notifications[status]) ~= "boolean" then
      fail("notifications." .. status, "a boolean")
    end
  end

  if type(config.context) ~= "table" then
    fail("context", "a table")
  end
  validate_positive_integer(config.context.max_lines, "context.max_lines")
  validate_positive_integer(config.context.max_bytes, "context.max_bytes")
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    fail("setup options", "a table or nil")
  end
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts or {}))
  validate(candidate)
  values = candidate
  return values
end

function M.get()
  return values or M.setup()
end

function M.defaults()
  return vim.deepcopy(defaults)
end

function M._reset()
  values = nil
end

return M
