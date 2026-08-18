-- CCNexus Automatic GPS Host
--
-- Run this on a CC:Tweaked Command Computer with a Wireless or Ender Modem.
-- Command Computers can read their own Minecraft block position, allowing the
-- GPS host coordinates to be configured automatically instead of typed by hand.

local function fail(message)
  if term.isColor and term.isColor() then term.setTextColor(colors.red) end
  print("ERROR: " .. tostring(message))
  if term.isColor and term.isColor() then term.setTextColor(colors.white) end
  return false
end

term.clear()
term.setCursorPos(1, 1)
print("CCNexus Auto GPS Host")
print("=====================")
print("")

if type(commands) ~= "table" or type(commands.getBlockPosition) ~= "function" then
  fail("This must run on a Command Computer.")
  print("A normal Computer cannot discover its absolute Minecraft coordinates before GPS is already available.")
  return
end

local wirelessModem
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then
    local modem = peripheral.wrap(name)
    local ok, wireless = pcall(function() return modem.isWireless() end)
    if ok and wireless then
      wirelessModem = { name = name, modem = modem }
      break
    end
  end
end

if not wirelessModem then
  fail("No Wireless or Ender Modem is attached.")
  print("Attach a Wireless Modem or Ender Modem and reboot this computer.")
  return
end

local ok, x, y, z = pcall(commands.getBlockPosition)
if not ok or x == nil or y == nil or z == nil then
  fail("Unable to read this Command Computer's position.")
  return
end

local dimension = "unknown"
if type(commands.getDimension) == "function" then
  local dimOk, dim = pcall(commands.getDimension)
  if dimOk and dim then dimension = tostring(dim) end
end

if term.isColor and term.isColor() then term.setTextColor(colors.lime) end
print("AUTO POSITION FOUND")
if term.isColor and term.isColor() then term.setTextColor(colors.white) end
print("Computer:  #" .. tostring(os.getComputerID()))
print("Modem:     " .. tostring(wirelessModem.name))
print("Dimension: " .. dimension)
print(("Position:  X=%s Y=%s Z=%s"):format(tostring(x), tostring(y), tostring(z)))
print("")
print("Starting GPS host on channel " .. tostring(gps.CHANNEL_GPS or 65534) .. "...")
print("Leave this computer powered and its chunk loaded.")
print("")

-- The stock gps program handles incoming GPS requests and broadcasts this
-- computer's automatically discovered Minecraft block coordinates.
local started = shell.run("gps", "host", tostring(x), tostring(y), tostring(z))
if started == false then
  fail("The gps host program exited unexpectedly.")
end
