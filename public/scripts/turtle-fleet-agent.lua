-- CCNexus Turtle Fleet bootstrap v0.3-flat
-- Existing Fleet startup hooks download this file automatically. It installs the
-- Flat Nexus GPS shim, refreshes the Fleet core, then starts the normal Fleet agent.

local CONFIG='/ccnexus/config.json'
local CORE='/ccnexus/turtle-fleet-agent-core.lua'
local SHIM='/ccnexus/flat-gps-shim.lua'

if not fs.exists(CONFIG) then error('CCNexus config missing. Run the normal installer first.',0) end
local h=fs.open(CONFIG,'r'); local cfg=textutils.unserializeJSON(h.readAll()); h.close()
if type(cfg)~='table' or not cfg.server then error('Invalid CCNexus config.',0) end
local server=tostring(cfg.server):gsub('/+$','')

local function download(url,path,minSize)
  local r,err=http.get(url)
  if not r then return false,err end
  local data=r.readAll(); r.close()
  if not data or #data < (minSize or 100) then return false,'download unexpectedly small' end
  local tmp=path..'.new'
  local out=fs.open(tmp,'w'); if not out then return false,'cannot write '..tmp end
  out.write(data); out.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp,path)
  return true
end

if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
local shimOk,shimErr=download(server..'/scripts/flat-gps-shim.lua',SHIM,1000)
if not shimOk then
  print('[CCNexus Fleet] Flat GPS update failed: '..tostring(shimErr))
  if not fs.exists(SHIM) then error('Flat GPS shim unavailable.',0) end
end
local coreOk,coreErr=download(server..'/scripts/turtle-fleet-agent-core.lua',CORE,5000)
if not coreOk then
  print('[CCNexus Fleet] Core update failed: '..tostring(coreErr))
  if not fs.exists(CORE) then error('Fleet core unavailable.',0) end
end

local ok,flat=pcall(dofile,SHIM)
if ok then
  local selected=gps.flatGetQuarry and gps.flatGetQuarry() or ''
  print('[CCNexus Fleet] Flat Nexus GPS enabled'..(selected~='' and (' for '..selected) or ''))
else
  error('Unable to load Flat Nexus GPS: '..tostring(flat),0)
end

shell.run(CORE)
