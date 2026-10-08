-- CCNexus Flat GPS telemetry adapter
-- Marks Fleet telemetry fixes produced by the Flat GPS shim as nexus_flat_gps.

if _G.CCNEXUS_FLAT_TELEMETRY_WRAPPED then return true end
_G.CCNEXUS_FLAT_TELEMETRY_WRAPPED=true

local native=textutils.serializeJSON
textutils.serializeJSON=function(value,...)
  if type(value)=='table' and value.type=='telemetry' and type(value.telemetry)=='table' then
    local st=_G.CCNEXUS_FLAT_GPS_LAST
    if type(st)=='table' and st.ok then
      local t=value.telemetry
      if type(t.position)=='table' and t.position.source=='gps' then
        t.position.source='nexus_flat_gps'
        t.position.flatGps={quarry=st.quarry,width=st.width,length=st.length,rms=st.rms,diagonalVerified=st.diagonalVerified}
      end
      if type(t.nav)=='table' and t.nav.source=='gps' then t.nav.source='nexus_flat_gps' end
      t.flatGps={ok=true,quarry=st.quarry,width=st.width,length=st.length,rms=st.rms,diagonalVerified=st.diagonalVerified}
    end
  end
  return native(value,...)
end
return true
