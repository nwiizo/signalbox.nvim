local M = {}

M.minimum_herdr = { 0, 7, 5 }
M.verified_herdr = { 0, 8, 0 }

local function format(version)
  return table.concat(version, ".")
end

function M.same_version(parsed, version)
  return parsed.major == version[1] and parsed.minor == version[2] and parsed.patch == version[3]
end

M.minimum_herdr_string = format(M.minimum_herdr)
M.verified_herdr_string = format(M.verified_herdr)

return M
