local CONFIG = '/ccnexus/config.json'
if not fs.exists(CONFIG) then error('CCNexus config missing. Run the installer again.',0) end
local cf = fs.open(CONFIG,'r'); local config = textutils.unserializeJSON(cf.readAll()); cf.close()
local running = true
local ws
local quarry = nil

local b64chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64decode(data)
  data = string.gsub(data, '[^'..b64chars..'=]', '')
  return (data:gsub('.', function(x)
    if x == '=' then return '' end
    local r,f='',(b64chars:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c=0
    for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

local function getSpeakers()
  local out={}
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=='speaker' then table.insert(out,{name=name,p=peripheral.wrap(name)}) end
  end
  return out
end
local function peripherals()
  local out={}
  for _,name in ipairs(peripheral.getNames()) do
    table.insert(out,{name=name,type=peripheral.getType(name)})
  end
  return out
end
local function position()
  local x,y,z=gps.locate(0.5,false)
  if x then return {x=math.floor(x*100)/100,y=math.floor(y*100)/100,z=math.floor(z*100)/100} end
end
local function inventory()
  if not turtle then return nil end
  local slots={}
  for i=1,16 do local d=turtle.getItemDetail(i); if d then slots[i]={name=d.name,count=d.count} end end
  return slots
end
local function telemetry()
  local fuel=nil
  if turtle then fuel=turtle.getFuelLevel() end
  return { position=position(), fuel=fuel, inventory=inventory(), job=quarry and {status=quarry.status,done=quarry.done,total=quarry.total,width=quarry.width,length=quarry.length,depth=quarry.depth} or nil }
end
local function send(obj)
  if ws then pcall(function() ws.send(textutils.serializeJSON(obj)) end) end
end
local function sendTelemetry()
  send({type='telemetry',label=config.label,kind=config.kind,peripherals=peripherals(),telemetry=telemetry()})
end

local function playChunk(msg)
  local raw=b64decode(msg.data or '')
  local samples={}
  for i=1,#raw do local v=raw:byte(i); if v>127 then v=v-256 end; samples[i]=v end
  local list=getSpeakers()
  for _,s in ipairs(list) do
    while not s.p.playAudio(samples,msg.volume or 1) do os.pullEvent('speaker_audio_empty') end
  end
end
local function stopAudio()
  for _,s in ipairs(getSpeakers()) do pcall(function() s.p.stop() end) end
end

local function safeForward()
  for _=1,20 do
    if turtle.forward() then return true end
    if turtle.detect() then turtle.dig() else turtle.attack() end
    sleep(0.05)
  end
  return false
end
local function safeDown()
  for _=1,20 do
    if turtle.down() then return true end
    if turtle.detectDown() then turtle.digDown() else turtle.attackDown() end
    sleep(0.05)
  end
  return false
end
local function shouldStop()
  while quarry and quarry.status=='paused' do sleep(0.2) end
  return not quarry or quarry.status=='stopping'
end
local function mineRow(length)
  for i=1,length-1 do
    if shouldStop() then return false end
    if not safeForward() then return false end
    quarry.done=quarry.done+1
  end
  return true
end
local function quarryLayer(width,length)
  for row=1,width do
    if not mineRow(length) then return false end
    if row<width then
      if row%2==1 then turtle.turnRight() else turtle.turnLeft() end
      if not safeForward() then return false end; quarry.done=quarry.done+1
      if row%2==1 then turtle.turnRight() else turtle.turnLeft() end
    end
  end
  return true
end
local function quarryWorker()
  while running do
    local _,job=os.pullEvent('ccnexus_quarry')
    quarry=job; quarry.status='running'; quarry.done=1; quarry.total=math.max(1,job.width*job.length*job.depth)
    send({type='event',message='Quarry started'})
    local ok=true
    for layer=1,quarry.depth do
      if shouldStop() then ok=false break end
      if not quarryLayer(quarry.width,quarry.length) then ok=false break end
      if layer<quarry.depth then
        if quarry.width%2==1 then turtle.turnRight(); turtle.turnRight() end
        turtle.digDown()
        if not safeDown() then ok=false break end
        quarry.done=quarry.done+1
      end
      sendTelemetry()
    end
    if quarry then quarry.status=ok and 'complete' or 'stopped'; sendTelemetry(); send({type='event',message=ok and 'Quarry completed' or 'Quarry stopped'}); sleep(1); quarry=nil end
  end
end

local function handleCommand(c)
  if c.type=='redstone' then redstone.setOutput(c.side or 'back',not not c.on)
  elseif c.type=='redstone_analog' then redstone.setAnalogOutput(c.side or 'back',math.max(0,math.min(15,tonumber(c.strength) or 0)))
  elseif c.type=='quarry_start' and turtle then
    if quarry then send({type='event',message='Quarry already active'}) else os.queueEvent('ccnexus_quarry',{width=math.max(1,math.min(64,tonumber(c.width) or 8)),length=math.max(1,math.min(64,tonumber(c.length) or 8)),depth=math.max(1,math.min(128,tonumber(c.depth) or 8))}) end
  elseif c.type=='quarry_pause' and quarry then quarry.status=quarry.status=='paused' and 'running' or 'paused'
  elseif c.type=='quarry_stop' and quarry then quarry.status='stopping'
  elseif c.type=='reboot' then os.reboot()
  end
end

local function socketLoop()
  while running do
    local wsUrl=config.server:gsub('^http://','ws://'):gsub('^https://','wss://') .. '/ws/device?token=' .. textutils.urlEncode(config.token)
    local conn,err=http.websocket({url=wsUrl,timeout=15})
    if not conn then print('CCNexus reconnect: '..tostring(err)); sleep(4)
    else
      ws=conn; print('CCNexus connected: '..config.label); sendTelemetry()
      while running and ws==conn do
        local raw,why=conn.receive(25)
        if raw then
          local msg=textutils.unserializeJSON(raw)
          if msg then
            if msg.type=='command' and msg.command then handleCommand(msg.command)
            elseif msg.type=='audio_chunk' then playChunk(msg)
            elseif msg.type=='audio_stop' then stopAudio()
            elseif msg.type=='audio_end' then if not msg.ok then print('Audio error: '..tostring(msg.error)) end end
          end
        elseif why and why~='Timed out' then break end
      end
      pcall(function() conn.close() end); ws=nil
      if running then sleep(2) end
    end
  end
end
local function heartbeatLoop()
  while running do sleep(2); if ws then sendTelemetry() end end
end

print('CCNexus Agent v0.1.0')
if turtle then parallel.waitForAny(socketLoop,heartbeatLoop,quarryWorker) else parallel.waitForAny(socketLoop,heartbeatLoop) end
