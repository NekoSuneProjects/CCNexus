local AUTO_SERVER = '__CCNEXUS_AUTO_SERVER__'
local args = { ... }

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function normalize(url)
  url = trim(url)
  if url == '' then return '' end
  if not url:match('^https?://') then url = 'https://' .. url end
  return url:gsub('/+$', '')
end

local function validServer(url)
  url = trim(url)
  return url ~= '' and url ~= '__CCNEXUS_AUTO_SERVER__' and url:match('^https?://') ~= nil
end

local server
local detected = false

-- When /install.lua is served by CCNexus, the server replaces AUTO_SERVER with
-- the same public origin which served this file. Stock CC:Tweaked `wget run`
-- does not expose its source URL to the downloaded Lua chunk, so injection is
-- the only reliable way to auto-detect the custom domain without an extra arg.
if validServer(AUTO_SERVER) then
  server = normalize(AUTO_SERVER)
  detected = true
elseif validServer(args[1]) then
  -- Useful when a locally copied installer is launched with an explicit URL:
  -- install.lua https://ccnexus.example.com
  server = normalize(args[1])
end

term.clear(); term.setCursorPos(1, 1)
print('CCNexus Installer v0.3')
print('======================')
print('Each pairing code is tied to one Server/World workspace.')
print('The startup hook checks for the newest CCNexus agent before every boot.')
print('')

if server then
  print('Dashboard: ' .. server .. (detected and '  [auto-detected]' or '  [argument]'))
else
  print('No hosted CCNexus URL could be detected.')
  print('This normally means install.lua was saved/run locally.')
  write('Dashboard domain / URL: ')
  repeat
    server = normalize(read())
    if server == '' then write('Please enter a dashboard URL: ') end
  until server ~= ''
end

write('10-minute pairing code: ')
local code = trim(read())
write('Device name (optional): ')
local label = trim(read())
if label == '' then label = (turtle and 'Turtle ' or 'Computer ') .. os.getComputerID() end
local kind = turtle and 'turtle' or 'computer'

print('\nPairing with ' .. server .. ' ...')
local body = textutils.serializeJSON({ code = code, computerId = os.getComputerID(), label = label, kind = kind })
local response, err = http.post(server .. '/api/pair', body, { ['Content-Type'] = 'application/json' })
if not response then error('Pairing failed: ' .. tostring(err), 0) end
local raw = response.readAll(); response.close()
local data = textutils.unserializeJSON(raw)
if not data or not data.deviceToken then error('Pairing was rejected: ' .. raw, 0) end

if not fs.exists('/ccnexus') then fs.makeDir('/ccnexus') end
local agent, agentErr = http.get(server .. '/ccnexus.lua')
if not agent then error('Unable to download agent: ' .. tostring(agentErr), 0) end
local f = fs.open('/ccnexus/agent.lua', 'w'); f.write(agent.readAll()); f.close(); agent.close()
local cfg = fs.open('/ccnexus/config.json', 'w')
cfg.write(textutils.serializeJSON({ server = server, deviceId = data.deviceId, token = data.deviceToken, label = label, kind = kind, worldId = data.worldId, worldName = data.worldName, monitorPage = 'overview' }))
cfg.close()

if not fs.exists('/startup') then fs.makeDir('/startup') end
local startupCode = [[
local CONFIG = '/ccnexus/config.json'
local AGENT = '/ccnexus/agent.lua'
local TMP = '/ccnexus/agent.new.lua'
local BACKUP = '/ccnexus/agent.backup.lua'
if fs.exists(CONFIG) then
  local f = fs.open(CONFIG, 'r')
  local cfg = textutils.unserializeJSON(f.readAll())
  f.close()
  if cfg and cfg.server then
    local h = http.get(cfg.server .. '/ccnexus.lua')
    if h then
      local data = h.readAll(); h.close()
      if data and #data > 100 then
        local out = fs.open(TMP, 'w'); out.write(data); out.close()
        if fs.exists(BACKUP) then fs.delete(BACKUP) end
        if fs.exists(AGENT) then fs.move(AGENT, BACKUP) end
        fs.move(TMP, AGENT)
        print('CCNexus agent updated from dashboard.')
      end
    else
      print('CCNexus update check unavailable; using cached agent.')
    end
  end
end
shell.run(AGENT)
]]
local startup = fs.open('/startup/ccnexus.lua', 'w'); startup.write(startupCode); startup.close()

print('\nInstalled successfully!')
print('Device: ' .. label)
print('Workspace: ' .. tostring(data.worldName or data.worldId))
print('Dashboard: ' .. server)
print('Future dashboard fleet updates can warn, reboot, then self-update this node.')
print('Starting CCNexus agent...')
sleep(1)
shell.run('/ccnexus/agent.lua')
