local D=dofile('Powerplant/distributed/discovery.lua')
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local devices={wired={isWireless=function() return false end},ender={isWireless=function() return true end},gauge={}}
peripheral={getNames=function() return {'gauge','ender','wired'} end,wrap=function(name) return devices[name] end}
local opened,closed,advertised
rednet={close=function() closed=true end,open=function(name) opened=name end,
 host=function(protocol,name) advertised=name end,lookup=function() return 42 end}
local wired,wireless=D.modems()
check(#wired==1 and wired[1]=='wired' and wireless[1]=='ender','modem classification')
check(not pcall(D.open,'ender'),'ender accepted for local cluster')
D.open('wired'); check(closed and opened=='wired','rednet not confined to wired modem')
D.host('station-1','master'); check(advertised=='station-1:master','cluster advertisement')
check(D.find('station-1','master')==42,'master discovery')
rednet.lookup=function() return 42,43 end
check(not pcall(D.find,'station-1','master'),'duplicate role accepted')
check(not pcall(D.host,'bad cluster','master'),'invalid cluster accepted')
print(('PASS: %d wired discovery checks'):format(n))
