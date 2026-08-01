local h = require("tests.harness")
local board = require("signalbox.board")
local config = require("signalbox.config")
local notifier = require("signalbox.notifier")
local state = require("signalbox.state")
local terminal = require("signalbox.terminal")

local function reset(opts)
  board._reset()
  terminal._reset()
  state._reset()
  config._reset()
  config.setup(opts)
  notifier._reset()
end

h.test("notifier reports configured attention states once per revision", function()
  reset()
  local notifications = {}
  notifier._set_notify(function(message, level)
    table.insert(notifications, { message = message, level = level })
  end)
  local blocked = { terminal_id = "a", status = "blocked", revision = 2, name = "api", title = "approval" }
  notifier.on_transition(blocked)
  notifier.on_transition(blocked)
  notifier.on_transition({ terminal_id = "a", status = "working", revision = 3, name = "api" })
  notifier.on_transition({ terminal_id = "a", status = "done", revision = 4, name = "api" })
  h.eq(2, #notifications)
  h.contains(notifications[1].message, "approval")
  h.eq(vim.log.levels.WARN, notifications[1].level)
  h.eq(vim.log.levels.INFO, notifications[2].level)
end)

h.test("notifier respects disabled done notifications", function()
  reset({ notifications = { done = false } })
  local count = 0
  notifier._set_notify(function()
    count = count + 1
  end)
  notifier.on_transition({ terminal_id = "a", status = "done", revision = 1, name = "api" })
  h.eq(0, count)
end)

h.test("notifier does not burn a dedup key while attention is visible", function()
  reset()
  local notifications = 0
  notifier._set_notify(function()
    notifications = notifications + 1
  end)
  notifier._set_visibility_probe(function()
    return true
  end)
  local blocked = { terminal_id = "board", status = "blocked", revision = 0, name = "board" }
  notifier.on_transition(blocked)
  notifier._set_visibility_probe(function()
    return false
  end)
  notifier.on_transition(blocked)
  h.eq(1, notifications)
end)

h.test("notifier only suppresses a matching live attach", function()
  reset()
  local notifications = 0
  notifier._set_notify(function()
    notifications = notifications + 1
  end)
  local previous = vim.api.nvim_get_current_buf()
  local live_buffer = vim.api.nvim_create_buf(false, true)
  local stale_buffer = vim.api.nvim_create_buf(false, true)
  vim.b[live_buffer].signalbox_terminal_id = "attached"
  vim.b[stale_buffer].signalbox_terminal_id = "attached"
  terminal._terminals().attached = { bufnr = live_buffer, job_id = 17 }

  vim.api.nvim_set_current_buf(stale_buffer)
  local done = { terminal_id = "attached", status = "done", revision = 1, name = "attached" }
  notifier.on_transition(done)
  vim.api.nvim_set_current_buf(live_buffer)
  done.revision = 2
  notifier.on_transition(done)
  terminal._terminals().attached = nil
  notifier.on_transition(done)
  vim.api.nvim_set_current_buf(previous)
  vim.api.nvim_buf_delete(live_buffer, { force = true })
  vim.api.nvim_buf_delete(stale_buffer, { force = true })
  h.eq(2, notifications)
end)

h.test("notifier suppresses the real open board without burning the transition", function()
  reset()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = {},
    workspaces = { { workspace_id = "w1", label = "one" } },
  })
  board.setup()
  board.open()
  local notifications = 0
  notifier._set_notify(function()
    notifications = notifications + 1
  end)
  local blocked = { terminal_id = "board", status = "blocked", revision = 1, name = "board" }
  notifier.on_transition(blocked)
  board.close()
  notifier.on_transition(blocked)
  h.eq(1, notifications)
  board._reset()
end)

h.test("a board in another tab does not hide attention from the current tab", function()
  reset()
  state._set_transition_handler(function() end)
  state._set_emit(function() end)
  state._accept({
    agents = {},
    workspaces = { { workspace_id = "w1", label = "one" } },
  })
  board.setup()
  board.open()
  vim.cmd("tabnew")
  local notifications = 0
  notifier._set_notify(function()
    notifications = notifications + 1
  end)
  notifier.on_transition({ terminal_id = "other-tab", status = "blocked", revision = 1, name = "other-tab" })
  vim.cmd("tabclose")
  h.eq(1, notifications)
  board._reset()
end)
