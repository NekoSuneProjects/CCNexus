local CONFIG = '/ccnexus/config.json'
local AGENT_VERSION = '0.3.0'
if not fs.exists(CONFIG) then error('CCNexus config missing. Run the installer again.', 0) end
local cf = fs.open(CONFIG, 'r')
local config = textutils.unserializeJSON(cf.readAll())
cf.close()

local running = true
local ws
local job = nil
local lastJob = nil
local worldMeta = { id = config.worldId, name = config.worldName or 'Minecraft World' }
local monitorPage = config.monitorPage or 'overview'
local cachedTelemetry = { storage = { items = {}, inventories = {} }, energy = {}, fluids = {}, ae2 = { bridges = {}, items = {} } }
local lastDeepScan = 0
local ui = {
  connection = 'STARTING', audio = 'IDLE', message = 'Starting CCNexus...',
  trackTitle = 'Nothing playing', trackType = '-', trackSource = '-', volume = 1
}

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

local function audioStatusColor(status)
  status = tostring(status or 'IDLE'):upper()
  if status == 'PLAYING' then return colors.lime end
  if status == 'BUFFERING' or status == 'PAUSED' then return colors.yellow end
  if status == 'ERROR' then return colors.red end
  return colors.lightGray
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
  local statusColor = online and colors.lime or (ui.connection == 'STARTING' or ui.connection == 'CONNECTING') and colors.yellow or colors.red
  uiField(t, 3, 'NEXUS', status, statusColor)
  uiField(t, 4, 'NODE', tostring(config.label or ('Computer ' .. os.getComputerID())) .. '  #' .. os.getComputerID(), colors.cyan)
  uiField(t, 5, 'WORLD', tostring(worldMeta.name or config.worldName or config.worldId or 'unknown'), colors.lightBlue)
  uiField(t, 6, 'TYPE', tostring(config.kind or (turtle and 'turtle' or 'computer')):upper(), colors.white)

  if h >= 11 then uiWriteLine(t, 8, '  STATUS ' .. string.rep('-', math.max(0, w - 9)), colors.gray, colors.black) end
  uiField(t, h >= 11 and 9 or 7, 'AUDIO', ui.audio, audioStatusColor(ui.audio))

  local jobText = 'IDLE'
  local jobColor = colors.lightGray
  if job then
    jobText = tostring(job.type or 'job'):upper() .. ' / ' .. tostring(job.status or 'running'):upper()
    if job.total and tonumber(job.total) and tonumber(job.total) > 0 then jobText = jobText .. '  ' .. tostring(job.done or 0) .. '/' .. tostring(job.total) end
    jobColor = job.status == 'paused' and colors.yellow or job.status == 'failed' and colors.red or colors.lime
  elseif lastJob then
    jobText = tostring(lastJob.type or 'job'):upper() .. ' / ' .. tostring(lastJob.status or 'done'):upper()
    jobColor = lastJob.status == 'failed' and colors.red or colors.lightGray
  end
  uiField(t, h >= 11 and 10 or 8, 'JOB', jobText, jobColor)

  if h >= 14 then
    local names = peripheral.getNames()
    local speakerCount = #getSpeakers()
    uiField(t, 11, 'DEVICES', tostring(#names) .. ' peripherals / ' .. tostring(speakerCount) .. ' speaker(s)', colors.white)
    if turtle then uiField(t, 12, 'FUEL', tostring(turtle.getFuelLevel()), colors.yellow) end
  end
  if h >= 16 then uiField(t, 13, 'TRACK', ui.trackTitle, ui.audio == 'PLAYING' and colors.cyan or colors.lightGray) end

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
    job = job and { type = job.type, status = job.status, done = job.done, total = job.total, detail = job.detail, error = job.error, width = job.width, length = job.length, depth = job.depth } or nil,
    lastJob = lastJob,
    audio = { status = ui.audio, title = ui.trackTitle, mediaType = ui.trackType, source = ui.trackSource, volume = ui.volume },
    storage = cachedTelemetry.storage, energy = cachedTelemetry.energy, fluids = cachedTelemetry.fluids, ae2 = cachedTelemetry.ae2,
    monitorPage = monitorPage
  }
end

local function send(obj)
  if ws then pcall(function() ws.send(textutils.serializeJSON(obj)) end) end
end

local function writeAt(mon, x, y, text, color, background)
  local w = select(1, mon.getSize())
  if y < 1 then return end
  if background and mon.isColor and mon.isColor() then mon.setBackgroundColor(background) end
  if color and mon.isColor and mon.isColor() then mon.setTextColor(color) end
  mon.setCursorPos(math.max(1, x), y)
  mon.write(tostring(text):sub(1, math.max(0, w - x + 1)))
end

local function fillLine(mon, y, text, color, background)
  local w = select(1, mon.getSize())
  if y < 1 then return end
  if background and mon.isColor and mon.isColor() then mon.setBackgroundColor(background) end
  if color and mon.isColor and mon.isColor() then mon.setTextColor(color) end
  mon.setCursorPos(1, y)
  mon.write((tostring(text or '') .. string.rep(' ', w)):sub(1, w))
end

local function formatNumber(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then return string.format('%.1fB', n / 1000000000) end
  if n >= 1000000 then return string.format('%.1fM', n / 1000000) end
  if n >= 1000 then return string.format('%.1fK', n / 1000) end
  return tostring(math.floor(n))
end

local function energyTotals()
  local stored, cap = 0, 0
  for _, e in ipairs(cachedTelemetry.energy or {}) do stored = stored + (tonumber(e.energy) or 0); cap = cap + (tonumber(e.capacity) or 0) end
  return stored, cap
end

local function monitorHeader(mon, title)
  local w = select(1, mon.getSize())
  local online = ws and 'ONLINE' or 'OFFLINE'
  local statusColor = ws and colors.lime or colors.red
  fillLine(mon, 1, ' CCNEXUS // ' .. string.upper(title), colors.white, colors.blue)
  fillLine(mon, 2, ' ' .. tostring(worldMeta.name or config.worldName or 'Minecraft World'), colors.lightBlue, colors.black)
  local sx = math.max(2, w - #online - 1)
  writeAt(mon, sx, 2, online, statusColor, colors.black)
end

local function monitorFooter(mon, h)
  if h < 3 then return end
  fillLine(mon, h, '[OVR] [MUS] [INV] [FE] [ME] [JOB]', colors.gray, colors.black)
end

local function monitorWrapped(mon, y, text, maxLines, color)
  local w, h = mon.getSize()
  local words = {}
  for word in tostring(text or ''):gmatch('%S+') do table.insert(words, word) end
  local line, lineNo = '', 0
  for _, word in ipairs(words) do
    local candidate = line == '' and word or (line .. ' ' .. word)
    if #candidate > math.max(1, w - 4) then
      lineNo = lineNo + 1
      if lineNo > maxLines or y + lineNo - 1 >= h then break end
      writeAt(mon, 3, y + lineNo - 1, line, color)
      line = word
    else line = candidate end
  end
  if line ~= '' and lineNo < maxLines and y + lineNo < h then
    lineNo = lineNo + 1
    writeAt(mon, 3, y + lineNo - 1, line, color)
  end
  return lineNo
end

local function renderMonitor(mon)
  pcall(function()
    mon.setTextScale(0.5)
    if mon.isColor and mon.isColor() then mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white) end
    mon.clear()
    local w, h = mon.getSize()
    monitorHeader(mon, monitorPage)

    if monitorPage == 'overview' then
      local peripherals = peripheral.getNames()
      local speakers = #getSpeakers()
      local stored, cap = energyTotals()
      local ae = cachedTelemetry.ae2 or { bridges = {}, items = {}, energy = {} }
      local storage = cachedTelemetry.storage or { items = {}, inventories = {} }

      fillLine(mon, 4, ' NODE & NETWORK', colors.cyan, colors.black)
      writeAt(mon, 3, 5, tostring(config.label or ('Computer ' .. os.getComputerID())) .. '  |  Computer #' .. tostring(os.getComputerID()), colors.white)
      writeAt(mon, 3, 6, 'Agent v' .. AGENT_VERSION .. '  |  ' .. tostring(config.kind or (turtle and 'turtle' or 'computer')):upper(), colors.lightGray)
      writeAt(mon, 3, 7, tostring(#peripherals) .. ' peripherals  |  ' .. tostring(speakers) .. ' speaker(s)', colors.lightBlue)

      fillLine(mon, 9, ' STORAGE & POWER', colors.cyan, colors.black)
      writeAt(mon, 3, 10, 'Inventory: ' .. tostring(#(storage.items or {})) .. ' item types / ' .. tostring(#(storage.inventories or {})) .. ' inventories', colors.white)
      writeAt(mon, 3, 11, 'Forge Energy: ' .. formatNumber(stored) .. ' / ' .. formatNumber(cap) .. ' FE', cap > 0 and colors.yellow or colors.gray)
      writeAt(mon, 3, 12, 'AE2: ' .. tostring(#(ae.bridges or {})) .. ' bridge(s) / ' .. tostring(#(ae.items or {})) .. ' indexed items', colors.lightBlue)

      fillLine(mon, 14, ' AUDIO NEXUS', colors.cyan, colors.black)
      writeAt(mon, 3, 15, ui.audio .. '  |  ' .. tostring(ui.trackTitle or 'Nothing playing'), audioStatusColor(ui.audio))
      if h >= 18 then writeAt(mon, 3, 16, tostring(ui.trackType or '-'):upper() .. '  |  ' .. tostring(ui.trackSource or '-') .. '  |  volume ' .. tostring(ui.volume or 1) .. 'x', colors.lightGray) end

      if turtle and h >= 20 then
        fillLine(mon, 18, ' TURTLE', colors.cyan, colors.black)
        local active = job or lastJob
        writeAt(mon, 3, 19, 'Fuel: ' .. tostring(turtle.getFuelLevel()) .. '  |  Job: ' .. (active and (tostring(active.type):upper() .. ' / ' .. tostring(active.status):upper()) or 'IDLE'), colors.yellow)
        if active and active.detail and h >= 21 then writeAt(mon, 3, 20, tostring(active.detail), active.status == 'failed' and colors.red or colors.lightGray) end
      end

    elseif monitorPage == 'music' then
      fillLine(mon, 4, ' AUDIO NEXUS // NOW PLAYING', colors.cyan, colors.black)
      writeAt(mon, 3, 6, 'STATUS', colors.gray)
      writeAt(mon, 15, 6, ui.audio, audioStatusColor(ui.audio))
      writeAt(mon, 3, 8, 'NOW PLAYING', colors.gray)
      monitorWrapped(mon, 10, ui.trackTitle or 'Nothing playing', math.max(1, math.min(4, h - 15)), colors.white)
      if h >= 16 then
        writeAt(mon, 3, h - 5, 'TYPE: ' .. tostring(ui.trackType or '-'):upper(), colors.lightBlue)
        writeAt(mon, math.max(22, math.floor(w / 2)), h - 5, 'SOURCE: ' .. tostring(ui.trackSource or '-'), colors.lightGray)
        writeAt(mon, 3, h - 4, 'VOLUME: ' .. tostring(ui.volume or 1) .. 'x', colors.yellow)
        writeAt(mon, 3, h - 3, '48 kHz mono PCM -> CC:Tweaked speaker', colors.gray)
      end

    elseif monitorPage == 'storage' then
      local storage = cachedTelemetry.storage or { items = {}, inventories = {} }
      fillLine(mon, 4, ' INVENTORY NETWORK', colors.cyan, colors.black)
      writeAt(mon, 3, 5, tostring(#(storage.items or {})) .. ' indexed item types  |  ' .. tostring(#(storage.inventories or {})) .. ' inventories', colors.lightBlue)
      local maxRows = math.max(0, h - 8)
      for i = 1, math.min(#(storage.items or {}), maxRows) do
        local it = storage.items[i]
        writeAt(mon, 3, 6 + i, string.format('%-9s  %s', formatNumber(it.count), tostring(it.displayName or it.name)), colors.lightGray)
      end

    elseif monitorPage == 'energy' then
      local stored, cap = energyTotals()
      local pct = cap > 0 and math.max(0, math.min(100, math.floor(stored / cap * 100))) or 0
      fillLine(mon, 4, ' FORGE ENERGY', colors.cyan, colors.black)
      writeAt(mon, 3, 6, formatNumber(stored) .. ' / ' .. formatNumber(cap) .. ' FE', colors.yellow)
      writeAt(mon, 3, 7, tostring(pct) .. '% stored', pct < 20 and colors.red or colors.lime)
      local barWidth = math.max(10, math.min(w - 6, 50))
      local filled = math.floor(barWidth * pct / 100)
      writeAt(mon, 3, 9, '[' .. string.rep('#', filled) .. string.rep('-', barWidth - filled) .. ']', pct < 20 and colors.red or colors.lime)
      writeAt(mon, 3, 11, tostring(#(cachedTelemetry.energy or {})) .. ' energy peripheral(s) reporting', colors.lightGray)

    elseif monitorPage == 'ae2' then
      local ae = cachedTelemetry.ae2 or { bridges = {}, items = {}, energy = {} }
      fillLine(mon, 4, ' APPLIED ENERGISTICS 2', colors.cyan, colors.black)
      writeAt(mon, 3, 5, tostring(#(ae.bridges or {})) .. ' ME bridge(s)  |  ' .. tostring(#(ae.items or {})) .. ' indexed items', colors.lightBlue)
      if ae.energy then writeAt(mon, 3, 6, 'ME energy: ' .. formatNumber(ae.energy.stored or 0) .. ' / ' .. formatNumber(ae.energy.capacity or 0), colors.yellow) end
      local maxRows = math.max(0, h - 9)
      for i = 1, math.min(#(ae.items or {}), maxRows) do
        local it = ae.items[i]
        writeAt(mon, 3, 7 + i, formatNumber(it.amount or it.count) .. '  ' .. tostring(it.displayName or it.name), it.isCraftable and colors.lime or colors.lightGray)
      end

    elseif monitorPage == 'farm' then
      fillLine(mon, 4, ' TURTLE / AUTOMATION JOB', colors.cyan, colors.black)
      if not turtle then
        writeAt(mon, 3, 6, 'This node is not a turtle.', colors.lightGray)
      else
        writeAt(mon, 3, 6, 'Fuel: ' .. tostring(turtle.getFuelLevel()), colors.yellow)
        local active = job or lastJob
        if active then
          local statusColor = active.status == 'failed' and colors.red or active.status == 'paused' and colors.yellow or colors.lime
          writeAt(mon, 3, 8, tostring(active.type or 'job'):upper() .. ' / ' .. tostring(active.status or 'unknown'):upper(), statusColor)
          writeAt(mon, 3, 9, 'Progress: ' .. tostring(active.done or 0) .. ' / ' .. tostring(active.total or 0), colors.white)
          if active.detail then monitorWrapped(mon, 11, active.detail, math.max(1, h - 14), active.status == 'failed' and colors.red or colors.lightGray) end
        else
          writeAt(mon, 3, 8, 'No active or recent automation job.', colors.lightGray)
        end
      end
    else
      monitorPage = 'overview'
      writeAt(mon, 3, 5, 'Unknown page; reset to overview.', colors.red)
    end

    monitorFooter(mon, h)
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
  renderMonitors()
end

local function applyAudioState(msg)
  local status = tostring(msg.status or 'idle'):upper()
  if status == 'LOADING' then status = 'BUFFERING' end
  if status ~= 'PLAYING' and status ~= 'PAUSED' and status ~= 'BUFFERING' and status ~= 'ERROR' then status = 'IDLE' end

  if status == 'IDLE' then
    ui.trackTitle = 'Nothing playing'
    ui.trackType = '-'
    ui.trackSource = '-'
  else
    if msg.title ~= nil then ui.trackTitle = tostring(msg.title) end
    if msg.mediaType ~= nil then ui.trackType = tostring(msg.mediaType) end
    if msg.source ~= nil then ui.trackSource = tostring(msg.source) end
  end
  if msg.volume ~= nil then ui.volume = tonumber(msg.volume) or ui.volume or 1 end

  local message
  if status == 'PLAYING' then message = 'Now playing: ' .. tostring(ui.trackTitle)
  elseif status == 'PAUSED' then message = 'Audio paused: ' .. tostring(ui.trackTitle)
  elseif status == 'BUFFERING' then message = 'Loading: ' .. tostring(ui.trackTitle)
  elseif status == 'ERROR' then message = 'Audio error: ' .. tostring(msg.error or 'unknown error')
  else message = 'Audio idle' end

  setUi(nil, status, message)
  renderMonitors()
end

local function setJobFailure(reason)
  reason = tostring(reason or 'Unknown turtle job failure')
  if job then job.error = reason; job.detail = reason end
  setUi(nil, nil, reason)
  return false
end

local function ensureFuel(minimum)
  if not turtle then return false, 'This node is not a turtle' end
  minimum = math.max(1, tonumber(minimum) or 1)
  local level = turtle.getFuelLevel()
  if level == 'unlimited' then return true end
  if tonumber(level) and tonumber(level) >= minimum then return true end

  local selected = turtle.getSelectedSlot()
  local foundFuel = false
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      local combustible = turtle.refuel(0)
      if combustible then
        foundFuel = true
        while turtle.getItemCount(slot) > 0 do
          local current = turtle.getFuelLevel()
          if current == 'unlimited' or (tonumber(current) and tonumber(current) >= minimum) then break end
          local ok = turtle.refuel(1)
          if not ok then break end
        end
      end
    end
    local current = turtle.getFuelLevel()
    if current == 'unlimited' or (tonumber(current) and tonumber(current) >= minimum) then break end
  end
  turtle.select(selected)

  level = turtle.getFuelLevel()
  if level == 'unlimited' or (tonumber(level) and tonumber(level) >= minimum) then
    setUi(nil, nil, 'Auto-refuelled turtle to ' .. tostring(level) .. ' fuel')
    return true
  end
  if foundFuel then return false, 'Fuel items were found but the turtle could not refuel enough to move' end
  return false, 'Out of fuel. Put coal/charcoal or another valid fuel item in the turtle inventory.'
end

local function waitJob()
  while job and job.status == 'paused' do sleep(0.2) end
  if not job then return false end
  if job.status == 'stopping' then job.detail = 'Stopped by user request'; return false end
  return true
end

local function safeForward(record)
  local fuelOk, fuelErr = ensureFuel(1)
  if not fuelOk then return setJobFailure(fuelErr) end
  local lastErr = 'movement blocked'
  for _ = 1, 20 do
    local moved, moveErr = turtle.forward()
    if moved then if record then table.insert(record, 'F') end; return true end
    if moveErr then lastErr = moveErr end
    local hasBlock = turtle.detect()
    if hasBlock then
      local dug, digErr = turtle.dig()
      if not dug and digErr then lastErr = digErr end
    else
      local attacked, attackErr = turtle.attack()
      if not attacked and attackErr then lastErr = attackErr end
    end
    local ok, err = ensureFuel(1)
    if not ok then return setJobFailure(err) end
    sleep(0.05)
  end
  return setJobFailure('Cannot move forward: ' .. tostring(lastErr))
end

local function safeDown()
  local fuelOk, fuelErr = ensureFuel(1)
  if not fuelOk then return setJobFailure(fuelErr) end
  local lastErr = 'movement blocked'
  for _ = 1, 20 do
    local moved, moveErr = turtle.down()
    if moved then return true end
    if moveErr then lastErr = moveErr end
    if turtle.detectDown() then
      local dug, digErr = turtle.digDown()
      if not dug and digErr then lastErr = digErr end
    else
      local attacked, attackErr = turtle.attackDown()
      if not attacked and attackErr then lastErr = attackErr end
    end
    local ok, err = ensureFuel(1)
    if not ok then return setJobFailure(err) end
    sleep(0.05)
  end
  return setJobFailure('Cannot move down: ' .. tostring(lastErr))
end

local function turnLeft(record) turtle.turnLeft(); if record then table.insert(record, 'L') end end
local function turnRight(record) turtle.turnRight(); if record then table.insert(record, 'R') end end

local function rewindPath(record)
  for i = #record, 1, -1 do
    if not waitJob() then return false end
    local action = record[i]
    if action == 'F' then
      local fuelOk, fuelErr = ensureFuel(1)
      if not fuelOk then return setJobFailure(fuelErr) end
      local moved, moveErr = turtle.back()
      if not moved then
        turtle.turnLeft(); turtle.turnLeft()
        if not safeForward() then return false end
        turtle.turnLeft(); turtle.turnLeft()
        if moveErr and job and not job.error then job.detail = 'Recovered return path after: ' .. tostring(moveErr) end
      end
    elseif action == 'L' then turtle.turnRight()
    elseif action == 'R' then turtle.turnLeft() end
  end
  return true
end

local function gridWalk(width, length, callback, record)
  for row = 1, width do
    for col = 1, length do
      if not waitJob() then return false end
      local cellOk = callback(row, col)
      if cellOk == false then return false end
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
  if harvested and seedSlot then turtle.select(seedSlot); turtle.placeDown() end
  return true
end

local function farmWorker(spec)
  local cycles = math.max(1, math.min(100, tonumber(spec.cycles) or 1))
  local interval = math.max(0, math.min(86400, tonumber(spec.interval) or 0))
  job.total = spec.width * spec.length * cycles
  for cycle = 1, cycles do
    if not waitJob() then return false end
    job.detail = 'Harvest cycle ' .. cycle .. '/' .. cycles
    local path = {}
    if not gridWalk(spec.width, spec.length, function() return farmCell(spec.seedSlot) end, path) then return false end
    if not rewindPath(path) then return false end
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
    local dug, digErr = turtle.dig()
    if not dug then turnLeft(); return setJobFailure('Cannot cut tree: ' .. tostring(digErr or 'dig failed')) end
    if safeForward() then
      local height = 0
      while height < 32 do
        local up, block = turtle.inspectUp()
        if not up or not block or not logIds[block.name] then break end
        local cut, cutErr = turtle.digUp()
        if not cut then turnLeft(); return setJobFailure('Cannot cut tree above: ' .. tostring(cutErr or 'dig failed')) end
        local fuelOk, fuelErr = ensureFuel(1); if not fuelOk then turnLeft(); return setJobFailure(fuelErr) end
        local moved, moveErr = turtle.up(); if moved then height = height + 1 else turnLeft(); return setJobFailure('Cannot move up tree: ' .. tostring(moveErr or 'blocked')) end
      end
      for _ = 1, height do local moved, err = turtle.down(); if not moved then turnLeft(); return setJobFailure('Cannot return down tree: ' .. tostring(err or 'blocked')) end end
      turtle.back()
      if seedSlot then turtle.select(seedSlot); turtle.place() end
    end
  end
  turnLeft()
  return true
end

local function treeWorker(spec)
  local count = math.max(1, math.min(256, tonumber(spec.trees) or 8))
  local spacing = math.max(1, math.min(16, tonumber(spec.spacing) or 4))
  job.total = count
  local path = {}
  for i = 1, count do
    if not waitJob() then return false end
    job.detail = 'Tree ' .. i .. '/' .. count
    if not harvestTree(spec.seedSlot) then return false end
    job.done = i
    if i < count then for _ = 1, spacing do if not safeForward(path) then return false end end end
  end
  if not rewindPath(path) then return false end
  return true
end

local function quarryCell()
  if turtle.detectDown() then
    local dug, digErr = turtle.digDown()
    if not dug then return setJobFailure('Cannot mine block below: ' .. tostring(digErr or 'dig failed; check mining tool or block')) end
  end
  return true
end

local function quarryWorker(spec)
  job.total = math.max(1, spec.width * spec.length * spec.depth)
  job.done = 0
  local estimatedMoves = math.max(1, spec.depth * (2 * math.max(0, spec.width * spec.length - 1)) + math.max(0, spec.depth - 1))
  job.detail = 'Preparing quarry; estimated movement fuel ' .. tostring(estimatedMoves)
  local fuelOk, fuelErr = ensureFuel(math.min(estimatedMoves, 128))
  if not fuelOk then return setJobFailure(fuelErr) end

  for layer = 1, spec.depth do
    if not waitJob() then return false end
    job.detail = 'Mining layer ' .. layer .. '/' .. spec.depth
    local path = {}
    if not gridWalk(spec.width, spec.length, quarryCell, path) then return false end
    if not rewindPath(path) then return false end
    if layer < spec.depth then
      if turtle.detectDown() then
        local dug, digErr = turtle.digDown()
        if not dug then return setJobFailure('Cannot open next quarry layer: ' .. tostring(digErr or 'dig failed')) end
      end
      if not safeDown() then return false end
    end
  end
  job.detail = 'Quarry complete'
  return true
end

local function jobWorker()
  while running do
    local _, spec = os.pullEvent('ccnexus_job')
    job = spec; job.status = 'running'; job.done = 0; job.total = 1; job.error = nil
    setUi(nil, nil, 'Started ' .. tostring(job.type))
    send({ type = 'event', message = 'Started ' .. tostring(job.type) })

    local workerOk, result = pcall(function()
      if spec.type == 'quarry' then return quarryWorker(spec)
      elseif spec.type == 'farm' then return farmWorker(spec)
      elseif spec.type == 'tree_farm' then return treeWorker(spec)
      else return setJobFailure('Unknown job type: ' .. tostring(spec.type)) end
    end)
    if not workerOk then setJobFailure('Job crashed: ' .. tostring(result)); result = false end

    if job then
      local finalStatus
      if job.status == 'stopping' then finalStatus = 'stopped'; job.detail = job.detail or 'Stopped by user request'
      elseif result and not job.error then finalStatus = 'complete'
      else finalStatus = 'failed' end
      job.status = finalStatus
      lastJob = { type = job.type, status = finalStatus, done = job.done, total = job.total, detail = job.detail, error = job.error, at = os.epoch('utc') }
      setUi(nil, nil, (finalStatus == 'complete' and 'Completed ' or finalStatus == 'failed' and 'Failed ' or 'Stopped ') .. tostring(job.type) .. (job.error and (': ' .. job.error) or ''))
      sendTelemetry()
      send({ type = 'event', message = (finalStatus == 'complete' and 'Completed ' or finalStatus == 'failed' and 'Failed ' or 'Stopped ') .. tostring(job.type) .. (job.error and (': ' .. job.error) or ''), job = lastJob })
      sleep(3); job = nil; pcall(renderTerminal); renderMonitors()
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
  elseif (c.type == 'quarry_pause' or c.type == 'job_pause') and job then job.status = 'paused'; job.detail = 'Paused by user'; renderMonitors()
  elseif c.type == 'job_resume' and job and job.status == 'paused' then job.status = 'running'; job.detail = 'Resumed by user'; renderMonitors()
  elseif (c.type == 'quarry_stop' or c.type == 'job_stop') and job then job.status = 'stopping'; job.detail = 'Stopping by user request...'; renderMonitors()
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
      renderMonitors()
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
            if msg.type == 'hello' and msg.world then
              worldMeta = msg.world
              setUi('ONLINE', nil, 'Workspace synced: ' .. tostring(msg.world.name or msg.world.id))
              renderMonitors()
            elseif msg.type == 'command' and msg.command then handleCommand(msg.command)
            elseif msg.type == 'audio_state' then
              applyAudioState(msg)
            elseif msg.type == 'audio_meta' then
              ui.trackTitle = tostring(msg.title or 'Untitled media')
              ui.trackType = tostring(msg.mediaType or 'media')
              ui.trackSource = tostring(msg.source or 'CCNexus')
              ui.volume = tonumber(msg.volume) or 1
              setUi(nil, 'BUFFERING', 'Loading: ' .. ui.trackTitle)
              renderMonitors()
            elseif msg.type == 'audio_chunk' then playChunk(msg)
            elseif msg.type == 'audio_stop' then stopAudio()
            elseif msg.type == 'audio_end' then
              if not msg.ok then setUi(nil, 'IDLE', 'Audio error: ' .. tostring(msg.error)) else setUi(nil, 'IDLE', 'Audio complete') end
              renderMonitors()
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
  local pages = { 'overview', 'music', 'storage', 'energy', 'ae2', 'farm' }
  while running do
    local _, side, x = os.pullEvent('monitor_touch')
    local mon = peripheral.wrap(side)
    if mon and mon.getSize then
      local w = select(1, mon.getSize())
      local index = math.max(1, math.min(#pages, math.floor(((tonumber(x) or 1) - 1) * #pages / math.max(1, w)) + 1))
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
