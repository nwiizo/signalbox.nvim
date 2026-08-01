if vim.g.loaded_signalbox_nvim == 1 then
  return
end
vim.g.loaded_signalbox_nvim = 1

vim.api.nvim_create_user_command("Signalbox", function()
  require("signalbox").toggle()
end, { desc = "Toggle the Signalbox attention board" })

vim.api.nvim_create_user_command("SignalboxRefresh", function()
  require("signalbox").refresh()
end, { desc = "Refresh Herdr agent state" })

vim.api.nvim_create_user_command("SignalboxStart", function(args)
  require("signalbox").start(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("signalbox")._complete_agent_kinds()
  end,
  desc = "Start a persistent coding agent through Herdr",
})

vim.api.nvim_create_user_command("SignalboxAttach", function(args)
  require("signalbox").attach(args.args ~= "" and args.args or nil, { takeover = args.bang })
end, {
  nargs = "?",
  bang = true,
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Attach to a persistent Herdr agent",
})

vim.api.nvim_create_user_command("SignalboxPrompt", function(args)
  local target = args.args ~= "" and args.args or nil
  if args.range > 0 then
    require("signalbox")._send_range(target, vim.api.nvim_get_current_buf(), args.line1, args.line2)
  else
    require("signalbox").prompt(target)
  end
end, {
  nargs = "?",
  range = true,
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Prompt an agent, optionally with a line range",
})

vim.api.nvim_create_user_command("SignalboxRename", function(args)
  require("signalbox").rename(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Give a Herdr agent a stable role name",
})

vim.api.nvim_create_user_command("SignalboxSendVisual", function(args)
  if args.range == 0 then
    vim.notify("SignalboxSendVisual requires a visual range", vim.log.levels.ERROR, { title = "Signalbox" })
    return
  end
  require("signalbox")._send_visual(
    args.args ~= "" and args.args or nil,
    vim.api.nvim_get_current_buf(),
    args.line1,
    args.line2
  )
end, {
  nargs = "?",
  range = true,
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Send an exact visual selection to an agent",
})

vim.api.nvim_create_user_command("SignalboxSendFile", function(args)
  require("signalbox")._send_file(args.args ~= "" and args.args or nil, vim.api.nvim_get_current_buf())
end, {
  nargs = "?",
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Send the current file reference to an agent",
})

vim.api.nvim_create_user_command("SignalboxSendDiagnostics", function(args)
  require("signalbox")._send_diagnostics(args.args ~= "" and args.args or nil, vim.api.nvim_get_current_buf())
end, {
  nargs = "?",
  complete = function()
    return require("signalbox")._complete_agents()
  end,
  desc = "Send current-buffer diagnostics to an agent",
})

vim.api.nvim_create_user_command("SignalboxHealth", function()
  vim.cmd("checkhealth signalbox")
end, { desc = "Run signalbox.nvim health checks" })
