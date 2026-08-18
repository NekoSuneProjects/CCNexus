-- CCNexus Flat Nexus GPS shim v1
-- Replaces gps.locate() inside CCNexus Fleet turtles with four-corner wireless
-- ranging from NW/NE/SW/SE marker computers. No Command Computer or raised GPS
-- host is required.
--
-- Marker coordinate plane:
--   NW = (0,0,0)        NE = (width,0,0)
--   SW = (0,0,length)   SE = (width,0,length)
-- Y is CCNexus depth relative to the marker-computer plane. Below is negative.

local CHANNEL = 65532
local PROTOCOL = 'ccnexus-flat-gps-v1'
local CONFIG = '/ccnexus/flat-gps.json'
local roles = { NW=true, NE=true, SW=true, SE=true }

local function trim(v)
  return (tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end
local function mean(values)
  local sum, n = 0, 0
  for _, v in ipairs(values or {}) do
    v = tonumber(v)
    if v and v > 0 then sum = sum + v; n = n + 1 end
  end
  if n == 0 then return nil end
  return sum / n
end
local function round3(v)
  if not v then return nil end
  return math.floor(v * 1000 + 0.5) / 1000
end
local function ensureDir()
  if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
end
local function loadConfig()
  if not fs.exists(CONFIG) then return {} end
  local h = fs.open(CONFIG, 'r'); if not h then return {} end
  local ok, d = pcall(textutils.unserializeJSON, h.readAll()); h.close()
  if ok and type(d) == 'table' then return d end
  return {}
end
local function saveConfig(d)
  ensureDir()
  local h = fs.open(CONFIG, 'w')
  if h then h.write(textutils.serializeJSON(d)); h.close(); return true end
  return false
end

local cfg = loadConfig()
local lastStatus = { ok=false, error='not located yet' }

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
if modem then modem.open(CHANNEL) end

local function parse(message, distance)
  if type(message) ~= 'string' or tonumber(distance) == nil then return nil end
  local ok, m = pcall(textutils.unserializeJSON, message)
  if not ok or type(m) ~= 'table' or m.protocol ~= PROTOCOL then return nil end
  local role = trim(m.role):upper()
  local quarry = trim(m.quarry)
  if quarry == '' or not roles[role] then return nil end
  local peers = {}
  if type(m.peers) == 'table' then
    for k, v in pairs(m.peers) do
      local r = trim(k):upper()
      local d = tonumber(type(v) == 'table' and v.distance or v)
      if roles[r] and d and d > 0 then peers[r] = d end
    end
  end
  return {
    quarry=quarry, role=role, computerId=tonumber(m.computerId),
    distance=tonumber(distance), peers=peers,
    modemSide=trim(m.modemSide):lower(), planeOffsetY=tonumber(m.planeOffsetY) or 0,
    timestamp=tonumber(m.timestamp) or 0
  }
end

local function pairDistance(group, a, b)
  local values = {}
  if group[a] and group[a].peers[b] then values[#values+1] = group[a].peers[b] end
  if group[b] and group[b].peers[a] then values[#values+1] = group[b].peers[a] end
  return mean(values)
end

local function geometry(group)
  if not (group and group.NW and group.NE and group.SW and group.SE) then
    return nil, 'waiting for NW/NE/SW/SE'
  end
  local top = pairDistance(group, 'NW', 'NE')
  local bottom = pairDistance(group, 'SW', 'SE')
  local left = pairDistance(group, 'NW', 'SW')
  local right = pairDistance(group, 'NE', 'SE')
  local width = mean({top, bottom})
  local length = mean({left, right})
  if not width or not length then return nil, 'markers have not learned both rectangle side lengths yet' end
  if width < 2 or length < 2 then return nil, 'marker rectangle is too small' end

  local edgeTol = math.max(1.25, math.max(width, length) * 0.04)
  if top and bottom and math.abs(top-bottom) > edgeTol then
    return nil, ('top/bottom width mismatch %.2f blocks'):format(math.abs(top-bottom))
  end
  if left and right and math.abs(left-right) > edgeTol then
    return nil, ('left/right length mismatch %.2f blocks'):format(math.abs(left-right))
  end

  local diag1 = pairDistance(group, 'NW', 'SE')
  local diag2 = pairDistance(group, 'NE', 'SW')
  local expectedDiag = math.sqrt(width*width + length*length)
  local diagTol = math.max(1.75, expectedDiag * 0.04)
  if diag1 and math.abs(diag1-expectedDiag) > diagTol then return nil, 'NW-SE diagonal does not match a flat rectangle' end
  if diag2 and math.abs(diag2-expectedDiag) > diagTol then return nil, 'NE-SW diagonal does not match a flat rectangle' end

  local offsets = {}
  for _, r in ipairs({'NW','NE','SW','SE'}) do offsets[#offsets+1] = tonumber(group[r].planeOffsetY) or 0 end
  local planeOffsetY = mean(offsets) or 0
  local side = group.NW.modemSide
  for _, r in ipairs({'NE','SW','SE'}) do
    if group[r].modemSide ~= side then return nil, 'all four marker modems must be mounted on the same side' end
  end
  if side ~= 'top' then return nil, 'Flat Nexus GPS currently requires top-mounted marker modems' end

  return {
    width=width, length=length, top=top, bottom=bottom, left=left, right=right,
    diag1=diag1, diag2=diag2, planeOffsetY=planeOffsetY, modemSide=side,
    diagonalVerified=diag1 ~= nil or diag2 ~= nil
  }
end

local function solve(group, g)
  local rn, re, rs, rse = group.NW.distance, group.NE.distance, group.SW.distance, group.SE.distance
  if not (rn and re and rs and rse) then return nil, 'turtle cannot hear all four flat markers' end
  local w, l = g.width, g.length
  local x1 = (rn*rn - re*re + w*w) / (2*w)
  local x2 = (rs*rs - rse*rse + w*w) / (2*w)
  local z1 = (rn*rn - rs*rs + l*l) / (2*l)
  local z2 = (re*re - rse*rse + l*l) / (2*l)
  local x, z = (x1+x2)/2, (z1+z2)/2

  local anchors = {
    {0,0,rn},{w,0,re},{0,l,rs},{w,l,rse}
  }
  local hValues = {}
  for _, a in ipairs(anchors) do
    local horizontal2 = (x-a[1])^2 + (z-a[2])^2
    hValues[#hValues+1] = a[3]^2 - horizontal2
  end
  local h2 = mean(hValues)
  if not h2 then return nil, 'unable to solve vertical depth' end
  if h2 < -2.5 then return nil, ('ranging solution is inconsistent (h2 %.2f)'):format(h2) end
  local depthFromModemPlane = math.sqrt(math.max(0, h2))
  local y = g.planeOffsetY - depthFromModemPlane

  local residual2 = 0
  for _, a in ipairs(anchors) do
    local predicted = math.sqrt((x-a[1])^2 + (z-a[2])^2 + (y-g.planeOffsetY)^2)
    residual2 = residual2 + (predicted-a[3])^2
  end
  local rms = math.sqrt(residual2/4)
  local tolerance = math.max(1.2, math.max(w,l)*0.02)
  if rms > tolerance then return nil, ('flat ranging residual too high: %.2f'):format(rms) end

  return {
    x=x, y=y, z=z, quarry=group.NW.quarry,
    width=w, length=l, rms=rms,
    diagonalVerified=g.diagonalVerified, planeOffsetY=g.planeOffsetY,
    distances={NW=rn,NE=re,SW=rs,SE=rse}
  }
end

local function collect(timeout, preferred)
  if not modem then modemName, modem = findWirelessModem(); if modem then modem.open(CHANNEL) end end
  if not modem then return nil, 'no Wireless Modem attached to turtle' end
  local groups = {}
  local timer = os.startTimer(math.max(0.25, tonumber(timeout) or 2))
  while true do
    local e = { os.pullEvent() }
    if e[1] == 'timer' and e[2] == timer then break end
    if e[1] == 'modem_message' and e[3] == CHANNEL then
      local m = parse(e[5], e[6])
      if m and (not preferred or preferred == '' or m.quarry == preferred) then
        groups[m.quarry] = groups[m.quarry] or {}
        groups[m.quarry][m.role] = m
        local g, gerr = geometry(groups[m.quarry])
        if g then
          local p, perr = solve(groups[m.quarry], g)
          if p then return p end
        end
      end
    end
  end
  if preferred and preferred ~= '' then
    local g, err = geometry(groups[preferred])
    if not g then return nil, err or ('no complete marker set for '..preferred) end
    return solve(groups[preferred], g)
  end
  local lastErr = 'no complete Flat Nexus marker set heard'
  for _, group in pairs(groups) do
    local g, err = geometry(group)
    if g then local p, perr = solve(group, g); if p then return p end; lastErr = perr or lastErr else lastErr = err or lastErr end
  end
  return nil, lastErr
end

local M = {}
function M.locate(timeout, preferred)
  preferred = trim(preferred or cfg.quarry)
  local p, err = collect(timeout or 2, preferred)
  if p then
    if preferred == '' then cfg.quarry = p.quarry; saveConfig(cfg) end
    lastStatus = {ok=true, at=os.epoch('utc'), quarry=p.quarry, x=p.x,y=p.y,z=p.z,width=p.width,length=p.length,rms=p.rms,diagonalVerified=p.diagonalVerified}
    _G.CCNEXUS_FLAT_GPS_LAST = lastStatus
    return p
  end
  lastStatus = {ok=false, at=os.epoch('utc'), quarry=preferred, error=tostring(err or 'flat GPS unavailable')}
  _G.CCNEXUS_FLAT_GPS_LAST = lastStatus
  return nil, err
end
function M.status() return lastStatus end
function M.setQuarry(name)
  cfg.quarry = trim(name)
  saveConfig(cfg)
  return cfg.quarry
end
function M.getQuarry() return trim(cfg.quarry) end

if not gps._ccnexusNativeLocate then gps._ccnexusNativeLocate = gps.locate end
gps.flatLocate = M.locate
gps.flatStatus = M.status
gps.flatSetQuarry = M.setQuarry
gps.flatGetQuarry = M.getQuarry
gps.locate = function(timeout, debug)
  local p, err = M.locate(timeout or 2)
  if not p then
    if debug then print('[Flat Nexus GPS] ' .. tostring(err)) end
    return nil
  end
  if debug then
    print(('[Flat Nexus GPS] %s  X %.3f Y %.3f Z %.3f  %0.2fx%0.2f  rms %.3f'):format(p.quarry,p.x,p.y,p.z,p.width,p.length,p.rms))
  end
  return p.x, p.y, p.z
end

_G.CCNEXUS_FLAT_GPS = M
return M
