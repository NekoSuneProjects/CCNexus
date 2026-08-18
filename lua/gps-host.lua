-- CCNexus GPS Host
--
-- Command Computers can detect their own block position automatically.
-- Normal/Advanced Computers cannot know their absolute position until GPS is
-- already working, so they ask for the F3 Targeted Block coordinates once and
-- save them for every future boot.

local CONFIG = "/gps-host.json"
local args = { ... }

local function setColor(color)
  if term.isColor and term.isColor() then term.setTextColor(color) end
end

local function fail(message)
  setColor(colors.red)
  print("ERROR: " .. tostring(message))
  setColor(colors.white)
  return false
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readNumber(prompt)
  while true do
    write(prompt)
    local value = tonumber(trim(read()))
    if value then return value end
    setColor(colors.red)
    print("Please enter a valid number.")
    setColor(colors.white)
  end
end

local function saveConfig(config)
  local handle = fs.open(CONFIG, "w")
  if not handle then return false end
  handle.write(textutils.serializeJSON(config))
  handle.close()
  return true
end

local function loadConfig()
  if not fs.exists(CONFIG) then return nil end
  local handle = fs.open(CONFIG, "r")
  if not handle then return nil end
  local raw = handle.readAll()
  handle.close()
  local ok, data = pcall(textutils.unserializeJSON, raw)
  if not ok or type(data) ~= "table" then return nil end
  if tonumber(data.x) == nil or tonumber(data.y) == nil or tonumber(data.z) == nil then return nil end
  return { x = tonumber(data.x), y = tonumber(data.y), z = tonumber(data.z), source = data.source or "saved" }
end

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local modem = peripheral.wrap(name)
    if modem and type(modem.isWireless) == "function" then
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then return name, modem end
    end
  end
  return nil
end

term.clear()
term.setCursorPos(1, 1)
setColor(colors.cyan)
print("CCNexus GPS Host")
print("================")
setColor(colors.white)
print("")

local modemName = findWirelessModem()
if not modemName then
  fail("No Wireless or Ender Modem is attached.")
  print("Attach a Wireless Modem or Ender Modem and reboot this computer.")
  return
end

local x, y, z
local source
local dimension = "unknown"

-- Optional explicit coordinates are useful for scripted installs:
-- gps-host.lua 100 64 -200
if tonumber(args[1]) and tonumber(args[2]) and tonumber(args[3]) then
  x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
  source = "arguments"
  saveConfig({ x = x, y = y, z = z, source = source })

-- Command Computers are the one CC:Tweaked computer type which can discover
-- their own absolute Minecraft position without an existing GPS constellation.
elseif type(commands) == "table" and type(commands.getBlockPosition) == "function" then
  local ok
  ok, x, y, z = pcall(commands.getBlockPosition)
  if not ok or x == nil or y == nil or z == nil then
    fail("Unable to read this Command Computer's position.")
    return
  end
  source = "auto"
  if type(commands.getDimension) == "function" then
    local dimOk, dim = pcall(commands.getDimension)
    if dimOk and dim then dimension = tostring(dim) end
  end
  saveConfig({ x = x, y = y, z = z, source = source, dimension = dimension })

else
  local saved = loadConfig()
  if saved then
    x, y, z = saved.x, saved.y, saved.z
    source = "saved"
  else
    setColor(colors.yellow)
    print("NORMAL COMPUTER SETUP")
    setColor(colors.white)
    print("This computer cannot discover its own absolute coordinates.")
    print("Press F3, look directly at this computer, and use the")
    print("Targeted Block coordinates shown on the debug screen.")
    print("")
    x = readNumber("X: ")
    y = readNumber("Y: ")
    z = readNumber("Z: ")
    source = "manual"
    if not saveConfig({ x = x, y = y, z = z, source = source }) then
      fail("Could not save " .. CONFIG)
      return
    end
    print("")
    setColor(colors.lime)
    print("Coordinates saved. Future reboots will use them automatically.")
    setColor(colors.white)
  end
end

print("")
setColor(colors.lime)
if source == "auto" then
  print("AUTO POSITION FOUND")
elseif source == "saved" then
  print("SAVED GPS POSITION LOADED")
else
  print("GPS POSITION CONFIGURED")
end
setColor(colors.white)
print("Computer:  #" .. tostring(os.getComputerID()))
print("Modem:     " .. tostring(modemName))
if dimension ~= "unknown" then print("Dimension: " .. dimension) end
print(("Position:  X=%s Y=%s Z=%s"):format(tostring(x), tostring(y), tostring(z)))
print("Source:    " .. tostring(source))
print("")
print("Starting GPS host on channel " .. tostring(gps.CHANNEL_GPS or 65534) .. "...")
print("Leave this computer powered and its chunk loaded.")
print("")

-- The stock gps program opens the GPS channel and answers locate requests.
local started = shell.run("gps", "host", tostring(x), tostring(y), tostring(z))
if started == false then
  fail("The gps host program exited unexpectedly.")
end
