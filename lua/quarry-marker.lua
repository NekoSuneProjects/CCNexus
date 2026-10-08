-- CCNexus Quarry Survey Marker
-- Public-server friendly: normal/Advanced Computer + Wireless Modem + working GPS.
-- Place marker computers around a quarry perimeter. They locate themselves with
-- the existing GPS constellation and advertise their position to quarry turtles.
--
-- Usage:
--   quarry-marker.lua Quarry1
--   quarry-marker.lua Quarry1 NW
--   quarry-marker.lua reset
--
-- Recommended startup install:
--   /startup/quarry-marker.lua Quarry1 NW

local CONFIG = '/ccnexus/quarry-marker.json'
local CHANNEL = 65533
local PROTOCOL = 'ccnexus-quarry-marker-v1'
local args = { ... }

local function trim(v)
  return (tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function setColor(c)
  if term.isColor and term.isColor() then term.setTextColor(c) end
end

local function fail(msg)
  setColor(colors.red)
  print('ERROR: ' .. tostring(msg))
  setColor(colors.white)
end

local function ensureDir()
  if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
end

local function saveConfig(cfg)
  ensureDir()
  local h = fs.open(CONFIG, 'w')
  if not h then return false end
  h.write(textutils.serializeJSON(cfg))
  h.close()
  return true
end

local function loadConfig()
  if not fs.exists(CONFIG) then return nil end
  local h = fs.open(CONFIG, 'r')
  if not h then return nil end
  local raw = h.readAll(); h.close()
  local ok, cfg = pcall(textutils.unserializeJSON, raw)
  if not ok or type(cfg) ~= 'table' then return nil end
  if trim(cfg.quarry) == '' then return nil end
  return cfg
end

local function wirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and type(p.isWireless) == 'function' then
      local ok, wireless = pcall(p.isWireless)
      if ok and wireless then return name, p end
    end
  end
end

term.clear(); term.setCursorPos(1, 1)
setColor(colors.cyan)
print('CCNexus Quarry Marker')
print('=====================')
setColor(colors.white)
print('')

if tostring(args[1] or ''):lower() == 'reset' then
  if fs.exists(CONFIG) then fs.delete(CONFIG) end
  print('Saved quarry marker configuration removed.')
  return
end

local modemName, modem = wirelessModem()
if not modem then
  fail('Attach a Wireless Modem to this computer.')
  return
end

local cfg = loadConfig()
local requestedQuarry = trim(args[1])
local requestedMarker = trim(args[2])
if requestedQuarry ~= '' then
  cfg = {
    quarry = requestedQuarry:sub(1, 48),
    marker = (requestedMarker ~= '' and requestedMarker or ('M' .. os.getComputerID())):sub(1, 24)
  }
  if not saveConfig(cfg) then fail('Could not save marker configuration.'); return end
elseif not cfg then
  write('Quarry name: ')
  local quarry = trim(read())
  if quarry == '' then fail('A quarry name is required.'); return end
  write('Marker label [M' .. os.getComputerID() .. ']: ')
  local marker = trim(read())
  if marker == '' then marker = 'M' .. os.getComputerID() end
  cfg = { quarry = quarry:sub(1, 48), marker = marker:sub(1, 24) }
  if not saveConfig(cfg) then fail('Could not save marker configuration.'); return end
end

local function locate()
  local x, y, z = gps.locate(2, false)
  if not x then return nil end
  return {
    x = math.floor(x * 1000 + 0.5) / 1000,
    y = math.floor(y * 1000 + 0.5) / 1000,
    z = math.floor(z * 1000 + 0.5) / 1000
  }
end

local pos = locate()
if not pos then
  fail('No GPS fix. Keep the GPS constellation online and in wireless range.')
  print('Test this computer with: gps locate')
  return
end

modem.open(CHANNEL)

local function draw(position, count)
  term.clear(); term.setCursorPos(1, 1)
  setColor(colors.cyan); print('CCNexus Quarry Marker'); setColor(colors.white)
  print('')
  print('Quarry:   ' .. cfg.quarry)
  print('Marker:   ' .. cfg.marker)
  print('Computer: #' .. os.getComputerID())
  print('Modem:    ' .. modemName)
  print('Channel:  ' .. CHANNEL)
  print('')
  setColor(colors.lime); print('GPS FIX / BEACON ONLINE'); setColor(colors.white)
  print(('X %.3f  Y %.3f  Z %.3f'):format(position.x, position.y, position.z))
  print('')
  print('Beacon broadcasts: ' .. tostring(count or 0))
  print('Leave this marker powered while mining.')
end

local count = 0
draw(pos, count)

while true do
  -- Re-locate each cycle so moving/replacing a marker automatically updates it.
  local fresh = locate()
  if fresh then pos = fresh end
  local message = textutils.serializeJSON({
    protocol = PROTOCOL,
    quarry = cfg.quarry,
    marker = cfg.marker,
    computerId = os.getComputerID(),
    x = pos.x, y = pos.y, z = pos.z,
    timestamp = os.epoch('utc')
  })
  modem.transmit(CHANNEL, CHANNEL, message)
  count = count + 1
  draw(pos, count)
  sleep(2)
end
