local M = {}

local function cwd_for(agent, fallback)
  return (agent and agent.cwd) or fallback or vim.fn.getcwd()
end

function M.lazygit(agent, fallback)
  local snacks = rawget(_G, "Snacks")
  if not snacks then
    local ok, module = pcall(require, "snacks")
    snacks = ok and module or nil
  end
  if snacks and snacks.lazygit and type(snacks.lazygit.open) == "function" then
    snacks.lazygit.open({ cwd = cwd_for(agent, fallback) })
    return true
  end
  vim.notify("Snacks.lazygit is unavailable", vim.log.levels.WARN, { title = "Signalbox" })
  return false
end

function M.diffview(agent, fallback)
  if vim.fn.exists(":DiffviewOpen") ~= 2 then
    vim.notify("DiffviewOpen is unavailable", vim.log.levels.WARN, { title = "Signalbox" })
    return false
  end
  vim.cmd("DiffviewOpen -C" .. vim.fn.fnameescape(cwd_for(agent, fallback)))
  return true
end

return M
