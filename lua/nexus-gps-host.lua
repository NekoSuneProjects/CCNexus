-- CCNexus Nexus GPS Host
--
-- Public-server friendly GPS constellation for normal/Advanced Computers.
-- No Command Computer, OP permission, Minecraft commands, or F3 coordinates
-- are required. Instead, four computers are physically placed in a known
-- shape and assigned preset CCNexus-relative coordinates.
--
-- Default 10-block constellation (computer block positions):
--   A = (0,  0,  0)   origin
--   B = (10, 0,  0)   10 blocks from A on one horizontal axis
--   C = (0,  0, 10)   10 blocks from A on the other horizontal axis
--   D = (0, 10,  0)   10 blocks directly above A
--
-- Usage:
--   nexus-gps-host.lua
--   nexus-gps-host.lua A
--   nexus-gps-host.lua B 10
--   nexus-gps-host.lua reset
--
-- Put this file in /startup/nexus-gps-host.lua on a dedicated GPS host.

local CONFIG = '/ccnexus/nexus-gps-host.json'
local args = { ... }

local function setColor(color)
  if term.isColor and term.isColor() then term.setTextColor(color) end
end

local function trim(value)
  return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function fail(message)
  setColor(colors.red)
  print('ERROR: ' .. tostring(message))
  setColor(colors.white)
  return false
end

local function ensureConfigDir()
  if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
end

local function saveConfig(config)
  ensureConfigDir()
  local handle = fs.open(CONFIG, 'w')
  if not handle then return false end
  handle.write(textutils.serializeJSON(config))
  handle.close()
  return true
end

local function loadConfig()
  if not fs.exists(CONFIG) then return nil end
  local handle = fs.open(CONFIG, 'r')
  if not handle then return nil end
  local raw = handle.readAll()
  handle.close()
  local ok, data = pcall(textutils.unserializeJSON, raw)
  if not ok or type(data) ~= 'table' then return nil end
  local host = tostring(data.host or ''):upper()
  local spacing = tonumber(data.spacing)
  if not ({ A = true, B = true, C = true, D = true })[host] then return nil end
  if not spacing or spacing < 2 or spacing > 128 then return nil end
  return { host = host, spacing = spacing }
end

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local modem = peripheral.wrap(name)
    if modem and type(modem.isWireless) == 'function' then
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then return name end
    end
  end
  return nil
end

local function coordinates(host, spacing)
  if host == 'A' then return 0, 0, 0 end
  if host == 'B' then return spacing, 0, 0 end
  if host == 'C' then return 0, 0, spacing end
  if host == 'D' then return 0, spacing, 0 end
end

local function askHost()
  while true do
    write('Host letter [A/B/C/D]: ')
    local host = trim(read()):upper()
    if ({ A = true, B = true, C = true, D = true })[host] then return host end
    setColor(colors.red)
    print('Choose A, B, C, or D.')
    setColor(colors.white)
  end
end

local function askSpacing(default)
  while true do
    write('Constellation spacing [' .. tostring(default) .. ']: ')
    local raw = trim(read())
    if raw == '' then return default end
    local n = tonumber(raw)
    if n and n >= 2 and n <= 128 and math.floor(n) == n then return n end
    setColor(colors.red)
    print('Enter a whole number from 2 to 128.')
    setColor(colors.white)
  end
end

term.clear()
term.setCursorPos(1, 1)
setColor(colors.cyan)
print('CCNexus Nexus GPS Host')
print('======================')
setColor(colors.white)
print('')

if tostring(args[1] or ''):lower() == 'reset' then
  if fs.exists(CONFIG) then fs.delete(CONFIG) end
  print('Saved Nexus GPS host configuration removed.')
  print('Run the program again to configure this host.')
  return
end

local modemName = findWirelessModem()
if not modemName then
  fail('No Wireless or Ender Modem is attached.')
  print('Attach a Wireless/Ender Modem to this computer and reboot.')
  return
end

local config = loadConfig()
if not config then
  local explicitHost = tostring(args[1] or ''):upper()
  local host = ({ A = true, B = true, C = true, D = true })[explicitHost] and explicitHost or nil
  local spacing = tonumber(args[2])

  setColor(colors.yellow)
  print('FIRST-TIME PRESET SETUP')
  setColor(colors.white)
  print('No Minecraft coordinates are needed.')
  print('The four computer blocks must be placed at the exact')
  print('relative spacing described by the A/B/C/D layout.')
  print('')

  host = host or askHost()
  if not spacing or spacing < 2 or spacing > 128 or math.floor(spacing) ~= spacing then
    spacing = askSpacing(10)
  end

  config = { host = host, spacing = spacing }
  if not saveConfig(config) then
    fail('Could not save ' .. CONFIG)
    return
  end

  setColor(colors.lime)
  print('Configuration saved for future reboots.')
  setColor(colors.white)
  print('')
end

local x, y, z = coordinates(config.host, config.spacing)
if x == nil then
  fail('Invalid host preset in configuration.')
  return
end

setColor(colors.lime)
print('NEXUS GPS HOST READY')
setColor(colors.white)
print('Computer: #' .. tostring(os.getComputerID()))
print('Modem:    ' .. tostring(modemName))
print('Host:     ' .. tostring(config.host))
print('Spacing:  ' .. tostring(config.spacing) .. ' blocks')
print(('Nexus:    X=%s Y=%s Z=%s'):format(tostring(x), tostring(y), tostring(z)))
print('Channel:  ' .. tostring(gps.CHANNEL_GPS or 65534))
print('')
print('Keep this computer powered and its chunk loaded.')
print('Starting GPS host...')
print('')

local started = shell.run('gps', 'host', tostring(x), tostring(y), tostring(z))
if started == false then
  fail('The built-in gps host program exited unexpectedly.')
end
