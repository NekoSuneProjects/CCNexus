-- CCNexus Flat Nexus quarry launcher
-- Loads the Flat GPS shim, then runs the existing marker-anchored quarry service.
-- Usage:
--   wget run <CCNexus>/scripts/flat-quarry.lua Quarry1 mine
--   wget run <CCNexus>/scripts/flat-quarry.lua Quarry1 rescue

local args={...}
local quarry=tostring(args[1] or 'Quarry1')
local mode=tostring(args[2] or 'mine')
local CONFIG='/ccnexus/config.json'
local SHIM='/ccnexus/flat-gps-shim.lua'
local SERVICE='/ccnexus/quarry-service.lua'

if not turtle then error('This launcher must run on a turtle.',0) end
if not fs.exists(CONFIG) then error('CCNexus config missing. Pair this turtle first.',0) end
local h=fs.open(CONFIG,'r'); local cfg=textutils.unserializeJSON(h.readAll()); h.close()
if type(cfg)~='table' or not cfg.server then error('Invalid CCNexus config.',0) end
local server=tostring(cfg.server):gsub('/+$','')

local function download(url,path)
  local r,err=http.get(url)
  if not r then return false,err end
  local data=r.readAll(); r.close()
  local out=fs.open(path,'w'); if not out then return false,'cannot write '..path end
  out.write(data); out.close(); return true
end
if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
local ok,err=download(server..'/scripts/flat-gps-shim.lua',SHIM)
if not ok then error('Flat GPS download failed: '..tostring(err),0) end
ok,err=download(server..'/scripts/quarry-service.lua',SERVICE)
if not ok then error('Quarry service download failed: '..tostring(err),0) end

dofile(SHIM)
if gps.flatSetQuarry then gps.flatSetQuarry(quarry) end
print('Flat Nexus GPS loaded for '..quarry)
print('Starting quarry service mode: '..mode)
shell.run(SERVICE,quarry,mode)
