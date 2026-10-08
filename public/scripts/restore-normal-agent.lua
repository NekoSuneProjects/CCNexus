-- Restore the normal CCNexus agent startup on a turtle.
local CONFIG='/ccnexus/config.json'
local STARTUP='/startup/ccnexus.lua'
local BACKUP='/ccnexus/computer-agent-startup.backup.lua'
if not fs.exists(CONFIG) then error('CCNexus config missing.',0) end

if fs.exists(BACKUP) then
  local f=fs.open(BACKUP,'r'); local data=f.readAll(); f.close()
  local out=fs.open(STARTUP,'w'); out.write(data); out.close()
else
  local code=[[
local CONFIG='/ccnexus/config.json'
local AGENT='/ccnexus/agent.lua'
local TMP='/ccnexus/agent.new.lua'
if fs.exists(CONFIG) then
  local f=fs.open(CONFIG,'r'); local cfg=textutils.unserializeJSON(f.readAll()); f.close()
  if cfg and cfg.server then
    local h=http.get(tostring(cfg.server):gsub('/+$','')..'/ccnexus.lua')
    if h then local data=h.readAll(); h.close(); if data and #data>100 then local o=fs.open(TMP,'w'); o.write(data); o.close(); if fs.exists(AGENT) then fs.delete(AGENT) end; fs.move(TMP,AGENT) end end
  end
end
shell.run(AGENT)
]]
  local out=fs.open(STARTUP,'w'); out.write(code); out.close()
end
print('Normal CCNexus startup restored. Rebooting...')
sleep(1)
os.reboot()
