-- CCNexus Turtle Fleet Agent v0.3
-- Specialised moving-turtle agent: resilient GPS/dead reckoning, shared stations,
-- delivery, refuelling, quarry, crops and tree patrols.

local CONFIG = '/ccnexus/config.json'
local FLEET_CONFIG = '/ccnexus/turtle-fleet.json'
local VERSION = '0.3.0-fleet.1'

if not turtle then error('CCNexus Turtle Fleet Agent must run on a turtle.', 0) end
if not fs.exists(CONFIG) then error('CCNexus config missing. Run the normal CCNexus installer first.', 0) end

local h = fs.open(CONFIG, 'r')
local config = textutils.unserializeJSON(h.readAll())
h.close()
if type(config) ~= 'table' or not config.server or not config.token then error('Invalid CCNexus config.', 0) end

local running = true
local ws
local worldMeta = { id = config.worldId, name = config.worldName or 'Minecraft World' }
local job, lastJob
local lastSave = 0
local servicingFuel = false

local fleet = {
  stations = {},
  nav = { position = nil, heading = nil, source = 'none', lastGpsAt = 0, lastMoveAt = 0 },
  fuel = { low = 256, target = 2000, station = 'fuel', slot = 16 },
}

local function clamp(n, a, b) n = tonumber(n) or a; return math.max(a, math.min(b, n)) end
local function trim(v) return (tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function round(v) v = tonumber(v) or 0; if v >= 0 then return math.floor(v + 0.5) end; return math.ceil(v - 0.5) end
local function now() return os.epoch('utc') end

local function saveFleet(force)
  if not force and now() - lastSave < 1000 then return end
  if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
  local out = fs.open(FLEET_CONFIG, 'w')
  if out then out.write(textutils.serializeJSON(fleet)); out.close(); lastSave = now() end
end

if fs.exists(FLEET_CONFIG) then
  local f = fs.open(FLEET_CONFIG, 'r')
  local ok, saved = pcall(textutils.unserializeJSON, f.readAll())
  f.close()
  if ok and type(saved) == 'table' then
    if type(saved.stations) == 'table' then fleet.stations = saved.stations end
    if type(saved.nav) == 'table' then
      fleet.nav.position = saved.nav.position
      fleet.nav.heading = tonumber(saved.nav.heading)
      fleet.nav.source = saved.nav.source or fleet.nav.source
      fleet.nav.lastGpsAt = tonumber(saved.nav.lastGpsAt) or 0
      fleet.nav.lastMoveAt = tonumber(saved.nav.lastMoveAt) or 0
    end
    if type(saved.fuel) == 'table' then
      fleet.fuel.low = clamp(saved.fuel.low or 256, 1, 100000)
      fleet.fuel.target = clamp(saved.fuel.target or 2000, fleet.fuel.low, 1000000)
      fleet.fuel.station = trim(saved.fuel.station) ~= '' and trim(saved.fuel.station) or 'fuel'
      fleet.fuel.slot = clamp(saved.fuel.slot or 16, 1, 16)
    end
  end
end

local headingNames = { 'NORTH', 'EAST', 'SOUTH', 'WEST' }
local function headingName() return fleet.nav.heading ~= nil and headingNames[fleet.nav.heading + 1] or 'UNKNOWN' end

local function stationList()
  local out = {}
  for _, s in pairs(fleet.stations or {}) do table.insert(out, s) end
  table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return out
end

local function inventorySummary()
  local out = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then out[#out + 1] = { slot = i, name = d.name, displayName = d.displayName, count = d.count } end
  end
  return out
end

local function gpsFix(timeout)
  local x, y, z = gps.locate(timeout or 2, false)
  if not x then return nil end
  local p = { x = round(x), y = round(y), z = round(z) }
  fleet.nav.position = p
  fleet.nav.source = 'gps'
  fleet.nav.lastGpsAt = now()
  saveFleet(false)
  return p
end

local function currentPosition(tryGps)
  local p = tryGps == false and nil or gpsFix(2)
  if p then return { x = p.x, y = p.y, z = p.z, source = 'gps', gpsAvailable = true, lastGpsAt = fleet.nav.lastGpsAt, ageMs = 0 } end
  local cached = fleet.nav.position
  if not cached then return nil end
  local source = fleet.nav.heading ~= nil and fleet.nav.lastMoveAt > fleet.nav.lastGpsAt and 'dead_reckoning' or 'last_known'
  fleet.nav.source = source
  return { x = cached.x, y = cached.y, z = cached.z, source = source, gpsAvailable = false, lastGpsAt = fleet.nav.lastGpsAt, ageMs = math.max(0, now() - fleet.nav.lastGpsAt) }
end

local function updateMove(kind)
  local p = fleet.nav.position
  if not p then return end
  local hd = fleet.nav.heading
  if kind == 'up' then p.y = p.y + 1
  elseif kind == 'down' then p.y = p.y - 1
  elseif hd ~= nil then
    local sign = kind == 'back' and -1 or 1
    if hd == 0 then p.z = p.z - sign
    elseif hd == 1 then p.x = p.x + sign
    elseif hd == 2 then p.z = p.z + sign
    elseif hd == 3 then p.x = p.x - sign end
  end
  fleet.nav.lastMoveAt = now()
  fleet.nav.source = fleet.nav.lastGpsAt > 0 and 'dead_reckoning' or 'local'
  saveFleet(false)
end

local function turnRight()
  local ok, err = turtle.turnRight()
  if ok and fleet.nav.heading ~= nil then fleet.nav.heading = (fleet.nav.heading + 1) % 4; saveFleet(false) end
  return ok, err
end
local function turnLeft()
  local ok, err = turtle.turnLeft()
  if ok and fleet.nav.heading ~= nil then fleet.nav.heading = (fleet.nav.heading + 3) % 4; saveFleet(false) end
  return ok, err
end
local function turnTo(target)
  if fleet.nav.heading == nil then return false, 'heading unknown' end
  local diff = (target - fleet.nav.heading) % 4
  if diff == 3 then return turnLeft() end
  for _ = 1, diff do local ok, err = turnRight(); if not ok then return false, err end end
  return true
end

local function localRefuel(minimum)
  minimum = math.max(1, tonumber(minimum) or 1)
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

local function waitJob()
  while job and job.status == 'paused' do sleep(0.15) end
  return job == nil or job.status ~= 'stopping'
end

local function moveForward(dig)
  if not localRefuel(1) then return false, 'out of fuel' end
  local last = 'blocked'
  for _ = 1, dig and 20 or 1 do
    local ok, err = turtle.forward()
    if ok then updateMove('forward'); return true end
    last = err or last
    if not dig then break end
    if turtle.detect() then
      local dug, derr = turtle.dig(); if not dug and derr then last = derr end
    else turtle.attack() end
    sleep(0.05)
  end
  return false, last
end
local function moveBack()
  if not localRefuel(1) then return false, 'out of fuel' end
  local ok, err = turtle.back(); if ok then updateMove('back') end; return ok, err
end
local function moveUp(dig)
  if not localRefuel(1) then return false, 'out of fuel' end
  if dig and turtle.detectUp() then local ok, err = turtle.digUp(); if not ok then return false, err end end
  local ok, err = turtle.up(); if ok then updateMove('up') end; return ok, err
end
local function moveDown(dig)
  if not localRefuel(1) then return false, 'out of fuel' end
  if dig and turtle.detectDown() then local ok, err = turtle.digDown(); if not ok then return false, err end end
  local ok, err = turtle.down(); if ok then updateMove('down') end; return ok, err
end

local function calibrateHeading()
  local before = gpsFix(2)
  if not before then
    if fleet.nav.heading ~= nil and fleet.nav.position then return true end
    return false, 'GPS is required once to calibrate heading. Move back into GPS range or clear the last saved nav state.'
  end
  for attempt = 1, 4 do
    if not localRefuel(2) then return false, 'not enough fuel to calibrate heading' end
    local moved = turtle.forward()
    if moved then
      sleep(0.15)
      local after = gpsFix(2)
      local backed, backErr = turtle.back()
      if backed then fleet.nav.position = { x = before.x, y = before.y, z = before.z } else return false, 'could not return after heading calibration: ' .. tostring(backErr) end
      if not after then return false, 'lost GPS during heading calibration' end
      local dx, dz = after.x - before.x, after.z - before.z
      if math.abs(dx) >= math.abs(dz) and dx ~= 0 then fleet.nav.heading = dx > 0 and 1 or 3
      elseif dz ~= 0 then fleet.nav.heading = dz > 0 and 2 or 0
      else return false, 'GPS movement was too small to infer heading' end
      fleet.nav.lastMoveAt = now(); fleet.nav.source = 'gps'; saveFleet(true)
      return true
    end
    if attempt < 4 then turtle.turnRight() end
  end
  return false, 'all four horizontal sides are blocked; clear one block beside the turtle'
end

local function navigateTo(target, allowDig)
  if not target then return false, 'station/target is missing' end
  if fleet.nav.heading == nil then local ok, err = calibrateHeading(); if not ok then return false, err end end
  local p = currentPosition(true)
  if not p then return false, 'no GPS fix and no last-known position' end

  local tx, ty, tz = round(target.x), round(target.y or p.y), round(target.z)
  local function goVertical()
    while fleet.nav.position and fleet.nav.position.y < ty do if not waitJob() then return false, 'stopped' end; local ok, err = moveUp(allowDig); if not ok then return false, 'cannot move up: ' .. tostring(err) end end
    while fleet.nav.position and fleet.nav.position.y > ty do if not waitJob() then return false, 'stopped' end; local ok, err = moveDown(allowDig); if not ok then return false, 'cannot move down: ' .. tostring(err) end end
    return true
  end
  local ok, err = goVertical(); if not ok then return false, err end

  p = currentPosition(false)
  if p.x ~= tx then
    turnTo(p.x < tx and 1 or 3)
    for _ = 1, math.abs(tx - p.x) do if not waitJob() then return false, 'stopped' end; local moved, merr = moveForward(allowDig); if not moved then return false, 'X travel blocked: ' .. tostring(merr) end end
  end
  p = currentPosition(false)
  if p.z ~= tz then
    turnTo(p.z < tz and 2 or 0)
    for _ = 1, math.abs(tz - p.z) do if not waitJob() then return false, 'stopped' end; local moved, merr = moveForward(allowDig); if not moved then return false, 'Z travel blocked: ' .. tostring(merr) end end
  end

  local fresh = gpsFix(1.0)
  if fresh and (fresh.x ~= tx or fresh.y ~= ty or fresh.z ~= tz) then
    fleet.nav.position = fresh
    return false, ('GPS correction mismatch: expected %d,%d,%d but got %d,%d,%d'):format(tx, ty, tz, fresh.x, fresh.y, fresh.z)
  end
  return true
end

local function sideCall(side, action, count)
  side = tostring(side or 'down'):lower()
  local fn = action .. (side == 'up' and 'Up' or side == 'down' and 'Down' or '')
  local f = turtle[fn]
  if type(f) ~= 'function' then return false, 'unsupported turtle side ' .. side end
  return f(count)
end

local function suckCargo(side)
  local got = 0
  local reserve = fleet.fuel.slot
  for slot = 1, 16 do
    if slot ~= reserve and turtle.getItemCount(slot) == 0 then
      turtle.select(slot)
      local ok = sideCall(side, 'suck', 64)
      if ok then got = got + turtle.getItemCount(slot) end
    end
  end
  return got
end

local function dropCargo(side, keepSlots)
  keepSlots = keepSlots or {}
  local reserve = fleet.fuel.slot
  for slot = 1, 16 do
    if slot ~= reserve and not keepSlots[slot] and turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      local ok, err = sideCall(side, 'drop')
      if not ok then return false, 'destination chest rejected slot ' .. slot .. ': ' .. tostring(err or 'full') end
    end
  end
  return true
end

local function refuelFromStation(station)
  if servicingFuel then return false, 'fuel service recursion' end
  servicingFuel = true
  local returnPos = fleet.nav.position and { x = fleet.nav.position.x, y = fleet.nav.position.y, z = fleet.nav.position.z } or nil
  local returnHeading = fleet.nav.heading
  local ok, err = navigateTo(station, false)
  if not ok then servicingFuel = false; return false, 'cannot reach fuel depot: ' .. tostring(err) end

  local slot = fleet.fuel.slot
  turtle.select(slot)
  local tries = 0
  while tries < 16 do
    local level = turtle.getFuelLevel()
    if level == 'unlimited' or (tonumber(level) and tonumber(level) >= fleet.fuel.target) then break end
    if turtle.getItemCount(slot) == 0 then
      local sucked = sideCall(station.side or 'down', 'suck', 64)
      if not sucked then break end
    end
    if not turtle.refuel(0) then
      sideCall(station.side or 'down', 'drop')
      servicingFuel = false
      return false, 'fuel depot supplied a non-fuel item; use a dedicated fuel-only chest'
    end
    turtle.refuel(1)
    tries = tries + 1
  end

  local level = turtle.getFuelLevel()
  if not (level == 'unlimited' or (tonumber(level) and tonumber(level) >= fleet.fuel.low)) then servicingFuel = false; return false, 'fuel depot could not provide enough fuel' end
  if returnPos then local backOk, backErr = navigateTo(returnPos, false); if not backOk then servicingFuel = false; return false, 'refuelled but cannot return: ' .. tostring(backErr) end end
  if returnHeading ~= nil then turnTo(returnHeading) end
  servicingFuel = false
  return true
end

local function maybeServiceFuel(force)
  if servicingFuel then return true end
  local level = turtle.getFuelLevel()
  if level == 'unlimited' then return true end
  if not force and tonumber(level) and tonumber(level) >= fleet.fuel.low then return true end
  local station = fleet.stations[fleet.fuel.station]
  if not station then return localRefuel(fleet.fuel.low), 'shared fuel station not configured' end
  return refuelFromStation(station)
end

local function setJobFailure(reason)
  reason = tostring(reason or 'unknown failure')
  if job then job.error = reason; job.detail = reason end
  return false, reason
end

local matureAge = { ['minecraft:wheat'] = 7, ['minecraft:carrots'] = 7, ['minecraft:potatoes'] = 7, ['minecraft:beetroots'] = 3, ['minecraft:nether_wart'] = 3 }
local logs = {
  ['minecraft:oak_log']=true,['minecraft:spruce_log']=true,['minecraft:birch_log']=true,['minecraft:jungle_log']=true,
  ['minecraft:acacia_log']=true,['minecraft:dark_oak_log']=true,['minecraft:mangrove_log']=true,['minecraft:cherry_log']=true,
  ['minecraft:crimson_stem']=true,['minecraft:warped_stem']=true
}

local function farmCell(seedSlot)
  local ok, data = turtle.inspectDown()
  if ok and data then
    local need = matureAge[data.name]
    local age = data.state and tonumber(data.state.age)
    if need and age and age >= need then
      local dug, err = turtle.digDown(); if not dug then return false, err end
      turtle.select(seedSlot)
      turtle.placeDown()
    end
  end
  return true
end

local function harvestTreeAhead(saplingSlot)
  local ok, data = turtle.inspect()
  if not ok or not data or not logs[data.name] then return false end
  local dug, err = turtle.dig(); if not dug then return nil, err end
  local moved, merr = moveForward(false); if not moved then return nil, merr end
  local height = 0
  while height < 32 do
    local has, block = turtle.inspectUp()
    if not has or not block or not logs[block.name] then break end
    local cut, cerr = turtle.digUp(); if not cut then return nil, cerr end
    local up, uerr = moveUp(false); if not up then return nil, uerr end
    height = height + 1
  end
  for _ = 1, height do local down, derr = moveDown(false); if not down then return nil, derr end end
  local back, berr = moveBack(); if not back then return nil, berr end
  turtle.select(saplingSlot)
  turtle.place()
  return true
end

local function scanTreeCell(saplingSlot)
  for _ = 1, 4 do
    local found, err = harvestTreeAhead(saplingSlot)
    if found == nil then return false, err end
    turnRight()
  end
  return true
end

local function gridWalk(width, length, callback, digTravel)
  for row = 1, width do
    for col = 1, length do
      if not waitJob() then return false, 'stopped' end
      local ok, err = callback(row, col); if ok == false then return false, err end
      job.done = math.min(job.total or 1, (job.done or 0) + 1)
      if col < length then local moved, merr = moveForward(digTravel); if not moved then return false, merr end end
    end
    if row < width then
      if row % 2 == 1 then turnRight() else turnLeft() end
      local moved, merr = moveForward(digTravel); if not moved then return false, merr end
      if row % 2 == 1 then turnRight() else turnLeft() end
    end
  end
  return true
end

local function unloadAt(stationName, keepSlots)
  local station = fleet.stations[stationName or '']
  if not station then return true end
  local ok, err = navigateTo(station, false); if not ok then return false, err end
  return dropCargo(station.side or 'down', keepSlots)
end

local function deliveryWorker(spec)
  local source = fleet.stations[spec.sourceStation or 'quarry']
  local dest = fleet.stations[spec.destStation or 'base']
  if not source then return setJobFailure('source station not configured: ' .. tostring(spec.sourceStation or 'quarry')) end
  if not dest then return setJobFailure('destination station not configured: ' .. tostring(spec.destStation or 'base')) end
  local cycles = math.max(0, math.min(100000, tonumber(spec.cycles) or 0))
  local interval = clamp(spec.interval or 5, 0, 3600)
  job.total = cycles == 0 and 0 or cycles
  local n = 0
  while cycles == 0 or n < cycles do
    if not waitJob() then return false end
    local fuelOk, fuelErr = maybeServiceFuel(false); if not fuelOk and not localRefuel(32) then return setJobFailure(fuelErr or 'low fuel') end
    job.detail = 'Travelling to ' .. tostring(source.name)
    local ok, err = navigateTo(source, false); if not ok then return setJobFailure(err) end
    local got = suckCargo(source.side or 'down')
    if got > 0 then
      job.detail = 'Delivering ' .. got .. ' items to ' .. tostring(dest.name)
      ok, err = navigateTo(dest, false); if not ok then return setJobFailure(err) end
      ok, err = dropCargo(dest.side or 'down'); if not ok then return setJobFailure(err) end
      n = n + 1; job.done = n
    else
      job.detail = 'Quarry/source chest empty; waiting'
    end
    local waited = 0
    while waited < interval do if not waitJob() then return false end; sleep(math.min(1, interval - waited)); waited = waited + 1 end
  end
  job.detail = 'Delivery complete'
  return true
end

local function farmWorker(spec)
  local station = fleet.stations[spec.station or 'crop']
  if not station then return setJobFailure('crop station not configured') end
  local width, length = clamp(spec.width or 9, 1, 64), clamp(spec.length or 9, 1, 64)
  local seedSlot = clamp(spec.seedSlot or 15, 1, 16)
  local cycles = clamp(spec.cycles or 1, 1, 1000)
  local interval = clamp(spec.interval or 0, 0, 86400)
  job.total = width * length * cycles
  local ok, err = navigateTo(station, false); if not ok then return setJobFailure(err) end
  if fleet.nav.heading == nil then ok, err = calibrateHeading(); if not ok then return setJobFailure(err) end end
  local startHeading = station.heading ~= nil and tonumber(station.heading) or fleet.nav.heading
  if startHeading ~= nil then turnTo(startHeading) end
  local keep = { [seedSlot] = true }
  for cycle = 1, cycles do
    job.detail = ('Harvesting crop cycle %d/%d'):format(cycle, cycles)
    ok, err = gridWalk(width, length, function() return farmCell(seedSlot) end, false); if not ok then return setJobFailure(err) end
    ok, err = navigateTo(station, false); if not ok then return setJobFailure(err) end
    if startHeading ~= nil then turnTo(startHeading) end
    if spec.baseStation then ok, err = unloadAt(spec.baseStation, keep); if not ok then return setJobFailure(err) end; navigateTo(station, false); if startHeading ~= nil then turnTo(startHeading) end end
    local fuelOk, fuelErr = maybeServiceFuel(false); if not fuelOk and not localRefuel(32) then return setJobFailure(fuelErr) end
    if cycle < cycles and interval > 0 then local waited = 0; while waited < interval do if not waitJob() then return false end; sleep(math.min(1, interval-waited)); waited=waited+1 end end
  end
  job.detail = 'Crop job complete'
  return true
end

local function treeWorker(spec)
  local station = fleet.stations[spec.station or 'tree']
  if not station then return setJobFailure('tree station not configured') end
  local width, length = clamp(spec.width or 8, 1, 64), clamp(spec.length or 8, 1, 64)
  local saplingSlot = clamp(spec.saplingSlot or 15, 1, 16)
  job.total = width * length
  local ok, err = navigateTo(station, false); if not ok then return setJobFailure(err) end
  if fleet.nav.heading == nil then ok, err = calibrateHeading(); if not ok then return setJobFailure(err) end end
  local startHeading = station.heading ~= nil and tonumber(station.heading) or fleet.nav.heading
  if startHeading ~= nil then turnTo(startHeading) end
  job.detail = 'Patrolling for trees and replanting saplings'
  ok, err = gridWalk(width, length, function() return scanTreeCell(saplingSlot) end, false); if not ok then return setJobFailure(err) end
  ok, err = navigateTo(station, false); if not ok then return setJobFailure(err) end
  if spec.baseStation then local keep = { [saplingSlot] = true }; ok, err = unloadAt(spec.baseStation, keep); if not ok then return setJobFailure(err) end end
  job.detail = 'Tree patrol complete'
  return true
end

local function quarryCell()
  if turtle.detectDown() then local ok, err = turtle.digDown(); if not ok then return false, err end end
  return true
end

local function quarryWorker(spec)
  local width, length, depth = clamp(spec.width or 8, 1, 64), clamp(spec.length or 8, 1, 64), clamp(spec.depth or 8, 1, 128)
  if fleet.nav.heading == nil then local ok, err = calibrateHeading(); if not ok then return setJobFailure(err) end end
  local start = currentPosition(true); if not start then return setJobFailure('quarry needs one GPS/last-known position at start') end
  local startHeading = fleet.nav.heading
  job.total = width * length * depth
  local estimate = math.max(32, width * length * depth * 2)
  if not localRefuel(math.min(estimate, 512)) then
    local ok, err = maybeServiceFuel(true); if not ok then return setJobFailure(err or 'not enough fuel for quarry') end
  end
  for layer = 1, depth do
    job.detail = ('Mining layer %d/%d'):format(layer, depth)
    local ok, err = gridWalk(width, length, quarryCell, true); if not ok then return setJobFailure(err) end
    ok, err = navigateTo({ x = start.x, y = start.y - (layer - 1), z = start.z }, true); if not ok then return setJobFailure(err) end
    turnTo(startHeading)
    if layer < depth then local down, derr = moveDown(true); if not down then return setJobFailure(derr) end end
  end
  for _ = 1, depth - 1 do local up, err = moveUp(true); if not up then return setJobFailure(err) end end
  if spec.baseStation then local ok, err = unloadAt(spec.baseStation); if not ok then return setJobFailure(err) end end
  job.detail = 'Quarry complete'
  return true
end

local function telemetry()
  local pos = currentPosition(true)
  return {
    fleet = true,
    fleetVersion = VERSION,
    position = pos,
    nav = { heading = fleet.nav.heading, headingName = headingName(), source = pos and pos.source or fleet.nav.source, lastGpsAt = fleet.nav.lastGpsAt },
    fuel = turtle.getFuelLevel(),
    fuelPolicy = fleet.fuel,
    stations = stationList(),
    inventory = inventorySummary(),
    job = job and { type=job.type,status=job.status,done=job.done,total=job.total,detail=job.detail,error=job.error } or nil,
    lastJob = lastJob,
    storage = { items = {}, inventories = {} }, energy = {}, fluids = {}, ae2 = { bridges = {}, items = {}, energy = {} }
  }
end

local function peripherals()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = tostring(peripheral.getType(name) or 'unknown')
    local p = peripheral.wrap(name)
    local wireless = false
    if p and type(p.isWireless) == 'function' then local ok, v = pcall(p.isWireless); wireless = ok and v or false end
    out[#out+1] = { name=name,type=ptype,wireless=wireless,speaker=false,monitor=ptype:lower():find('monitor') ~= nil }
  end
  return out
end

local function send(obj) if ws then pcall(function() ws.send(textutils.serializeJSON(obj)) end) end end
local function sendTelemetry() send({ type='telemetry', agentVersion=VERSION, label=config.label, kind='turtle', peripherals=peripherals(), telemetry=telemetry() }) end

local function render()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
  if term.isColor() then term.setBackgroundColor(colors.blue) end
  print((' CCNEXUS TURTLE FLEET %-12s'):format(VERSION))
  term.setBackgroundColor(colors.black)
  local p = currentPosition(false)
  print('')
  print('Node:   ' .. tostring(config.label or ('Turtle '..os.getComputerID())))
  print('World:  ' .. tostring(worldMeta.name or config.worldName or '-'))
  print('Nexus:  ' .. (ws and 'ONLINE' or 'OFFLINE'))
  print('Fuel:   ' .. tostring(turtle.getFuelLevel()) .. '  low=' .. tostring(fleet.fuel.low))
  print('GPS:    ' .. (p and string.upper(tostring(p.source)) or 'UNAVAILABLE'))
  if p then print(('Pos:    %d, %d, %d'):format(p.x,p.y,p.z)) else print('Pos:    no last-known position') end
  print('Facing: ' .. headingName())
  print('Stations: ' .. tostring(#stationList()))
  print('')
  if job then
    print(('JOB: %s / %s'):format(tostring(job.type):upper(), tostring(job.status):upper()))
    print(('Progress: %s/%s'):format(tostring(job.done or 0), tostring(job.total or 0)))
    print(tostring(job.detail or ''))
  elseif lastJob then print(('Last: %s / %s'):format(tostring(lastJob.type), tostring(lastJob.status)))
  else print('JOB: IDLE') end
end

local function handleCommand(c)
  local t = tostring(c.type or '')
  if t == 'reboot' then render(); sleep(0.2); os.reboot()
  elseif t == 'scan_now' then sendTelemetry()
  elseif t == 'station_set' then
    local name = trim(c.name):lower():gsub('[^%w_.%-]', '_')
    if name ~= '' and tonumber(c.x) and tonumber(c.z) then
      fleet.stations[name] = { name=name,label=trim(c.label) ~= '' and trim(c.label) or name,type=trim(c.stationType) ~= '' and trim(c.stationType) or name,x=round(c.x),y=round(c.y or 0),z=round(c.z),side=({up=true,down=true,front=true})[tostring(c.side)] and tostring(c.side) or 'down',heading=c.heading ~= nil and tonumber(c.heading) or nil }
      saveFleet(true); send({type='event',message='Station saved: '..name}); sendTelemetry()
    end
  elseif t == 'station_delete' then fleet.stations[trim(c.name):lower()] = nil; saveFleet(true); sendTelemetry()
  elseif t == 'fleet_config' then
    if c.lowFuel ~= nil then fleet.fuel.low = clamp(c.lowFuel,1,100000) end
    if c.targetFuel ~= nil then fleet.fuel.target = clamp(c.targetFuel,fleet.fuel.low,1000000) end
    if trim(c.fuelStation) ~= '' then fleet.fuel.station = trim(c.fuelStation):lower() end
    if c.fuelSlot ~= nil then fleet.fuel.slot = clamp(c.fuelSlot,1,16) end
    saveFleet(true); sendTelemetry()
  elseif t == 'refuel_now' then os.queueEvent('ccnexus_fleet_job',{type='refuel'})
  elseif t == 'delivery_start' or t == 'farm_start' or t == 'tree_farm_start' or t == 'tree_patrol_start' or t == 'quarry_start' then
    if job then send({type='event',message='A turtle job is already active'}) else local spec={}; for k,v in pairs(c) do spec[k]=v end; if t=='tree_farm_start' then spec.type='tree_patrol_start' else spec.type=t end; os.queueEvent('ccnexus_fleet_job',spec) end
  elseif (t == 'job_pause' or t == 'quarry_pause') and job then job.status='paused'; job.detail='Paused from dashboard'
  elseif t == 'job_resume' and job and job.status == 'paused' then job.status='running'; job.detail='Resumed from dashboard'
  elseif (t == 'job_stop' or t == 'quarry_stop') and job then job.status='stopping'; job.detail='Stopping...'
  end
  render()
end

local function jobLoop()
  while running do
    local _, spec = os.pullEvent('ccnexus_fleet_job')
    job = spec; job.status='running'; job.done=0; job.total=1; job.error=nil; job.detail='Starting'
    send({type='event',message='Started '..tostring(job.type)})
    local ok, result, err = pcall(function()
      if spec.type == 'refuel' then local r,e = maybeServiceFuel(true); return r,e
      elseif spec.type == 'delivery_start' then return deliveryWorker(spec)
      elseif spec.type == 'farm_start' then return farmWorker(spec)
      elseif spec.type == 'tree_patrol_start' then return treeWorker(spec)
      elseif spec.type == 'quarry_start' then return quarryWorker(spec)
      end
      return false, 'unknown fleet job: '..tostring(spec.type)
    end)
    if not ok then result=false; err=tostring(result) end
    local status
    if job.status == 'stopping' then status='stopped'
    elseif result then status='complete'
    else status='failed'; job.error = job.error or tostring(err or job.detail or 'job failed'); job.detail=job.error end
    job.status=status
    lastJob={type=job.type,status=status,done=job.done,total=job.total,detail=job.detail,error=job.error,at=now()}
    sendTelemetry(); send({type='event',message=(status=='complete' and 'Completed ' or status=='failed' and 'Failed ' or 'Stopped ')..tostring(job.type)..(job.error and (': '..job.error) or ''),job=lastJob})
    render(); sleep(2); job=nil; render()
  end
end

local function socketLoop()
  while running do
    local url = config.server:gsub('^http://','ws://'):gsub('^https://','wss://') .. '/ws/device?token=' .. textutils.urlEncode(config.token)
    local conn, err = http.websocket({url=url,timeout=15})
    if not conn then ws=nil; render(); sleep(4)
    else
      ws=conn; sendTelemetry(); render()
      while running and ws == conn do
        local raw, why = conn.receive(25)
        if raw then
          local msg = textutils.unserializeJSON(raw)
          if type(msg)=='table' then
            if msg.type=='hello' and msg.world then worldMeta=msg.world; render()
            elseif msg.type=='command' and type(msg.command)=='table' then handleCommand(msg.command) end
          end
        elseif why and why ~= 'Timed out' then break end
      end
      pcall(function() conn.close() end); ws=nil; render(); sleep(2)
    end
  end
end

local function heartbeat()
  while running do sleep(3); render(); if ws then sendTelemetry() end end
end

render()
parallel.waitForAny(socketLoop, heartbeat, jobLoop)
