local CONFIG = '/ccnexus/config.json'
local AGENT_VERSION = '0.3.0'
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
local ui = { connection = 'STARTING', audio = 'IDLE', message = 'Starting CCNexus...' }

-- Decode base64 directly into bytes. The old implementation expanded every
-- character into a temporary bit-string which could trip CraftOS's
-- "Too long without yielding" watchdog on normal audio packets.
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64lookup = {}
for i = 1, #b64chars do b64lookup[b64chars:sub(i, i)] = i - 1 end

local function cooperativeYield()
  os.queueEvent('ccnexus_audio_yield')
  os.pullEvent('ccnexus_audio_yield')
end

local function b64decode(data)
  data = tostring(data or '')
  local out, n = {}, 0
  local i, groups = 1, 0
  while i <= #data do
    local c1, c2 = data:sub(i, i), data:sub(i + 1, i + 1)
    local c3, c4 = data:sub(i + 2, i + 2), data:sub(i + 3, i + 3)
    i = i + 4
    local a, b = b64lookup[c1], b64lookup[c2]
    if a and b then
      n = n + 1; out[n] = string.char(a * 4 + math.floor(b / 16))
      if c3 ~= '=' and c3 ~= '' then
        local c = b64lookup[c3]
        if c then
          n = n + 1; out[n] = string.char((b % 16) * 16 + math.floor(c / 4))
          if c4 ~= '=' and c4 ~= '' then
            local d = b64lookup[c4]
            if d then n = n + 1; out[n] = string.char((c % 4) * 64 + d) end
          end
        end
      end
    end
    groups = groups + 1
    if groups % 2048 == 0 then cooperativeYield() end
  end
  return table.concat(out)
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

local function uiWriteLine(t, y, text, fg, bg)
  local w = select(1, t.getSize())
  if y < 1 then return end
  if bg and t.isColor and t.isColor() then t.setBackgroundColor(bg) end
  if fg and t.isColor and t.isColor() then t.setTextColor(fg) end
  t.setCursorPos(1, y)
  t.write((tostring(text or '') .. string.rep(' ', w)):sub(1, w))
end

local function uiField(t, y, label, value, color)
  local w, h = t.getSize()
  if y < 1 or y >= h then return end
  local prefix = ('  %-10s'):format(label)
  if t.isColor and t.isColor() then t.setBackgroundColor(colors.black); t.setTextColor(colors.gray) end
  t.setCursorPos(1, y); t.write(prefix:sub(1, w))
  if #prefix < w then
    if t.isColor and t.isColor() then t.setTextColor(color or colors.white) end
    t.write(tostring(value or '-'):sub(1, w - #prefix))
  end
end

local function renderTerminal()
  local t = term.current()
  if not t then return end
  local w, h = t.getSize()
  if t.isColor and t.isColor() then t.setBackgroundColor(colors.black); t.setTextColor(colors.white) end
  t.clear()

  local title = ' CCNEXUS NODE'
  local version = 'v' .. AGENT_VERSION .. ' '
  local spaces = math.max(1, w - #title - #version)
  uiWriteLine(t, 1, title .. string.rep(' ', spaces) .. version, colors.white, colors.blue)

  local online = ui.connection == 'ONLINE'
  local status = online and 'ONLINE' or ui.connection
  local statusColor = online and colors.lime or (ui.connection == 'STARTING' and colors.yellow or colors.red)
  uiField(t, 3, 'NEXUS', status, statusColor)
  uiField(t, 4, 'NODE', tostring(config.label or ('Computer ' .. os.getComputerID())) .. '  #' .. os.getComputerID(), colors.cyan)
  uiField(t, 5, 'WORLD', tostring(worldMeta.name or config.worldName or config.worldId or 'unknown'), colors.lightBlue)
  uiField(t, 6, 'TYPE', tostring(config.kind or (turtle and 'turtle' or 'computer')):upper(), colors.white)

  if h >= 11 then uiWriteLine(t, 8, '  STATUS ' .. string.rep('-', math.max(0, w - 9)), colors.gray, colors.black) end
  local audioColor = ui.audio == 'PLAYING' and colors.lime or colors.lightGray
  uiField(t, h >= 11 and 9 or 7, 'AUDIO', ui.audio, audioColor)

  local jobText = 'IDLE'
  local jobColor = colors.lightGray
  if job then
    jobText = tostring(job.type or 'job'):upper() .. ' / ' .. tostring(job.status or 'running'):upper()
    if job.total and tonumber(job.total) and tonumber(job.total) > 0 then jobText = jobText .. '  ' .. tostring(job.done or 0) .. '/' .. tostring(job.total) end
    jobColor = job.status == 'paused' and colors.yellow or colors.lime
  end
  uiField(t, h >= 11 and 10 or 8, 'JOB', jobText, jobColor)

  if h >= 14 then
    local names = peripheral.getNames()
    local speakerCount = #getSpeakers()
    uiField(t, 11, 'DEVICES', tostring(#names) .. ' peripherals / ' .. tostring(speakerCount) .. ' speaker(s)', colors.white)
    if turtle then uiField(t, 12, 'FUEL', tostring(turtle.getFuelLevel()), colors.yellow) end
  end

  if h >= 6 then
    local msgY = math.max(3, h - 2)
    uiWriteLine(t, msgY, '  ' .. tostring(ui.message or ''):sub(1, math.max(0, w - 2)), colors.lightGray, colors.black)
    uiWriteLine(t, h, ' Managed remotely by CCNexus', colors.gray, colors.black)
  end
  t.setCursorPos(1, h)
end

local function setUi(connection, audio, message, redraw)
  if connection then ui.connection = connection end
  if audio then ui.audio = audio end
  if message then ui.message = message end
  if redraw ~= false then pcall(renderTerminal) end
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
    if h >= 3 then writeAt(mon, 1, h, '[OVR] [INV] [FE] [ME] [JOB]', colors.gray) end
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
  send({ type = 'telemetry', agentVersion = AGENT_VERSION, label = config.label, kind = config.kind, peripherals = describePeripherals(), telemetry = telemetry() })
end

local function playChunk(msg)
  if ui.audio ~= 'PLAYING' then setUi(nil, 'PLAYING', 'Audio stream active') end
  local raw = b64decode(msg.data or '')
  local samples = {}
  for i = 1, #raw do
    local v = raw:byte(i)
    if v > 127 then v = v - 256 end
    samples[i] = v
    if i % 8192 == 0 then cooperativeYield() end
  end
  for _, s in ipairs(getSpeakers()) do
    while not s.p.playAudio(samples, msg.volume or 1) do os.pullEvent('speaker_audio_empty') end
  end
end

local function stopAudio()
  for _, s in ipairs(getSpeakers()) do pcall(function() s.p.stop() end) end
  setUi(nil, 'IDLE', 'Audio stopped')
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
    setUi(nil, nil, 'Started ' .. tostring(job.type))
    send({ type = 'event', message = 'Started ' .. tostring(job.type) })
    local ok = false
    if spec.type == 'quarry' then ok = quarryWorker(spec)
    elseif spec.type == 'farm' then ok = farmWorker(spec)
    elseif spec.type == 'tree_farm' then ok = treeWorker(spec) end
    if job then
      job.status = ok and 'complete' or 'stopped'
      setUi(nil, nil, (ok and 'Completed ' or 'Stopped ') .. tostring(job.type))
      sendTelemetry()
      send({ type = 'event', message = (ok and 'Completed ' or 'Stopped ') .. tostring(job.type) })
      sleep(1); job = nil; pcall(renderTerminal)
    end
  end
end

local function startJob(spec)
  if not turtle then send({ type = 'event', message = 'Automation requires a turtle' }); setUi(nil, nil, 'Automation requires a turtle'); return end
  if job then send({ type = 'event', message = 'A turtle job is already active' }); setUi(nil, nil, 'A turtle job is already active'); return end
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
  if not bridge then send({ type = 'event', message = 'No Advanced Peripherals ME Bridge found' }); setUi(nil, nil, 'No ME Bridge found'); return end
  local ok, result, err = call(bridge, 'craftItem', { name = c.item, count = math.max(1, tonumber(c.count) or 1) })
  if ok then send({ type = 'event', message = 'AE2 craft request sent for ' .. tostring(c.count or 1) .. ' x ' .. tostring(c.item), result = result, detail = err }); setUi(nil, nil, 'AE2 craft request sent')
  else send({ type = 'event', message = 'AE2 craft request failed: ' .. tostring(result) }); setUi(nil, nil, 'AE2 craft request failed') end
  lastDeepScan = 0
end

local function handleCommand(c)
  setUi(nil, nil, 'Command: ' .. tostring(c.type or 'unknown'))
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
  elseif c.type == 'reboot' then setUi('RESTARTING', nil, c.update and 'Updating agent and restarting...' or 'Restarting node...'); sleep(0.15); os.reboot() end
end

local function socketLoop()
  while running do
    local wsUrl = config.server:gsub('^http://', 'ws://'):gsub('^https://', 'wss://') .. '/ws/device?token=' .. textutils.urlEncode(config.token)
    setUi('CONNECTING', nil, 'Connecting to Nexus...')
    local conn, err = http.websocket({ url = wsUrl, timeout = 15 })
    if not conn then
      setUi('OFFLINE', nil, 'Reconnect in 4s: ' .. tostring(err))
      sleep(4)
    else
      ws = conn
      setUi('ONLINE', nil, 'Connected to CCNexus')
      sendTelemetry()
      while running and ws == conn do
        local raw, why = conn.receive(25)
        if raw then
          local msg = textutils.unserializeJSON(raw)
          if msg then
            if msg.type == 'hello' and msg.world then worldMeta = msg.world; setUi('ONLINE', nil, 'Workspace synced: ' .. tostring(msg.world.name or msg.world.id))
            elseif msg.type == 'command' and msg.command then handleCommand(msg.command)
            elseif msg.type == 'audio_chunk' then playChunk(msg)
            elseif msg.type == 'audio_stop' then stopAudio()
            elseif msg.type == 'audio_end' then
              if not msg.ok then setUi(nil, 'IDLE', 'Audio error: ' .. tostring(msg.error)) else setUi(nil, 'IDLE', 'Audio complete') end
            end
          end
        elseif why and why ~= 'Timed out' then
          setUi('OFFLINE', nil, 'Socket closed: ' .. tostring(why))
          break
        end
      end
      pcall(function() conn.close() end); ws = nil; renderMonitors()
      if running then setUi('OFFLINE', nil, 'Disconnected; reconnecting...'); sleep(2) end
    end
  end
end

local function heartbeatLoop()
  while running do
    sleep(3)
    pcall(renderTerminal)
    if ws then sendTelemetry() else renderMonitors() end
  end
end

local function monitorTouchLoop()
  local pages = { 'overview', 'storage', 'energy', 'ae2', 'farm' }
  while running do
    local _, side, x = os.pullEvent('monitor_touch')
    local mon = peripheral.wrap(side)
    if mon and mon.getSize then
      local w = select(1, mon.getSize())
      local index = math.max(1, math.min(5, math.floor(((tonumber(x) or 1) - 1) * 5 / math.max(1, w)) + 1))
      monitorPage = pages[index]
      config.monitorPage = monitorPage
      local f = fs.open(CONFIG, 'w'); f.write(textutils.serializeJSON(config)); f.close()
      renderMonitors()
      setUi(nil, nil, 'Monitor page: ' .. monitorPage)
      send({ type = 'event', message = 'Monitor page changed to ' .. monitorPage })
    end
  end
end

pcall(renderTerminal)
if turtle then parallel.waitForAny(socketLoop, heartbeatLoop, jobWorker, monitorTouchLoop) else parallel.waitForAny(socketLoop, heartbeatLoop, monitorTouchLoop) end
