-- CCNexus Quarry Service
-- Marker-anchored bedrock quarry + emergency surface return.
--
-- Usage:
--   quarry-service.lua Quarry1 mine
--   quarry-service.lua Quarry1 rescue
--
-- Requires four running quarry-marker.lua computers and a Wireless Modem.
-- The NE marker is used as the surface/service anchor. The actual service shaft
-- is one block inside the marker rectangle so the marker computer is not mined.

local FLEET_CONFIG = '/ccnexus/turtle-fleet.json'
local CHANNEL = 65533
local PROTOCOL = 'ccnexus-quarry-marker-v1'
local args = { ... }

if not turtle then error('This program must run on a turtle.', 0) end

local function trim(v)
  return (tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function round(v)
  v = tonumber(v) or 0
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

local function sign(v)
  if v > 0 then return 1 end
  if v < 0 then return -1 end
  return 0
end

local function setColor(c)
  if term.isColor and term.isColor() then term.setTextColor(c) end
end

local function fail(msg)
  setColor(colors.red)
  print('ERROR: ' .. tostring(msg))
  setColor(colors.white)
  error(tostring(msg), 0)
end

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and type(p.isWireless) == 'function' then
      local ok, wireless = pcall(p.isWireless)
      if ok and wireless then return name, p end
    end
  end
end

local modemName, modem = findWirelessModem()
if not modem then fail('Attach a Wireless Modem to this turtle.') end
modem.open(CHANNEL)

local fleet = {
  stations = {},
  nav = { position = nil, heading = nil },
  fuel = { low = 512, target = 4000, station = 'fuel', slot = 16 }
}

local function loadFleet()
  if not fs.exists(FLEET_CONFIG) then return end
  local h = fs.open(FLEET_CONFIG, 'r')
  if not h then return end
  local ok, data = pcall(textutils.unserializeJSON, h.readAll())
  h.close()
  if not ok or type(data) ~= 'table' then return end
  if type(data.stations) == 'table' then fleet.stations = data.stations end
  if type(data.nav) == 'table' then
    fleet.nav.position = data.nav.position
    fleet.nav.heading = tonumber(data.nav.heading)
  end
  if type(data.fuel) == 'table' then
    fleet.fuel.low = math.max(1, tonumber(data.fuel.low) or fleet.fuel.low)
    fleet.fuel.target = math.max(fleet.fuel.low, tonumber(data.fuel.target) or fleet.fuel.target)
    fleet.fuel.station = trim(data.fuel.station) ~= '' and trim(data.fuel.station) or fleet.fuel.station
    fleet.fuel.slot = math.max(1, math.min(16, tonumber(data.fuel.slot) or fleet.fuel.slot))
  end
end
loadFleet()

local function saveNav(pos, heading)
  if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
  local data = fleet
  data.nav = data.nav or {}
  data.nav.position = { x = pos.x, y = pos.y, z = pos.z }
  data.nav.heading = heading
  local h = fs.open(FLEET_CONFIG, 'w')
  if h then h.write(textutils.serializeJSON(data)); h.close() end
end

local function parseMarker(message)
  if type(message) ~= 'string' then return nil end
  local ok, m = pcall(textutils.unserializeJSON, message)
  if not ok or type(m) ~= 'table' or m.protocol ~= PROTOCOL then return nil end
  if trim(m.quarry) == '' or tonumber(m.x) == nil or tonumber(m.y) == nil or tonumber(m.z) == nil then return nil end
  return {
    quarry = trim(m.quarry), marker = trim(m.marker):upper(),
    computerId = tonumber(m.computerId),
    x = round(m.x), y = round(m.y), z = round(m.z)
  }
end

local function discover(seconds)
  local sets = {}
  local timer = os.startTimer(seconds or 6)
  while true do
    local e = { os.pullEvent() }
    if e[1] == 'timer' and e[2] == timer then break end
    if e[1] == 'modem_message' and e[3] == CHANNEL then
      local m = parseMarker(e[5])
      if m then
        sets[m.quarry] = sets[m.quarry] or {}
        sets[m.quarry][tostring(m.computerId or m.marker)] = m
      end
    end
  end
  return sets
end

local function markerList(set)
  local out = {}
  for _, m in pairs(set or {}) do out[#out + 1] = m end
  return out
end

local quarryName = trim(args[1])
local mode = trim(args[2]):lower()
if mode == '' then mode = 'mine' end
if mode ~= 'mine' and mode ~= 'rescue' then fail('Mode must be mine or rescue.') end

term.clear(); term.setCursorPos(1, 1)
setColor(colors.cyan)
print('CCNexus Quarry Service')
print('======================')
setColor(colors.white)
print('Modem: ' .. tostring(modemName))
print('Scanning quarry markers for 6 seconds...')

local sets = discover(6)
if quarryName == '' then
  local names = {}
  for name in pairs(sets) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then fail('No quarry markers discovered.') end
  if #names == 1 then quarryName = names[1]
  else
    print('')
    for i, name in ipairs(names) do print(('[%d] %s'):format(i, name)) end
    write('Choose quarry [1]: ')
    quarryName = names[math.max(1, math.min(#names, tonumber(read()) or 1))]
  end
end

local markers = markerList(sets[quarryName])
if #markers < 4 then fail('Need all four quarry markers online for ' .. quarryName .. '. Found ' .. #markers .. '.') end

local minX, maxX, minZ, maxZ
local ne
for _, m in ipairs(markers) do
  minX = minX and math.min(minX, m.x) or m.x
  maxX = maxX and math.max(maxX, m.x) or m.x
  minZ = minZ and math.min(minZ, m.z) or m.z
  maxZ = maxZ and math.max(maxZ, m.z) or m.z
  if m.marker == 'NE' then ne = m end
end
if not ne then fail('No marker labelled NE was found. Configure one marker as NE.') end
if minX == maxX or minZ == maxZ then fail('Marker rectangle has no usable X/Z area.') end

local centerX = (minX + maxX) / 2
local centerZ = (minZ + maxZ) / 2
local inset = 1
local service = {
  x = ne.x + sign(centerX - ne.x) * inset,
  y = ne.y,
  z = ne.z + sign(centerZ - ne.z) * inset
}
local mineMinX, mineMaxX = minX + inset, maxX - inset
local mineMinZ, mineMaxZ = minZ + inset, maxZ - inset
if mineMinX > mineMaxX or mineMinZ > mineMaxZ then fail('Marker rectangle is too small after the safety inset.') end

print('')
print('Quarry: ' .. quarryName)
print(('Marker bounds X=%d..%d Z=%d..%d'):format(minX, maxX, minZ, maxZ))
print(('NE marker     X=%d Y=%d Z=%d'):format(ne.x, ne.y, ne.z))
print(('Service point X=%d Y=%d Z=%d'):format(service.x, service.y, service.z))
print(('Mine bounds   X=%d..%d Z=%d..%d'):format(mineMinX, mineMaxX, mineMinZ, mineMaxZ))

local pos
local heading = fleet.nav.heading

local function gpsFix(timeout)
  local x, y, z = gps.locate(timeout or 2, false)
  if not x then return nil end
  pos = { x = round(x), y = round(y), z = round(z) }
  return { x = pos.x, y = pos.y, z = pos.z }
end

local cached = fleet.nav.position
if not gpsFix(2) and cached then pos = { x = round(cached.x), y = round(cached.y), z = round(cached.z) } end
if not pos then fail('No GPS fix and no saved Fleet position. Move the turtle into GPS range once first.') end

local function update(kind)
  if kind == 'up' then pos.y = pos.y + 1
  elseif kind == 'down' then pos.y = pos.y - 1
  elseif heading ~= nil then
    local back = kind == 'back' and -1 or 1
    if heading == 0 then pos.z = pos.z - back
    elseif heading == 1 then pos.x = pos.x + back
    elseif heading == 2 then pos.z = pos.z + back
    elseif heading == 3 then pos.x = pos.x - back end
  end
  saveNav(pos, heading)
end

local function refuelLocal(minimum)
  local level = turtle.getFuelLevel()
  if level == 'unlimited' or (tonumber(level) and tonumber(level) >= minimum) then return true end
  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if turtle.refuel(0) then
        while turtle.getItemCount(slot) > 0 do
          level = turtle.getFuelLevel()
          if level == 'unlimited' or (tonumber(level) and tonumber(level) >= minimum) then break end
          if not turtle.refuel(1) then break end
        end
      end
    end
  end
  turtle.select(selected)
  level = turtle.getFuelLevel()
  return level == 'unlimited' or (tonumber(level) and tonumber(level) >= minimum)
end

local function turnRight()
  local ok, err = turtle.turnRight()
  if ok and heading ~= nil then heading = (heading + 1) % 4; saveNav(pos, heading) end
  return ok, err
end
local function turnLeft()
  local ok, err = turtle.turnLeft()
  if ok and heading ~= nil then heading = (heading + 3) % 4; saveNav(pos, heading) end
  return ok, err
end
local function turnTo(target)
  if heading == nil then return false, 'heading unknown' end
  local diff = (target - heading) % 4
  if diff == 3 then return turnLeft() end
  for _ = 1, diff do local ok, err = turnRight(); if not ok then return false, err end end
  return true
end

local function forward(dig)
  if not refuelLocal(1) then return false, 'out of fuel' end
  local last = 'blocked'
  for _ = 1, dig and 20 or 1 do
    local ok, err = turtle.forward()
    if ok then update('forward'); return true end
    last = err or last
    if not dig then break end
    if turtle.detect() then
      local dug, derr = turtle.dig()
      if not dug and derr then last = derr end
    else turtle.attack() end
    sleep(0.05)
  end
  return false, last
end
local function up(dig)
  if not refuelLocal(1) then return false, 'out of fuel' end
  if dig and turtle.detectUp() then
    local ok, err = turtle.digUp()
    if not ok then return false, err or 'cannot dig block above' end
  end
  local ok, err = turtle.up()
  if ok then update('up') end
  return ok, err
end
local function down(dig)
  if not refuelLocal(1) then return false, 'out of fuel' end
  if dig and turtle.detectDown() then
    local ok, err = turtle.digDown()
    if not ok then return false, err or 'cannot dig block below' end
  end
  local ok, err = turtle.down()
  if ok then update('down') end
  return ok, err
end

local function calibrate()
  local before = gpsFix(2)
  if not before then
    if heading ~= nil then return true end
    return false, 'GPS is required once to determine the turtle heading.'
  end
  for attempt = 1, 4 do
    local moved = turtle.forward()
    if moved then
      sleep(0.15)
      local x, y, z = gps.locate(2, false)
      local backed, berr = turtle.back()
      if not backed then return false, 'could not move back after heading test: ' .. tostring(berr) end
      pos = { x = before.x, y = before.y, z = before.z }
      if not x then return false, 'lost GPS during heading calibration' end
      local dx, dz = round(x) - before.x, round(z) - before.z
      if math.abs(dx) >= math.abs(dz) and dx ~= 0 then heading = dx > 0 and 1 or 3
      elseif dz ~= 0 then heading = dz > 0 and 2 or 0
      else return false, 'GPS did not change enough during heading calibration' end
      saveNav(pos, heading)
      return true
    end
    if attempt < 4 then turtle.turnRight() end
  end
  return false, 'all four sides are blocked; clear one adjacent block'
end

if heading == nil then
  local ok, err = calibrate()
  if not ok then fail(err) end
end

local function moveXZ(tx, tz, dig)
  if pos.x ~= tx then
    local ok, err = turnTo(pos.x < tx and 1 or 3)
    if not ok then return false, err end
    for _ = 1, math.abs(tx - pos.x) do
      local moved, merr = forward(dig)
      if not moved then return false, 'X travel blocked: ' .. tostring(merr) end
    end
  end
  if pos.z ~= tz then
    local ok, err = turnTo(pos.z < tz and 2 or 0)
    if not ok then return false, err end
    for _ = 1, math.abs(tz - pos.z) do
      local moved, merr = forward(dig)
      if not moved then return false, 'Z travel blocked: ' .. tostring(merr) end
    end
  end
  return true
end

local function moveY(ty, dig)
  while pos.y < ty do
    local ok, err = up(dig)
    if not ok then return false, 'cannot climb to surface: ' .. tostring(err) end
  end
  while pos.y > ty do
    local ok, err = down(dig)
    if not ok then return false, 'cannot descend to target: ' .. tostring(err) end
  end
  return true
end

local function returnToSurface()
  -- First reach the service shaft at the current depth, then climb vertically.
  local ok, err = moveXZ(service.x, service.z, true)
  if not ok then return false, err end
  ok, err = moveY(service.y, true)
  if not ok then
    return false, err .. '. If bedrock is physically above this turtle, survival-mode rescue cannot teleport through it.'
  end
  gpsFix(2)
  saveNav(pos, heading)
  return true
end

if mode == 'rescue' then
  print('')
  setColor(colors.yellow)
  print('RESCUE MODE')
  print('Returning to the NE service point...')
  setColor(colors.white)
  local ok, err = returnToSurface()
  if not ok then fail(err) end
  setColor(colors.lime)
  print(('RESCUED: X=%d Y=%d Z=%d'):format(pos.x, pos.y, pos.z))
  setColor(colors.white)
  return
end

-- Always move to marker surface before starting the quarry. This prevents an
-- underground/near-bedrock launch point from becoming the quarry origin.
print('')
print('Moving to NE surface service point before mining...')
local ok, err = returnToSurface()
if not ok then fail(err) end

local xDir = service.x > centerX and -1 or 1
local zDir = service.z > centerZ and -1 or 1
local length = mineMaxX - mineMinX + 1
local width = mineMaxZ - mineMinZ + 1
local surfaceHeading = heading
local depth = 0

local function headingForX(dir) return dir > 0 and 1 or 3 end
local function headingForZ(dir) return dir > 0 and 2 or 0 end

local function blockBelowIsBedrock()
  local has, data = turtle.inspectDown()
  return has and data and tostring(data.name or ''):lower():find('bedrock', 1, true) ~= nil
end

local function mineCell()
  if not turtle.detectDown() then return true, false end
  if blockBelowIsBedrock() then return true, true end
  local dug, derr = turtle.digDown()
  if not dug then return false, false, derr or 'cannot dig block below' end
  return true, false
end

local function fuelStation()
  return fleet.stations and fleet.stations[fleet.fuel.station] or nil
end

local function sideCall(side, action, count)
  side = tostring(side or 'down'):lower()
  local fn = action .. (side == 'up' and 'Up' or side == 'down' and 'Down' or '')
  local f = turtle[fn]
  if type(f) ~= 'function' then return false, 'unsupported side ' .. side end
  return f(count)
end

local function refuelAtDepot(target)
  local station = fuelStation()
  if not station then return refuelLocal(target), 'no shared fuel station is configured' end
  local savedHeading = heading
  local ok, err = moveY(service.y, true)
  if not ok then return false, err end
  ok, err = moveXZ(round(station.x), round(station.z), false)
  if not ok then return false, 'cannot reach fuel depot: ' .. tostring(err) end
  ok, err = moveY(round(station.y or service.y), false)
  if not ok then return false, 'cannot reach fuel depot Y: ' .. tostring(err) end

  local slot = fleet.fuel.slot
  turtle.select(slot)
  local tries = 0
  while tries < 128 do
    local level = turtle.getFuelLevel()
    if level == 'unlimited' or (tonumber(level) and tonumber(level) >= target) then break end
    if turtle.getItemCount(slot) == 0 then
      local sucked = sideCall(station.side or 'down', 'suck', 64)
      if not sucked then break end
    end
    if not turtle.refuel(0) then
      sideCall(station.side or 'down', 'drop')
      return false, 'fuel chest supplied a non-fuel item'
    end
    turtle.refuel(1)
    tries = tries + 1
  end

  ok, err = moveY(service.y, false)
  if not ok then return false, err end
  ok, err = moveXZ(service.x, service.z, false)
  if not ok then return false, err end
  for _ = 1, depth do
    local d, derr = down(false)
    if not d then return false, 'cannot return down service shaft: ' .. tostring(derr) end
  end
  if savedHeading ~= nil then turnTo(savedHeading) end

  local level = turtle.getFuelLevel()
  return level == 'unlimited' or (tonumber(level) and tonumber(level) >= target), 'fuel depot did not provide enough fuel'
end

local function ensureLayerFuel()
  local layerTravel = width * length + width + length
  local reserve = math.max(fleet.fuel.low, layerTravel + depth * 2 + 64)
  local level = turtle.getFuelLevel()
  if level == 'unlimited' or (tonumber(level) and tonumber(level) >= reserve) then return true end
  if refuelLocal(reserve) then return true end
  print(('Fuel low (%s), servicing at surface...'):format(tostring(level)))
  return refuelAtDepot(math.max(fleet.fuel.target, reserve))
end

local function mineLayer()
  local bedrockHits = 0
  local rowXDir = xDir
  local targetStartX = xDir > 0 and mineMinX or mineMaxX
  local targetStartZ = zDir > 0 and mineMinZ or mineMaxZ
  local ok, err = moveXZ(targetStartX, targetStartZ, true)
  if not ok then return false, err end
  turnTo(headingForX(rowXDir))

  for row = 1, width do
    for col = 1, length do
      local cellOk, bedrock, cellErr = mineCell()
      if not cellOk then return false, cellErr end
      if bedrock then bedrockHits = bedrockHits + 1 end
      if col < length then
        local moved, merr = forward(true)
        if not moved then return false, 'cannot mine row: ' .. tostring(merr) end
      end
    end
    if row < width then
      turnTo(headingForZ(zDir))
      local moved, merr = forward(true)
      if not moved then return false, 'cannot step to next row: ' .. tostring(merr) end
      rowXDir = -rowXDir
      turnTo(headingForX(rowXDir))
    end
  end
  return true, bedrockHits
end

local maxLayers = 384
print(('Starting %dx%d quarry from marker Y=%d down to bedrock.'):format(length, width, service.y))
print('The turtle only returns to the surface for fuel, rescue, or completion.')

for layer = 1, maxLayers do
  depth = layer - 1
  local fuelOk, fuelErr = ensureLayerFuel()
  if not fuelOk then fail(fuelErr or 'not enough fuel to safely continue') end

  print(('Mining layer %d at Y=%d'):format(layer, pos.y))
  local layerOk, bedrockHitsOrErr = mineLayer()
  if not layerOk then fail(bedrockHitsOrErr) end

  local backOk, backErr = moveXZ(service.x, service.z, true)
  if not backOk then fail('cannot return to service shaft: ' .. tostring(backErr)) end
  if surfaceHeading ~= nil then turnTo(surfaceHeading) end

  if blockBelowIsBedrock() then
    print('Bedrock reached at service shaft.')
    break
  end

  local dug = true
  if turtle.detectDown() then
    dug = turtle.digDown()
    if not dug and blockBelowIsBedrock() then
      print('Bedrock reached at service shaft.')
      break
    elseif not dug then
      fail('cannot open next quarry layer')
    end
  end

  local moved, derr = down(false)
  if not moved then
    if blockBelowIsBedrock() then
      print('Bedrock reached at service shaft.')
      break
    end
    fail('cannot descend to next layer: ' .. tostring(derr))
  end
  depth = layer
end

print('Returning to NE surface service point...')
local rescued, rescueErr = returnToSurface()
if not rescued then fail(rescueErr) end
if surfaceHeading ~= nil then turnTo(surfaceHeading) end
setColor(colors.lime)
print(('QUARRY COMPLETE / SURFACE: X=%d Y=%d Z=%d'):format(pos.x, pos.y, pos.z))
setColor(colors.white)
