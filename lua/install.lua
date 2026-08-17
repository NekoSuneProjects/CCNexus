local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
local function normalize(url)
  url = trim(url)
  if not url:match('^https?://') then url = 'https://' .. url end
  return url:gsub('/+$', '')
end

term.clear(); term.setCursorPos(1, 1)
print('CCNexus Installer v0.2')
print('======================')
print('Each pairing code is tied to one Server/World workspace.')
print('')
write('Dashboard domain / URL: ')
local server = normalize(read())
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
local startup = fs.open('/startup/ccnexus.lua', 'w'); startup.write('shell.run("/ccnexus/agent.lua")\n'); startup.close()

print('\nInstalled successfully!')
print('Device: ' .. label)
print('Workspace: ' .. tostring(data.worldName or data.worldId))
print('Cached dashboard data remains visible when this world is offline.')
print('Starting CCNexus agent...')
sleep(1)
shell.run('/ccnexus/agent.lua')
