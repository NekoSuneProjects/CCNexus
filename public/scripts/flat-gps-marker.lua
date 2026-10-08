-- CCNexus Flat Nexus GPS / Quarry Marker v1
-- One of four stationary markers: NW / NE / SW / SE.
-- The same four computers provide Flat GPS ranging and quarry boundaries.
--
-- IMPORTANT: Put all four marker computers on the same block Y level and attach
-- each Wireless Modem on TOP of its computer. Keep rectangle sides aligned to
-- Minecraft block rows. No native gps host, Command Computer, OP or F3 needed.
--
-- Usage:
--   flat-gps-marker.lua Quarry1 NW
--   flat-gps-marker.lua Quarry1 NE
--   flat-gps-marker.lua Quarry1 SW
--   flat-gps-marker.lua Quarry1 SE
--   flat-gps-marker.lua reset

local CONFIG = '/ccnexus/flat-gps-marker.json'
local FLAT_CHANNEL = 65532
local QUARRY_CHANNEL = 65533
local FLAT_PROTOCOL = 'ccnexus-flat-gps-v1'
local QUARRY_PROTOCOL = 'ccnexus-quarry-marker-v1'
local args = { ... }
local validRole = {NW=true,NE=true,SW=true,SE=true}

local function trim(v) return (tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function setColor(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function ensureDir() if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end end
local function save(cfg)
  ensureDir(); local h=fs.open(CONFIG,'w'); if not h then return false end
  h.write(textutils.serializeJSON(cfg)); h.close(); return true
end
local function load()
  if not fs.exists(CONFIG) then return nil end
  local h=fs.open(CONFIG,'r'); if not h then return nil end
  local ok,cfg=pcall(textutils.unserializeJSON,h.readAll()); h.close()
  if not ok or type(cfg)~='table' then return nil end
  cfg.quarry=trim(cfg.quarry); cfg.role=trim(cfg.role):upper()
  if cfg.quarry=='' or not validRole[cfg.role] then return nil end
  return cfg
end
local function fail(msg)
  setColor(colors.red); print('ERROR: '..tostring(msg)); setColor(colors.white); return false
end

if tostring(args[1] or ''):lower()=='reset' then
  if fs.exists(CONFIG) then fs.delete(CONFIG) end
  print('Flat marker configuration removed.'); return
end

local modem = peripheral.wrap('top')
if not modem or type(modem.isWireless)~='function' then
  fail('Attach a Wireless Modem on TOP of this computer.'); return
end
local okWireless, isWireless = pcall(modem.isWireless)
if not okWireless or not isWireless then fail('The top modem must be wireless.'); return end

local cfg=load()
local requestedQuarry=trim(args[1])
local requestedRole=trim(args[2]):upper()
if requestedQuarry~='' then
  if not validRole[requestedRole] then fail('Role must be NW, NE, SW, or SE.'); return end
  cfg={quarry=requestedQuarry:sub(1,48),role=requestedRole}
  if not save(cfg) then fail('Unable to save '..CONFIG); return end
elseif not cfg then
  write('Quarry / Flat GPS name [Quarry1]: '); local q=trim(read()); if q=='' then q='Quarry1' end
  write('Corner [NW/NE/SW/SE]: '); local r=trim(read()):upper()
  if not validRole[r] then fail('Role must be NW, NE, SW, or SE.'); return end
  cfg={quarry=q:sub(1,48),role=r}; if not save(cfg) then fail('Unable to save configuration.'); return end
end

modem.open(FLAT_CHANNEL)
modem.open(QUARRY_CHANNEL)
local peers={}
local count=0
local lastGeometry

local function parseFlat(message)
  if type(message)~='string' then return nil end
  local ok,m=pcall(textutils.unserializeJSON,message)
  if not ok or type(m)~='table' or m.protocol~=FLAT_PROTOCOL then return nil end
  local role=trim(m.role):upper()
  if trim(m.quarry)~=cfg.quarry or not validRole[role] or role==cfg.role then return nil end
  return m,role
end

local function getDistance(role)
  local p=peers[role]
  if not p or os.epoch('utc')-(p.at or 0)>10000 then return nil end
  return tonumber(p.distance)
end

local function geometry()
  local width,length,diag
  if cfg.role=='NW' then width=getDistance('NE'); length=getDistance('SW'); diag=getDistance('SE')
  elseif cfg.role=='NE' then width=getDistance('NW'); length=getDistance('SE'); diag=getDistance('SW')
  elseif cfg.role=='SW' then width=getDistance('SE'); length=getDistance('NW'); diag=getDistance('NE')
  elseif cfg.role=='SE' then width=getDistance('SW'); length=getDistance('NE'); diag=getDistance('NW') end
  if not width or not length then return nil,'waiting for adjacent corner ranges' end
  local expected=math.sqrt(width*width+length*length)
  if diag then
    local tolerance=math.max(1.75,expected*0.04)
    if math.abs(diag-expected)>tolerance then return nil,'corners are not a flat rectangle' end
  end
  local x,z=0,0
  if cfg.role=='NE' or cfg.role=='SE' then x=width end
  if cfg.role=='SW' or cfg.role=='SE' then z=length end
  return {width=width,length=length,diag=diag,x=x,y=0,z=z,verified=diag~=nil}
end

local function peerPayload()
  local out={}
  local now=os.epoch('utc')
  for role,p in pairs(peers) do
    if now-(p.at or 0)<=10000 then out[role]={distance=p.distance,at=p.at} end
  end
  return out
end

local function broadcast()
  local now=os.epoch('utc')
  local packet=textutils.serializeJSON({
    protocol=FLAT_PROTOCOL,quarry=cfg.quarry,role=cfg.role,computerId=os.getComputerID(),
    modemSide='top',planeOffsetY=1,peers=peerPayload(),timestamp=now
  })
  modem.transmit(FLAT_CHANNEL,FLAT_CHANNEL,packet)
  local g=geometry(); lastGeometry=g
  if g then
    -- Compatibility broadcast: existing quarry scripts see the same four machines
    -- as a normal local-coordinate quarry rectangle.
    modem.transmit(QUARRY_CHANNEL,QUARRY_CHANNEL,textutils.serializeJSON({
      protocol=QUARRY_PROTOCOL,quarry=cfg.quarry,marker=cfg.role,computerId=os.getComputerID(),
      x=g.x,y=0,z=g.z,timestamp=now,flatGps=true
    }))
  end
  count=count+1
end

local function draw()
  local g,err=geometry(); lastGeometry=g
  term.clear(); term.setCursorPos(1,1)
  setColor(colors.cyan); print('CCNexus Flat GPS / Quarry'); setColor(colors.white)
  print('')
  print('Quarry:   '..cfg.quarry)
  print('Corner:   '..cfg.role)
  print('Computer: #'..os.getComputerID())
  print('Modem:    top')
  print('Channels: '..FLAT_CHANNEL..' / '..QUARRY_CHANNEL)
  print('')
  local peerCount=0; for _ in pairs(peers) do peerCount=peerCount+1 end
  print('Peers heard: '..peerCount..'/3')
  if g then
    setColor(colors.lime)
    print(g.verified and 'FLAT NEXUS READY / RECTANGLE VERIFIED' or 'FLAT NEXUS READY / DIAGONAL UNVERIFIED')
    setColor(colors.white)
    print(('Width %.2f  Length %.2f'):format(g.width,g.length))
    print(('Local anchor X %.2f Y 0 Z %.2f'):format(g.x,g.z))
    if not g.verified then setColor(colors.yellow); print('Diagonal marker is out of radio range; side geometry only.'); setColor(colors.white) end
  else
    setColor(colors.yellow); print('CALIBRATING: '..tostring(err)); setColor(colors.white)
    print('All four computers must be on the same Y level.')
    print('Keep Wireless Modems mounted on TOP.')
  end
  print('')
  print('Broadcasts: '..count)
  print('Leave this marker powered while Fleet turtles work.')
end

draw()
local timer=os.startTimer(0.2)
while true do
  local e={os.pullEvent()}
  if e[1]=='modem_message' and e[3]==FLAT_CHANNEL then
    local m,role=parseFlat(e[5])
    local distance=tonumber(e[6])
    if m and role and distance then peers[role]={distance=distance,at=os.epoch('utc')} end
  elseif e[1]=='timer' and e[2]==timer then
    broadcast(); draw(); timer=os.startTimer(0.5)
  end
end
