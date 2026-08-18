-- CCNexus Flat Nexus GPS tester
-- Usage on a paired turtle/computer with Wireless Modem:
--   wget run <CCNexus>/scripts/flat-gps-test.lua Quarry1

local args={...}
local preferred=tostring(args[1] or '')
local CONFIG='/ccnexus/config.json'
local SHIM='/ccnexus/flat-gps-shim.lua'

local function trim(v) return (tostring(v or ''):gsub('^%s+',''):gsub('%s+$','')) end
local function fail(msg) printError and printError(msg) or print('ERROR: '..tostring(msg)); return end

if not fs.exists(CONFIG) then fail('CCNexus config missing. Pair this turtle/computer first.'); return end
local h=fs.open(CONFIG,'r'); local cfg=textutils.unserializeJSON(h.readAll()); h.close()
if type(cfg)~='table' or not cfg.server then fail('Invalid CCNexus config.'); return end
local server=tostring(cfg.server):gsub('/+$','')
local r,err=http.get(server..'/scripts/flat-gps-shim.lua')
if not r then fail('Unable to download Flat GPS shim: '..tostring(err)); return end
local data=r.readAll(); r.close()
if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
local out=fs.open(SHIM,'w'); out.write(data); out.close()
local flat=dofile(SHIM)
if trim(preferred)~='' and gps.flatSetQuarry then gps.flatSetQuarry(trim(preferred)) end

term.clear(); term.setCursorPos(1,1)
print('CCNexus Flat Nexus GPS Test')
print('===========================')
print('')
print('Listening for four flat markers...')
local x,y,z=gps.locate(4,true)
print('')
if not x then
  local st=gps.flatStatus and gps.flatStatus() or {}
  print('NO FLAT GPS FIX')
  print(tostring(st.error or 'Unknown ranging error'))
  print('')
  print('Check:')
  print('- NW / NE / SW / SE all powered')
  print('- all four computers on same Y level')
  print('- Wireless Modem mounted on TOP of every marker')
  print('- turtle is within wireless range of all four markers')
  return
end
local st=gps.flatStatus and gps.flatStatus() or {}
print('FLAT GPS FIX OK')
print(('Quarry: %s'):format(tostring(st.quarry or preferred)))
print(('X %.3f'):format(x))
print(('Y %.3f  (0 = marker surface, negative = depth)'):format(y))
print(('Z %.3f'):format(z))
if st.width and st.length then print(('Rectangle %.2f x %.2f'):format(st.width,st.length)) end
if st.rms then print(('Ranging RMS %.3f'):format(st.rms)) end
print('Source: NEXUS FLAT GPS')
