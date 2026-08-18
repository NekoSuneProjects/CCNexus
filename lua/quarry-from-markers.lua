-- CCNexus Quarry From Markers
--
-- Discovers CCNexus quarry survey markers over a Wireless Modem, maps their
-- GPS positions, automatically derives the quarry footprint, calibrates turtle
-- heading with GPS, travels to the inside corner, and mines the marked area.
--
-- Requirements:
--   * Mining/Advanced Turtle with a Wireless Modem
--   * Working CC:Tweaked GPS constellation
--   * At least two quarry-marker.lua beacons with distinct X and Z positions
--     (four corner markers are strongly recommended)
--
-- Usage:
--   quarry-from-markers.lua Quarry1 8
--   quarry-from-markers.lua Quarry1 8 1
--
-- Arguments:
--   1: quarry name
--   2: depth (default 8)
--   3: inset from marker boundary (default 1)
--
-- Markers are normally placed one block outside the area to mine, so inset=1
-- keeps the marker computers safe.

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

local function setColor(c)
  if term.isColor and term.isColor() then term.setTextColor(c) end
end

local function fail(msg)
  setColor(colors.red)
  print('ERROR: ' .. tostring(msg))
  setColor(colors.white)
  return false, msg
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
if not modem then error('Attach a Wireless Modem to this turtle.', 0) end
modem.open(CHANNEL)

local function gpsPosition(timeout)
  local x, y, z = gps.locate(timeout or 2, false)
  if not x then return nil end
  return { x = round(x), y = round(y), z = round(z), rawX = x, rawY = y, rawZ = z }
end

local function ensureFuel(minimum)
  minimum = math.max(1, tonumber(minimum) or 1)
  local level = turtle.getFuelLevel()
  if level == 'unlimited' then return true end
  if tonumber(level) and tonumber(level) >= minimum then return true end

  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if turtle.refuel(0) then
        while turtle.getItemCount(slot) > 0 do
          local now = turtle.getFuelLevel()
          if now == 'unlimited' or (tonumber(now) and tonumber(now) >= minimum) then break end
          if not turtle.refuel(1) then break end
        end
      end
    end
    local now = turtle.getFuelLevel()
    if now == 'unlimited' or (tonumber(now) and tonumber(now) >= minimum) then break end
  end
  turtle.select(selected)
  level = turtle.getFuelLevel()
  return level == 'unlimited' or (tonumber(level) and tonumber(level) >= minimum)
end

local function parseMarker(message)
  if type(message) ~= 'string' then return nil end
  local ok, data = pcall(textutils.unserializeJSON, message)
  if not ok or type(data) ~= 'table' or data.protocol ~= PROTOCOL then return nil end
  if trim(data.quarry) == '' or tonumber(data.x) == nil or tonumber(data.z) == nil then return nil end
  return {
    quarry = trim(data.quarry), marker = trim(data.marker),
    computerId = tonumber(data.computerId),
    x = round(data.x), y = round(data.y), z = round(data.z),
    timestamp = tonumber(data.timestamp) or 0
  }
end

local function discover(seconds)
  seconds = tonumber(seconds) or 6
  local sets = {}
  local timer = os.startTimer(seconds)
  while true do
    local event = { os.pullEvent() }
    if event[1] == 'timer' and event[2] == timer then break end
    if event[1] == 'modem_message' and event[3] == CHANNEL then
      local marker = parseMarker(event[5])
      if marker then
        sets[marker.quarry] = sets[marker.quarry] or {}
        local key = tostring(marker.computerId or marker.marker or (marker.x .. ':' .. marker.z))
        sets[marker.quarry][key] = marker
      end
    end
  end
  return sets
end

local function listFromSet(set)
  local out = {}
  for _, marker in pairs(set or {}) do table.insert(out, marker) end
  table.sort(out, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    return tostring(a.marker) < tostring(b.marker)
  end)
  return out
end

local function bounds(markers, inset)
  local minX, maxX, minZ, maxZ
  for _, m in ipairs(markers) do
    minX = minX and math.min(minX, m.x) or m.x
    maxX = maxX and math.max(maxX, m.x) or m.x
    minZ = minZ and math.min(minZ, m.z) or m.z
    maxZ = maxZ and math.max(maxZ, m.z) or m.z
  end
  if not minX or minX == maxX or minZ == maxZ then return nil, 'Markers must span at least two distinct X positions and two distinct Z positions.' end
  local startX, endX = minX + inset, maxX - inset
  local startZ, endZ = minZ + inset, maxZ - inset
  if startX > endX or startZ > endZ then return nil, 'Inset is too large for this marker rectangle.' end
  return {
    markerMinX = minX, markerMaxX = maxX, markerMinZ = minZ, markerMaxZ = maxZ,
    minX = startX, maxX = endX, minZ = startZ, maxZ = endZ,
    length = endX - startX + 1,
    width = endZ - startZ + 1
  }
end

local firstMonitor
for _, name in ipairs(peripheral.getNames()) do
  if tostring(peripheral.getType(name) or ''):lower():find('monitor') then
    firstMonitor = peripheral.wrap(name)
    if firstMonitor then break end
  end
end

local mapState = { quarry = '-', markers = {}, area = nil, turtle = nil, status = 'DISCOVERING', detail = '', done = 0, total = 0 }

local function drawMonitor()
  local mon = firstMonitor
  if not mon then return end
  pcall(function()
    mon.setTextScale(0.5)
    if mon.isColor and mon.isColor() then mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white) end
    mon.clear()
    local w, h = mon.getSize()
    mon.setCursorPos(1, 1)
    if mon.isColor and mon.isColor() then mon.setBackgroundColor(colors.blue); mon.setTextColor(colors.white) end
    mon.write((' CCNEXUS QUARRY GPS ' .. tostring(mapState.quarry) .. string.rep(' ', w)):sub(1, w))
    if mon.isColor and mon.isColor() then mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white) end
    mon.setCursorPos(2, 3); mon.write('STATUS: ' .. tostring(mapState.status))
    mon.setCursorPos(2, 4); mon.write(('PROGRESS: %d/%d'):format(mapState.done or 0, mapState.total or 0))

    local area = mapState.area
    if area and w >= 30 and h >= 12 then
      local left, top = 2, 6
      local mapW, mapH = math.max(8, w - 4), math.max(4, h - 9)
      local spanX = math.max(1, area.markerMaxX - area.markerMinX)
      local spanZ = math.max(1, area.markerMaxZ - area.markerMinZ)
      local function screen(x, z)
        local sx = left + math.floor((x - area.markerMinX) / spanX * (mapW - 1))
        local sy = top + math.floor((z - area.markerMinZ) / spanZ * (mapH - 1))
        return sx, sy
      end
      for x = area.minX, area.maxX do
        local sx1, sy1 = screen(x, area.minZ)
        local sx2, sy2 = screen(x, area.maxZ)
        mon.setCursorPos(sx1, sy1); mon.write('.')
        mon.setCursorPos(sx2, sy2); mon.write('.')
      end
      for z = area.minZ, area.maxZ do
        local sx1, sy1 = screen(area.minX, z)
        local sx2, sy2 = screen(area.maxX, z)
        mon.setCursorPos(sx1, sy1); mon.write('.')
        mon.setCursorPos(sx2, sy2); mon.write('.')
      end
      for _, m in ipairs(mapState.markers or {}) do
        local sx, sy = screen(m.x, m.z)
        mon.setCursorPos(sx, sy)
        if mon.isColor and mon.isColor() then mon.setTextColor(colors.yellow) end
        mon.write('M')
      end
      if mapState.turtle then
        local sx, sy = screen(mapState.turtle.x, mapState.turtle.z)
        mon.setCursorPos(sx, sy)
        if mon.isColor and mon.isColor() then mon.setTextColor(colors.lime) end
        mon.write('T')
      end
      if mon.isColor and mon.isColor() then mon.setTextColor(colors.lightGray) end
      mon.setCursorPos(2, h - 1); mon.write(tostring(mapState.detail or ''):sub(1, math.max(0, w - 2)))
    end
  end)
end

local function printMapSummary(quarryName, markers, area, pos)
  term.clear(); term.setCursorPos(1, 1)
  setColor(colors.cyan); print('CCNexus Marker Quarry'); print('====================='); setColor(colors.white)
  print('')
  print('Quarry: ' .. quarryName)
  print('Markers found: ' .. #markers)
  for _, m in ipairs(markers) do
    print(('  %-8s #%s  X=%d Y=%d Z=%d'):format(m.marker ~= '' and m.marker or 'marker', tostring(m.computerId or '?'), m.x, m.y, m.z))
  end
  print('')
  print(('Marker bounds: X %d..%d / Z %d..%d'):format(area.markerMinX, area.markerMaxX, area.markerMinZ, area.markerMaxZ))
  print(('Mine bounds:   X %d..%d / Z %d..%d'):format(area.minX, area.maxX, area.minZ, area.maxZ))
  print(('Auto size:     %d x %d blocks'):format(area.length, area.width))
  if pos then print(('Turtle GPS:    X=%d Y=%d Z=%d'):format(pos.x, pos.y, pos.z)) end
  print('')
end

-- Heading: 0=N(-Z), 1=E(+X), 2=S(+Z), 3=W(-X)
local heading
local headingName = { 'NORTH', 'EAST', 'SOUTH', 'WEST' }

local function turnRight()
  turtle.turnRight()
  if heading ~= nil then heading = (heading + 1) % 4 end
end

local function turnLeft()
  turtle.turnLeft()
  if heading ~= nil then heading = (heading + 3) % 4 end
end

local function turnTo(target)
  if heading == nil then return false end
  local diff = (target - heading) % 4
  if diff == 3 then turnLeft()
  else for _ = 1, diff do turnRight() end end
  return true
end

local function calibrateHeading()
  local before = gpsPosition(2)
  if not before then return false, 'GPS fix unavailable during heading calibration.' end
  for attempt = 1, 4 do
    if not ensureFuel(2) then return false, 'Not enough fuel to calibrate heading.' end
    local moved, moveErr = turtle.forward()
    if moved then
      sleep(0.15)
      local after = gpsPosition(2)
      local backed, backErr = turtle.back()
      if not backed then return false, 'Calibration moved forward but could not move back: ' .. tostring(backErr) end
      if not after then return false, 'Lost GPS fix during heading calibration.' end
      local dx, dz = after.x - before.x, after.z - before.z
      if math.abs(dx) >= math.abs(dz) and dx ~= 0 then heading = dx > 0 and 1 or 3
      elseif dz ~= 0 then heading = dz > 0 and 2 or 0
      else return false, 'GPS position did not change enough to infer heading.' end
      return true
    end
    if attempt < 4 then turnRight() end
  end
  return false, 'The turtle is blocked on all four sides; clear one adjacent block for GPS heading calibration.'
end

local function travelForward()
  if not ensureFuel(1) then return false, 'Out of fuel while travelling.' end
  local ok, err = turtle.forward()
  if not ok then return false, 'Travel path blocked: ' .. tostring(err or 'cannot move forward') end
  return true
end

local function travelTo(targetX, targetZ)
  local pos = gpsPosition(2)
  if not pos then return false, 'GPS unavailable while navigating to quarry.' end
  mapState.turtle = pos; drawMonitor()

  if pos.x ~= targetX then
    turnTo(pos.x < targetX and 1 or 3)
    for _ = 1, math.abs(targetX - pos.x) do
      local ok, err = travelForward(); if not ok then return false, err end
    end
  end
  pos = gpsPosition(2) or pos
  if pos.z ~= targetZ then
    turnTo(pos.z < targetZ and 2 or 0)
    for _ = 1, math.abs(targetZ - pos.z) do
      local ok, err = travelForward(); if not ok then return false, err end
    end
  end
  local final = gpsPosition(2)
  if final and (final.x ~= targetX or final.z ~= targetZ) then
    return false, ('Navigation mismatch: expected %d,%d but GPS reports %d,%d'):format(targetX, targetZ, final.x, final.z)
  end
  mapState.turtle = final or { x = targetX, z = targetZ }; drawMonitor()
  return true
end

local function mineForward()
  if not ensureFuel(1) then return false, 'Out of fuel while mining.' end
  local lastErr = 'blocked'
  for _ = 1, 20 do
    local moved, err = turtle.forward()
    if moved then return true end
    if err then lastErr = err end
    if turtle.detect() then
      local dug, digErr = turtle.dig()
      if not dug and digErr then lastErr = digErr end
    else
      turtle.attack()
    end
    sleep(0.05)
  end
  return false, 'Cannot mine/move forward: ' .. tostring(lastErr)
end

local function mineCell()
  if turtle.detectDown() then
    local dug, err = turtle.digDown()
    if not dug then return false, 'Cannot mine block below: ' .. tostring(err or 'dig failed') end
  end
  return true
end

local function updateProgress(detail)
  mapState.detail = detail or mapState.detail
  local pos = gpsPosition(0.25)
  if pos then mapState.turtle = pos end
  drawMonitor()
end

local function mineLayer(area, layer)
  -- Start at north-west inside corner and face east.
  turnTo(1)
  for row = 1, area.width do
    for col = 1, area.length do
      local ok, err = mineCell(); if not ok then return false, err end
      mapState.done = mapState.done + 1
      if mapState.done % 4 == 0 then updateProgress(('Layer %d row %d/%d'):format(layer, row, area.width)) end
      if col < area.length then
        local moved, moveErr = mineForward(); if not moved then return false, moveErr end
      end
    end
    if row < area.width then
      if row % 2 == 1 then turnRight() else turnLeft() end
      local moved, moveErr = mineForward(); if not moved then return false, moveErr end
      if row % 2 == 1 then turnRight() else turnLeft() end
    end
  end
  return true
end

local quarryName = trim(args[1])
local depth = math.max(1, math.min(128, tonumber(args[2]) or 8))
local inset = math.max(0, math.min(16, tonumber(args[3]) or 1))

print('Scanning quarry marker channel ' .. CHANNEL .. ' for 6 seconds...')
local sets = discover(6)

if quarryName == '' then
  local names = {}
  for name in pairs(sets) do table.insert(names, name) end
  table.sort(names)
  if #names == 0 then error('No CCNexus quarry markers discovered.', 0) end
  print('Discovered quarry marker sets:')
  for i, name in ipairs(names) do print(('  [%d] %s (%d markers)'):format(i, name, #listFromSet(sets[name]))) end
  write('Choose quarry [1]: ')
  local choice = tonumber(trim(read())) or 1
  quarryName = names[math.max(1, math.min(#names, choice))]
end

local markers = listFromSet(sets[quarryName])
if #markers < 2 then error('Need at least two markers for ' .. quarryName .. '; four corners are recommended.', 0) end
local area, areaErr = bounds(markers, inset)
if not area then error(areaErr, 0) end

local pos = gpsPosition(2)
if not pos then error('Turtle has no GPS fix. Run `gps locate` first.', 0) end
mapState.quarry = quarryName; mapState.markers = markers; mapState.area = area; mapState.turtle = pos; mapState.status = 'READY'; mapState.total = area.length * area.width * depth; drawMonitor()

printMapSummary(quarryName, markers, area, pos)
print('Depth:         ' .. depth .. ' block layer(s)')
print('Marker inset:  ' .. inset .. ' block(s)')
print('')
setColor(colors.yellow)
print('SAFETY: The turtle will travel horizontally to the north-west')
print('inside quarry corner. Keep that path clear. It will not dig')
print('obstacles while travelling to the quarry.')
setColor(colors.white)
print('')
write('Start this marked quarry? [y/N]: ')
local answer = trim(read()):lower()
if answer ~= 'y' and answer ~= 'yes' then print('Cancelled.'); return end

mapState.status = 'CALIBRATING'; mapState.detail = 'Calibrating turtle heading with GPS'; drawMonitor()
local calibrated, calibrationErr = calibrateHeading()
if not calibrated then error(calibrationErr, 0) end

setColor(colors.lime)
print('Heading calibrated: ' .. headingName[heading + 1])
setColor(colors.white)

mapState.status = 'NAVIGATING'; mapState.detail = ('Travelling to X=%d Z=%d'):format(area.minX, area.minZ); drawMonitor()
local navigated, navErr = travelTo(area.minX, area.minZ)
if not navigated then error(navErr, 0) end
turnTo(1)

local startSurface = gpsPosition(2)
if not startSurface then error('Lost GPS fix at quarry start.', 0) end
local descended = 0
mapState.status = 'MINING'; drawMonitor()

for layer = 1, depth do
  mapState.detail = ('Mining layer %d/%d'):format(layer, depth); drawMonitor()
  local ok, err = mineLayer(area, layer)
  if not ok then mapState.status = 'FAILED'; mapState.detail = err; drawMonitor(); error(err, 0) end

  -- GPS navigation through the already-cleared layer returns to the start.
  local returned, returnErr = travelTo(area.minX, area.minZ)
  if not returned then mapState.status = 'FAILED'; mapState.detail = returnErr; drawMonitor(); error(returnErr, 0) end
  turnTo(1)

  if layer < depth then
    if turtle.detectDown() then
      local dug, digErr = turtle.digDown()
      if not dug then error('Cannot open next layer: ' .. tostring(digErr or 'dig failed'), 0) end
    end
    if not ensureFuel(1) then error('Out of fuel before descending.', 0) end
    local down, downErr = turtle.down()
    if not down then error('Cannot descend to next layer: ' .. tostring(downErr or 'blocked'), 0) end
    descended = descended + 1
  end
end

-- Return to the original surface level through the mined start column.
mapState.status = 'RETURNING'; mapState.detail = 'Returning to quarry surface'; drawMonitor()
for _ = 1, descended do
  if not ensureFuel(1) then error('Out of fuel while returning to surface.', 0) end
  local up, upErr = turtle.up()
  if not up then error('Cannot return to surface: ' .. tostring(upErr or 'blocked'), 0) end
end
turnTo(1)
mapState.turtle = gpsPosition(2) or mapState.turtle
mapState.status = 'COMPLETE'; mapState.detail = ('Quarry complete: %d x %d x %d'):format(area.length, area.width, depth); drawMonitor()

setColor(colors.lime)
print('')
print(('QUARRY COMPLETE: %d x %d x %d'):format(area.length, area.width, depth))
print(('Start waypoint: X=%d Z=%d'):format(area.minX, area.minZ))
setColor(colors.white)
