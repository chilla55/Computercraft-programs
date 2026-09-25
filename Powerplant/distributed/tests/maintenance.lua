-- Exercise the queued UI maintenance worker and its bounded persistent log.
local Common=dofile('Powerplant/distributed/common.lua')
local tasks,writes={},{}
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local s={inputGauge='',outputGauge='',sourceGauge='',preStepUpGauge='',sourceCurrentGauge='',sourcePowerGauge='',inputBreakers={},plusBreaker='',minusBreaker='',variacsA={},variacsB={},variacsC={},thermalMaxAgeSeconds=1}
local U=setmetatable({editable={},roles={},read=function() end,write=function(p,v) writes[p]=Common.copy(v) end,
 isolated=function() return true end,idle=function() return true end,
 device=function() return {getStatus=function() return {closed=false} end} end,
 stationaryBanks=function() error('Test alignment read failed') end},{__index=Common})
local screen={getSize=function() return 57,29 end}
local peer={latched=true,temperatures={}}
local R={U=U,role='master',node={},config={settings=s},state={},events={},now=function() return 1000 end,
 fresh=function() return peer end,updatePeer=function() end,trip=function() error('Read-only maintenance unexpectedly tripped') end,
 modules={ui={new=function() return {draw=function() end,animating=function() return false end,
 event=function(event,test) if event=='test' then return {kind='maintenance_test',test=test} end end} end}}}
local env=setmetatable({term=screen,colors={},peripheral={},os={pullEvent=function() return coroutine.yield() end,queueEvent=function() end},
 sleep=function() coroutine.yield() end,
 parallel={waitForAny=function(...) for _,fn in ipairs({...}) do tasks[#tasks+1]=coroutine.create(fn) end end}},{__index=_G})
assert(loadfile('Powerplant/distributed/interface.lua','t',env))().run(R)
assert(coroutine.resume(tasks[3])); assert(coroutine.resume(tasks[1]))
for i=1,10 do
 assert(coroutine.resume(tasks[1],'test','gauges'))
 check(R.maintenanceBusy,'test was not queued')
 assert(coroutine.resume(tasks[4]))
 check(not R.maintenanceBusy,'completed test remained busy')
end
local log=writes['/config/maintenance-log.json']
check(log and #log.entries==8,'maintenance log was not bounded to eight reports')
check(log.entries[8].ok and log.entries[8].report.voltages,'gauge result was not logged')
assert(coroutine.resume(tasks[1],'test','alignment')); assert(coroutine.resume(tasks[4]))
log=writes['/config/maintenance-log.json']
check(not log.entries[8].ok and log.entries[8].reason:find('Test alignment read failed',1,true),'failed test was not logged')
print(('PASS: %d maintenance queue/log checks'):format(count))
