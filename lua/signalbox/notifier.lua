local config = require("signalbox.config")

local M = {}

local notify = vim.notify
local seen = {}
local visibility_probe

local function attention_is_visible(event)
  if visibility_probe then
    return visibility_probe(event)
  end
  local ok, board = pcall(require, "signalbox.board")
  if ok and board.is_visible() then
    return true
  end
  local buffer = vim.api.nvim_get_current_buf()
  if vim.b[buffer].signalbox_terminal_id ~= event.terminal_id then
    return false
  end
  local terminal_ok, terminal = pcall(require, "signalbox.terminal")
  return terminal_ok and terminal.is_attached(event.terminal_id, buffer)
end

function M.on_transition(event)
  if not config.get().notifications[event.status] then
    return
  end
  local key = table.concat({ event.terminal_id, event.status, tostring(event.revision) }, ":")
  if seen[key] then
    return
  end
  if attention_is_visible(event) then
    return
  end
  seen[key] = true
  local message = string.format("%s is %s", event.name or event.terminal_id, event.status)
  if event.title and event.title ~= "" then
    message = message .. ": " .. event.title
  end
  local level = event.status == "blocked" and vim.log.levels.WARN or vim.log.levels.INFO
  notify(message, level, { title = "Signalbox" })
end

function M._set_notify(value)
  notify = value or vim.notify
end

function M._set_visibility_probe(value)
  visibility_probe = value
end

function M._reset()
  notify = vim.notify
  seen = {}
  visibility_probe = nil
end

return M
