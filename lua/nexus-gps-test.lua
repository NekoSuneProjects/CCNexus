-- CCNexus Nexus GPS Test
-- Public-server friendly GPS test for a normal computer or turtle.
-- Requires a Wireless/Ender Modem and four running GPS hosts.

local function setColor(color)
  if term.isColor and term.isColor() then term.setTextColor(color) end
end

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local modem = peripheral.wrap(name)
    if modem and type(modem.isWireless) == 'function' then
      local ok, wireless = pcall(modem.isWireless)
      if ok and wireless then return name end
    end
  end
  return nil
end

term.clear()
term.setCursorPos(1, 1)
setColor(colors.cyan)
print('CCNexus Nexus GPS Test')
print('======================')
setColor(colors.white)
print('')

local modemName = findWirelessModem()
if not modemName then
  setColor(colors.red)
  print('NO WIRELESS MODEM')
  setColor(colors.white)
  print('Attach a Wireless or Ender Modem and try again.')
  return
end

print('Modem: ' .. tostring(modemName))
print('Searching for GPS constellation...')
print('')

-- Current CC:Tweaked default GPS timeout is 2 seconds.
local x, y, z = gps.locate(2, true)
if not x then
  setColor(colors.red)
  print('NO GPS FIX')
  setColor(colors.white)
  print('Check that all four A/B/C/D hosts are running,')
  print('their modems are wireless, and their physical')
  print('positions match the preset spacing exactly.')
  return
end

setColor(colors.lime)
print('GPS FIX OK')
setColor(colors.white)
print(('Nexus X: %.3f'):format(x))
print(('Nexus Y: %.3f'):format(y))
print(('Nexus Z: %.3f'):format(z))
print('')
print('These are CCNexus-relative coordinates, not')
print('Minecraft F3 world coordinates.')
