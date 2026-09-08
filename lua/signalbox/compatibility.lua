local M = {}

M.minimum_herdr = { 0, 7, 5 }
M.verified_herdr = { 0, 9, 0 }

local function format(version)
  return table.concat(version, ".")
end

function M.same_version(parsed, version)
  return parsed.major == version[1] and parsed.minor == version[2] and parsed.patch == version[3]
end

function M.parse_server_status(output)
  local fields = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+):%s*(.-)%s*$")
    if key then
      fields[key] = value
    end
  end
  if fields.status == "not running" then
    return "not_running"
  end
  if fields.status ~= "running" then
    return "incompatible"
  end
  -- Herdr 0.9 separates endpoint compatibility from its private wire protocol.
  if fields.endpoint_compatible ~= nil then
    return fields.endpoint_compatible == "yes" and "compatible" or "incompatible"
  end
  if tonumber(fields.protocol) and fields.compatible == "yes" then
    return "compatible"
  end
  return "incompatible"
end

M.minimum_herdr_string = format(M.minimum_herdr)
M.verified_herdr_string = format(M.verified_herdr)

return M
