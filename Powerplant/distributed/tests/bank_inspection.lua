local checks=0
local function check(v,m) assert(v,m); checks=checks+1 end
local function run(closed,missing)
 local report,reads=nil,0
 local settings={inputBreakers={'input'},plusBreaker='plus',minusBreaker='minus',gearA='ga',gearB='gb',gearC='gc',variacsC={'c1','c2'}}
 local env=setmetatable({},{__index=_G})
 env.os={epoch=function() reads=reads+1; return reads end}
 env.sleep=function() end; env.print=function() end
 env.textutils={unserializeJSON=function() return {role='master',config={settings=settings}} end,serializeJSON=function(v) report=v; return 'report' end}
 env.fs={open=function(path,mode) return {readAll=function() return 'config' end,write=function() end,close=function() end} end}
 env.peripheral={getMethods=function() return {'getStatus','getThermalStatus'} end,wrap=function(name)
  if name==missing then return nil end
  return {isClosed=function() return closed and name=='input' or false end,isRunning=function() return false end,
   getStatus=function() return {position=.9,ratio=.901,shaftSpeed=0} end,
   getThermalStatus=function() return {available=true,unit='C',temperature=20} end,
   close=function() error('diagnostic closed a breaker') end,open=function() error('diagnostic changed a breaker') end,rotate=function() error('diagnostic moved a bank') end}
 end}
 assert(loadfile('Powerplant/distributed/tools/inspect-variac-bank.lua','t',env))('C')
 return report
end
local r=run(false)
check(r.completed and not r.atomic and not r.movementTest,'inspection claimed atomic/moving test')
check(#r.members==2 and #r.members[2].samples==3,'member samples missing')
check(r.members[1].samples[1].status.value.position==.9,'status not recorded')
check(r.members[1].samples[1].thermal.value.temperature==20,'temperature not recorded')
r=run(true)
check(not r.completed and #r.members==0,'inspection ran with closed source breaker')
r=run(false,'c1')
check(r.completed and not r.members[1].samples[1].status.ok,'missing member not captured')
check(r.members[2].samples[3].status.ok,'missing member skipped healthy follower')
r=run(false,'input')
check(not r.completed,'unknown input contact passed isolation')
print(('PASS: %d read-only bank inspection checks'):format(checks))
