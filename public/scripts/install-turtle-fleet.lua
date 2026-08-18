-- CCNexus Turtle Fleet installer
-- Run this AFTER the normal CCNexus installer has paired this turtle once.

local CONFIG = '/ccnexus/config.json'
if not turtle then error('This installer is only for turtles.', 0) end
if not fs.exists(CONFIG) then
  error('CCNexus is not paired yet. Run your dashboard /install.lua first, pair the turtle, then run this installer.', 0)
end

local f = fs.open(CONFIG, 'r')
local cfg = textutils.unserializeJSON(f.readAll())
f.close()
if type(cfg) ~= 'table' or not cfg.server then error('Invalid /ccnexus/config.json', 0) end

local server = tostring(cfg.server):gsub('/+$', '')
local url = server .. '/scripts/turtle-fleet-agent.lua'
local AGENT = '/ccnexus/turtle-fleet-agent.lua'
local TMP = '/ccnexus/turtle-fleet-agent.new.lua'
local STARTUP = '/startup/ccnexus.lua'
local BACKUP = '/ccnexus/computer-agent-startup.backup.lua'

term.clear(); term.setCursorPos(1,1)
print('CCNexus Turtle Fleet Installer')
print('==============================')
print('Dashboard: ' .. server)
print('Downloading: ' .. url)

local h, err = http.get(url)
if not h then error('Unable to download Turtle Fleet agent: ' .. tostring(err), 0) end
local data = h.readAll(); h.close()
if not data or #data < 1000 then error('Downloaded Turtle Fleet agent is unexpectedly small.', 0) end

local out = fs.open(TMP, 'w'); out.write(data); out.close()
if fs.exists(AGENT) then fs.delete(AGENT) end
fs.move(TMP, AGENT)

if not fs.exists('/startup') then fs.makeDir('/startup') end
if fs.exists(STARTUP) and not fs.exists(BACKUP) then
  local old = fs.open(STARTUP, 'r')
  local oldData = old and old.readAll() or nil
  if old then old.close() end
  if oldData then local b = fs.open(BACKUP, 'w'); b.write(oldData); b.close() end
end

local startupCode = [[
local CONFIG = '/ccnexus/config.json'
local AGENT = '/ccnexus/turtle-fleet-agent.lua'
local TMP = '/ccnexus/turtle-fleet-agent.new.lua'
if fs.exists(CONFIG) then
  local f = fs.open(CONFIG, 'r')
  local cfg = textutils.unserializeJSON(f.readAll())
  f.close()
  if cfg and cfg.server then
    local h = http.get(tostring(cfg.server):gsub('/+$','') .. '/scripts/turtle-fleet-agent.lua')
    if h then
      local data = h.readAll(); h.close()
      if data and #data > 1000 then
        local out = fs.open(TMP, 'w'); out.write(data); out.close()
        if fs.exists(AGENT) then fs.delete(AGENT) end
        fs.move(TMP, AGENT)
        print('CCNexus Turtle Fleet agent updated from dashboard.')
      end
    else
      print('Fleet update unavailable; using cached Turtle Fleet agent.')
    end
  end
end
shell.run(AGENT)
]]

local startup = fs.open(STARTUP, 'w'); startup.write(startupCode); startup.close()

print('')
print('Turtle Fleet mode installed.')
print('The normal computer/speaker agent startup was backed up to:')
print(BACKUP)
print('')
print('This turtle will now use the specialised fleet agent after reboot.')
print('Rebooting in 2 seconds...')
sleep(2)
os.reboot()
