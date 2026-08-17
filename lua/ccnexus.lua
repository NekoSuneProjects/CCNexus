local CONFIG = '/ccnexus/config.json'
if not fs.exists(CONFIG) then error('CCNexus config missing. Run the installer again.', 0) end
local cf = fs.open(CONFIG, 'r')
local config = textutils.unserializeJSON(cf.readAll())
cf.close()

local running = true
local ws
local job = nil
local worldMeta = { id = config.worldId, name = config.worldName or 'Minecraft World' }
local monitorPage = config.monitorPage or 'overview'
local cachedTelemetry = { storage = { items = {}, inventories = {} }, energy = {}, fluids = {}, ae2 = { bridges = {}, items = {} } }
local lastDeepScan = 0

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64decode(data)
  data = string.gsub(data, '[^' .. b64chars .. '=]', '')
  return (data:gsub('.', function(x)
    if x == '=' then return '' end
    local r, f = '', (b64chars:find(x) - 1)
    for i = 6, 1, -1 do r = r .. (f % 2^i - f % 2^(i - 1) > 0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2^(8 - i) or 0) end
    return string.char(c)
  end))
end

local function methodSet(name)
  local set = {}
  local ok, methods = pcall(peripheral.getMethods, name)
  if ok and type(methods) == 'table' then for _, m in ipairs(methods) do set[m] = true end end
  return set
end

local function getType(name)
  local ok, t = pcall(peripheral.getType, name)
  return ok and tostring(t or 'unknown') or 'unknown'
end

local function call(name, method, ...)
  local args = { ... }
  return pcall(function() return peripheral.call(name, method, table.unpack(args)) end)
end

local function describePeripherals()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local methods = methodSet(name)
    local ptype = getType(name)
    local lower = ptype:lower()
    table.insert(out, {
      name = name,
      type = ptype,
      speaker = methods.playAudio == true,
      monitor = methods.setCursorPos == true and methods.write == true and lower:find('monitor') ~= nil,
      inventory = methods.list == true and methods.size == true,
      energy = methods.getEnergy == true and methods.getEnergyCapacity == true,
      fluid = methods.tanks == true,
      ae2 = (lower == 'mebridge' or lower == 'me_bridge' or (methods.listItems and methods.craftItem)) and true or false
    })
  end
  return out
end

local function getSpeakers()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local methods = methodSet(name)
    if methods.playAudio then table.insert(out, { name = name, p = peripheral.wrap(name) }) end
  end
  return out
end

local function position()
  local x, y, z = gps.locate(0.5, false)
  if x then return { x = math.floor(x * 100) / 100, y = math.floor(y * 100) / 100, z = math.floor(z * 100) / 100 } end
end

local function turtleInventory()
  if not turtle then return nil end
  local slots = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then slots[i] = { name = d.name, count = d.count, displayName = d.displayName } end
  end
  return slots
end

local function compactItems(map, limit)
  local list = {}
  for name, item in pairs(map) do table.insert(list, { name = name, displayName = item.displayName or name, count = item.count, amount = item.amount, isCraftable = item.isCraftable }) end
  table.sort(list, function(a, b) return (a.count or a.amount or 0) > (b.count or b.amount or 0) end)
  while #list > limit do table.remove(list) end
  return list
end

local function deepScan()
  local itemMap, inventories, energy, fluids = {}, {}, {}, {}
  local ae = { bridges = {}, items = {}, energy = {} }
  local aeMap, craftable = {}, {}

  for _, name in ipairs(peripheral.getNames()) do
    local methods = methodSet(name)
    local ptype = getType(name)
    local lower = ptype:lower()

    if methods.list and methods.size then
      local ok, items = call(name, 'list')
      local slots, total = 0, 0
      if ok and type(items) == 'table' then
        for _, item in pairs(items) do
          if item and item.name then
            slots = slots + 1
            total = total + (tonumber(item.count) or 0)
            local e = itemMap[item.name] or { count = 0, displayName = item.displayName }
            e.count = e.count + (tonumber(item.count) or 0)
            itemMap[item.name] = e
          end
        end
      end
      local okSize, size = call(name, 'size')
      table.insert(inventories, { name = name, type = ptype, slots = okSize and size or nil, usedSlots = slots, itemCount = total })
    end

    if methods.getEnergy and methods.getEnergyCapacity then
      local okE, stored = call(name, 'getEnergy')
      local okC, capacity = call(name, 'getEnergyCapacity')
      if okE and okC then table.insert(energy, { name = name, type = ptype, energy = tonumber(stored) or 0, capacity = tonumber(capacity) or 0 }) end
    end

    if methods.tanks then
      local ok, tanks = call(name, 'tanks')
      if ok and type(tanks) == 'table' then
        local amount, names = 0, {}
        for _, tank in pairs(tanks) do
          if tank then
            amount = amount + (tonumber(tank.amount) or 0)
            if tank.name then names[tank.name] = true end
          end
        end
        local list = {}; for fluidName in pairs(names) do table.insert(list, fluidName) end
        table.insert(fluids, { name = name, type = ptype, amount = amount, fluids = list })
      end
    end

    local isAe = lower == 'mebridge' or lower == 'me_bridge' or (methods.listItems and methods.craftItem)
    if isAe then
      local bridge = { name = name, type = ptype, online = true }
      if methods.isConnected then local ok, v = call(name, 'isConnected'); if ok then bridge.online = not not v end end
      if methods.isOnline then local ok, v = call(name, 'isOnline'); if ok then bridge.online = not not v end end
      table.insert(ae.bridges, bridge)

      if methods.listCraftableItems then
        local ok, list = call(name, 'listCraftableItems')
        if ok and type(list) == 'table' then for _, it in pairs(list) do if it and it.name then craftable[it.name] = true end end end
      end
      if methods.listItems then
        local ok, list = call(name, 'listItems')
        if ok and type(list) == 'table' then
          for _, it in pairs(list) do
            if it and it.name then
              local amount = tonumber(it.amount or it.count) or 0
              local e = aeMap[it.name] or { amount = 0, displayName = it.displayName, isCraftable = false }
              e.amount = e.amount + amount
              e.displayName = e.displayName or it.displayName
              e.isCraftable = e.isCraftable or it.isCraftable == true
              aeMap[it.name] = e
            end
          end
        end
      end

      local stored, capacity, usage
      if methods.getStoredEnergy then local ok, v = call(name, 'getStoredEnergy'); if ok then stored = tonumber(v) end
      elseif methods.getEnergyStorage then local ok, v = call(name, 'getEnergyStorage'); if ok then stored = tonumber(v) end end
      if methods.getEnergyCapacity then local ok, v = call(name, 'getEnergyCapacity'); if ok then capacity = tonumber(v) end
      elseif methods.getMaxEnergyStorage then local ok, v = call(name, 'getMaxEnergyStorage'); if ok then capacity = tonumber(v) end end
      if methods.getEnergyUsage then local ok, v = call(name, 'getEnergyUsage'); if ok then usage = tonumber(v) end end
      if stored then ae.energy.stored = (ae.energy.stored or 0) + stored end
      if capacity then ae.energy.capacity = (ae.energy.capacity or 0) + capacity end
      if usage then ae.energy.usage = (ae.energy.usage or 0) + usage end
    end
  end

  for name, v in pairs(aeMap) do if craftable[name] then v.isCraftable = true end end
  ae.items = compactItems(aeMap, 750)
  cachedTelemetry.storage = { items = compactItems(itemMap, 500), inventories = inventories }
  cachedTelemetry.energy = energy
  cachedTelemetry.fluids = fluids
  cachedTelemetry.ae2 = ae
  lastDeepScan = os.epoch('utc')
end

local function telemetry()
  if os.epoch('utc') - lastDeepScan > 15000 then deepScan() end
  local fuel = turtle and turtle.getFuelLevel() or nil
  return {
    position = position(), fuel = fuel, inventory = turtleInventory(),
    job = job and { type = job.type, status = job.status, done = job.done, total = job.total, detail = job.detail, width = job.width, length = job.length, depth = job.depth } or nil,
    storage = cachedTelemetry.storage, energy = cachedTelemetry.energy, fluids = cachedTelemetry.fluids, ae2 = cachedTelemetry.ae2,
    monitorPage = monitorPage
  }
end

local function send(obj)
  if ws then pcall(function() ws.send(textutils.serializeJSON(obj)) end) end
end

local function writeAt(mon, x, y, text, color)
  local w = select(1, mon.getSize())
  if y < 1 then return end
  mon.setCursorPos(math.max(1, x), y)
  if color and mon.isColor and mon.isColor() then mon.setTextColor(color) end
  mon.write(tostring(text):sub(1, math.max(0, w - x + 1)))
end

local function formatNumber(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then return string.format('%.1fB', n / 1000000000) end
  if n >= 1000000 then return string.format('%.1fM', n / 1000000) end
  if n >= 1000 then return string.format('%.1fK', n / 1000) end
  return tostring(math.floor(n))
end

local function renderMonitor(mon)
  pcall(function()
    mon.setTextScale(0.5)
    if mon.isColor and mon.isColor() then mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white) end
    mon.clear()
    local w, h = mon.getSize()
    writeAt(mon, 2, 1, 'CCNEXUS // ' .. string.upper(monitorPage), colors.cyan)
    writeAt(mon, 2, 2, (worldMeta and worldMeta.name or config.worldName or 'Minecraft World'), colors.lightBlue)
    if monitorPage == 'overview' then
      writeAt(mon, 2, 4, config.label or ('Computer ' .. os.getComputerID()), colors.white)
      writeAt(mon, 2, 5, ws and 'NEXUS: ONLINE' or 'NEXUS: OFFLINE', ws and colors.lime or colors.red)
      if turtle then writeAt(mon, 2, 7, 'Fuel: ' .. tostring(turtle.getFuelLevel()), colors.yellow) end
      writeAt(mon, 2, 9, 'Peripherals: ' .. tostring(#peripheral.getNames()), colors.lightGray)
    elseif monitorPage == 'storage' then
      writeAt(mon, 2, 4, 'LOCAL INVENTORY NETWORK', colors.white)
      for i = 1, math.min(#cachedTelemetry.storage.items, math.max(0, h - 5)) do
        local it = cachedTelemetry.storage.items[i]
        writeAt(mon, 2, 4 + i, formatNumber(it.count) .. '  ' .. (it.displayName or it.name), colors.lightGray)
      end
    elseif monitorPage == 'energy' then
      local stored, cap = 0, 0
      for _, e in ipairs(cachedTelemetry.energy) do stored = stored + (e.energy or 0); cap = cap + (e.capacity or 0) end
      writeAt(mon, 2, 4, 'FORGE ENERGY', colors.white)
      writeAt(mon, 2, 6, formatNumber(stored) .. ' / ' .. formatNumber(cap) .. ' FE', colors.yellow)
      local pct = cap > 0 and math.floor(stored / cap * 100) or 0
      writeAt(mon, 2, 7, tostring(pct) .. '% stored', pct < 20 and colors.red or colors.lime)
    elseif monitorPage == 'ae2' then
      writeAt(mon, 2, 4, 'APPLIED ENERGISTICS 2', colors.white)
      writeAt(mon, 2, 5, 'ME bridges: ' .. tostring(#cachedTelemetry.ae2.bridges), colors.lightBlue)
      for i = 1, math.min(#cachedTelemetry.ae2.items, math.max(0, h - 6)) do
        local it = cachedTelemetry.ae2.items[i]
        writeAt(mon, 2, 5 + i, formatNumber(it.amount or it.count) .. '  ' .. (it.displayName or it.name), it.isCraftable and colors.lime or colors.lightGray)
      end
    elseif monitorPage == 'farm' then
      writeAt(mon, 2, 4, 'AUTOMATION JOB', colors.white)
      if job then
        writeAt(mon, 2, 6, string.upper(job.type or 'job'), colors.lightBlue)
        writeAt(mon, 2, 7, 'Status: ' .. tostring(job.status), colors.yellow)
        writeAt(mon, 2, 8, 'Progress: ' .. tostring(job.done or 0) .. '/' .. tostring(job.total or 0), colors.lime)
        writeAt(mon, 2, 9, job.detail or '', colors.lightGray)
      else writeAt(mon, 2, 6, 'No active job', colors.lightGray) end
    end
  end)
end

local function renderMonitors()
  for _, name in ipairs(peripheral.getNames()) do
    local methods = methodSet(name)
    if methods.setCursorPos and methods.write and getType(name):lower():find('monitor') then
      local mon = peripheral.wrap(name); if mon then renderMonitor(mon) end
    end
  end
end

local function sendTelemetry()
  renderMonitors()
  send({ type = 'telemetry', label = config.label, kind = config.kind, peripherals = describePeripherals(), telemetry = telemetry() })
end

local function playChunk(msg)
  local raw = b64decode(msg.data or '')
  local samples = {}
  for i = 1, #raw do local v = raw:byte(i); if v > 127 then v = v - 256 end; samples[i] = v end
  for _, s in ipairs(getSpeakers()) do while not s.p.playAudio(samples, msg.volume or 1) do os.pullEvent('speaker_audio_empty') end end
end

local function stopAudio()
  for _, s in ipairs(getSpeakers()) do pcall(function() s.p.stop() end) end
end

local function waitJob()
  while job and job.status == 'paused' do sleep(0.2) end
  return job and job.status ~= 'stopping'
end

local function safeForward(record)
  for _ = 1, 20 do
    if turtle.forward() then if record then table.insert(record, 'F') end; return true end
    if turtle.detect() then turtle.dig() else turtle.attack() end
    sleep(0.05)
  end
  return false
end

local function safeDown()
  for _ = 1, 20 do
    if turtle.down() then return true end
    if turtle.detectDown() then turtle.digDown() else turtle.attackDown() end
    sleep(0.05)
  end
  return false
end

local function turnLeft(record) turtle.turnLeft(); if record then table.insert(record, 'L') end end
local function turnRight(record) turtle.turnRight(); if record then table.insert(record, 'R') end end

local function rewindPath(record)
  for i = #record, 1, -1 do
    local action = record[i]
    if action == 'F' then
      if not turtle.back() then turtle.turnLeft(); turtle.turnLeft(); safeForward(); turtle.turnLeft(); turtle.turnLeft() end
    elseif action == 'L' then turtle.turnRight()
    elseif action == 'R' then turtle.turnLeft() end
  end
end

local function gridWalk(width, length, callback, record)
  for row = 1, width do
    for col = 1, length do
      if not waitJob() then return false end
      callback(row, col)
      job.done = math.min(job.total, (job.done or 0) + 1)
      if col < length and not safeForward(record) then return false end
    end
    if row < width then
      if row % 2 == 1 then turnRight(record) else turnLeft(record) end
      if not safeForward(record) then return false end
      if row % 2 == 1 then turnRight(record) else turnLeft(record) end
    end
  end
  return true
end

local matureAge = { ['minecraft:wheat'] = 7, ['minecraft:carrots'] = 7, ['minecraft:potatoes'] = 7, ['minecraft:beetroots'] = 3, ['minecraft:nether_wart'] = 3 }
local function farmCell(seedSlot)
  local ok, data = turtle.inspectDown()
  local harvested = false
  if ok and data then
    local need = matureAge[data.name]
    local age = data.state and tonumber(data.state.age)
    if need and age and age >= need then turtle.digDown(); harvested = true end
  end
  if harvested and seedSlot then
    turtle.select(seedSlot)
    turtle.placeDown()
  end
end

local function farmWorker(spec)
  local cycles = math.max(1, math.min(100, tonumber(spec.cycles) or 1))
  local interval = math.max(0, math.min(86400, tonumber(spec.interval) or 0))
  job.total = spec.width * spec.length * cycles
  for cycle = 1, cycles do
    if not waitJob() then return false end
    job.detail = 'Harvest cycle ' .. cycle .. '/' .. cycles
    local path = {}
    if not gridWalk(spec.width, spec.length, function() farmCell(spec.seedSlot) end, path) then return false end
    rewindPath(path)
    if cycle < cycles and interval > 0 then
      job.detail = 'Waiting ' .. interval .. 's for next cycle'
      local waited = 0
      while waited < interval do if not waitJob() then return false end; sleep(math.min(1, interval - waited)); waited = waited + 1 end
    end
  end
  return true
end

local logIds = { ['minecraft:oak_log'] = true, ['minecraft:spruce_log'] = true, ['minecraft:birch_log'] = true, ['minecraft:jungle_log'] = true, ['minecraft:acacia_log'] = true, ['minecraft:dark_oak_log'] = true, ['minecraft:mangrove_log'] = true, ['minecraft:cherry_log'] = true, ['minecraft:crimson_stem'] = true, ['minecraft:warped_stem'] = true }
local function harvestTree(seedSlot)
  turnRight()
  local ok, data = turtle.inspect()
  if ok and data and logIds[data.name] then
    turtle.dig()
    if safeForward() then
      local height = 0
      while height < 32 do
        local up, block = turtle.inspectUp()
        if not up or not block or not logIds[block.name] then break end
        turtle.digUp(); if turtle.up() then height = height + 1 else break end
      end
      for _ = 1, height do turtle.down() end
      turtle.back()
      if seedSlot then turtle.select(seedSlot); turtle.place() end
    end
  end
  turnLeft()
end

local function treeWorker(spec)
  local count = math.max(1, math.min(256, tonumber(spec.trees) or 8))
  local spacing = math.max(1, math.min(16, tonumber(spec.spacing) or 4))
  job.total = count
  local path = {}
  for i = 1, count do
    if not waitJob() then return false end
    job.detail = 'Tree ' .. i .. '/' .. count
    harvestTree(spec.seedSlot)
    job.done = i
    if i < count then for _ = 1, spacing do if not safeForward(path) then return false end end end
  end
  rewindPath(path)
  return true
end

local function quarryWorker(spec)
  job.total = math.max(1, spec.width * spec.length * spec.depth)
  job.done = 0
  for layer = 1, spec.depth do
    if not waitJob() then return false end
    job.detail = 'Mining layer ' .. layer .. '/' .. spec.depth
    local path = {}
    if not gridWalk(spec.width, spec.length, function() turtle.digDown() end, path) then return false end
    -- Return to the same X/Z origin before descending. This makes every layer
    -- start with the same orientation for both odd and even quarry widths.
    rewindPath(path)
    if layer < spec.depth then
      turtle.digDown()
      if not safeDown() then return false end
    end
  end
  return true
end

local function jobWorker()
  while running do
    local _, spec = os.pullEvent('ccnexus_job')
    job = spec; job.status = 'running'; job.done = 0; job.total = 1
    send({ type = 'event', message = 'Started ' .. tostring(job.type) })
    local ok = false
    if spec.type == 'quarry' then ok = quarryWorker(spec)
    elseif spec.type == 'farm' then ok = farmWorker(spec)
    elseif spec.type == 'tree_farm' then ok = treeWorker(spec) end
    if job then
      job.status = ok and 'complete' or 'stopped'
      sendTelemetry()
      send({ type = 'event', message = (ok and 'Completed ' or 'Stopped ') .. tostring(job.type) })
      sleep(1); job = nil
    end
  end
end

local function startJob(spec)
  if not turtle then send({ type = 'event', message = 'Automation requires a turtle' }); return end
  if job then send({ type = 'event', message = 'A turtle job is already active' }); return end
  os.queueEvent('ccnexus_job', spec)
end

local function findAeBridge(preferred)
  if preferred and preferred ~= '' and peripheral.isPresent(preferred) then return preferred end
  for _, name in ipairs(peripheral.getNames()) do
    local methods = methodSet(name); local lower = getType(name):lower()
    if lower == 'mebridge' or lower == 'me_bridge' or (methods.listItems and methods.craftItem) then return name end
  end
end

local function handleAeCraft(c)
  local bridge = findAeBridge(c.bridge)
  if not bridge then send({ type = 'event', message = 'No Advanced Peripherals ME Bridge found' }); return end
  local ok, result, err = call(bridge, 'craftItem', { name = c.item, count = math.max(1, tonumber(c.count) or 1) })
  if ok then send({ type = 'event', message = 'AE2 craft request sent for ' .. tostring(c.count or 1) .. ' x ' .. tostring(c.item), result = result, detail = err })
  else send({ type = 'event', message = 'AE2 craft request failed: ' .. tostring(result) }) end
  lastDeepScan = 0
end

local function handleCommand(c)
  if c.type == 'redstone' then redstone.setOutput(c.side or 'back', not not c.on)
  elseif c.type == 'redstone_analog' then redstone.setAnalogOutput(c.side or 'back', math.max(0, math.min(15, tonumber(c.strength) or 0)))
  elseif c.type == 'quarry_start' then startJob({ type = 'quarry', width = math.max(1, math.min(64, tonumber(c.width) or 8)), length = math.max(1, math.min(64, tonumber(c.length) or 8)), depth = math.max(1, math.min(128, tonumber(c.depth) or 8)) })
  elseif c.type == 'farm_start' then startJob({ type = 'farm', width = math.max(1, math.min(64, tonumber(c.width) or 8)), length = math.max(1, math.min(64, tonumber(c.length) or 8)), seedSlot = math.max(1, math.min(16, tonumber(c.seedSlot) or 1)), cycles = math.max(1, math.min(100, tonumber(c.cycles) or 1)), interval = math.max(0, math.min(86400, tonumber(c.interval) or 0)) })
  elseif c.type == 'tree_farm_start' then startJob({ type = 'tree_farm', trees = math.max(1, math.min(256, tonumber(c.trees) or 8)), spacing = math.max(1, math.min(16, tonumber(c.spacing) or 4)), seedSlot = math.max(1, math.min(16, tonumber(c.seedSlot) or 1)) })
  elseif (c.type == 'quarry_pause' or c.type == 'job_pause') and job then job.status = 'paused'
  elseif c.type == 'job_resume' and job and job.status == 'paused' then job.status = 'running'
  elseif (c.type == 'quarry_stop' or c.type == 'job_stop') and job then job.status = 'stopping'
  elseif c.type == 'monitor_set' then monitorPage = c.page or 'overview'; config.monitorPage = monitorPage; local f = fs.open(CONFIG, 'w'); f.write(textutils.serializeJSON(config)); f.close(); renderMonitors()
  elseif c.type == 'ae2_craft' then handleAeCraft(c)
  elseif c.type == 'scan_now' then lastDeepScan = 0; deepScan(); sendTelemetry()
  elseif c.type == 'reboot' then os.reboot() end
end

local function socketLoop()
  while running do
    local wsUrl = config.server:gsub('^http://', 'ws://'):gsub('^https://', 'wss://') .. '/ws/device?token=' .. textutils.urlEncode(config.token)
    local conn, err = http.websocket({ url = wsUrl, timeout = 15 })
    if not conn then print('CCNexus reconnect: ' .. tostring(err)); sleep(4)
    else
      ws = conn; print('CCNexus connected: ' .. config.label); sendTelemetry()
      while running and ws == conn do
        local raw, why = conn.receive(25)
        if raw then
          local msg = textutils.unserializeJSON(raw)
          if msg then
            if msg.type == 'hello' and msg.world then worldMeta = msg.world
            elseif msg.type == 'command' and msg.command then handleCommand(msg.command)
            elseif msg.type == 'audio_chunk' then playChunk(msg)
            elseif msg.type == 'audio_stop' then stopAudio()
            elseif msg.type == 'audio_end' and not msg.ok then print('Audio error: ' .. tostring(msg.error)) end
          end
        elseif why and why ~= 'Timed out' then break end
      end
      pcall(function() conn.close() end); ws = nil; renderMonitors()
      if running then sleep(2) end
    end
  end
end

local function heartbeatLoop()
  while running do sleep(3); if ws then sendTelemetry() else renderMonitors() end end
end

print('CCNexus Agent v0.2.0')
print('Workspace: ' .. tostring(config.worldName or config.worldId or 'unknown'))
if turtle then parallel.waitForAny(socketLoop, heartbeatLoop, jobWorker) else parallel.waitForAny(socketLoop, heartbeatLoop) end
