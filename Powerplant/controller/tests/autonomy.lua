local f=assert(io.open('Powerplant/regulator/tests/config_banks.lua')); local text=f:read('*a'); f:close()
local prefix=text:sub(1,assert(text:find('local config={',1,true))-1)
local fixture=assert(load(prefix..'\nreturn fixture','fixture','t',_G))()
local Core=dofile('Powerplant/controller/controller_core.lua')
local checks=0
local function check(v,m) assert(v,m); checks=checks+1 end
local function regulatorConfig() return {version=17,masterId=9,autonomousFallback=true,protectionMode='current',remoteTargetPercent=2} end
-- Run actual regulation, with no main controller connected at all.
do
 local st,load=fixture(regulatorConfig()); st.concurrent=true; local live=false
 st.onSend=function(m) if m.type=='status' and m.phase=='live' then
   live=m.controlMode=='single' and m.enabled and st.closed[1] and st.closed[2]
 end end
 st.onSleep=function() if live then error('Stopped by user',0) end end
 load(false); check(live,'no-supervisor startup failed')
end
-- Lose supervision during a temporary generator adjustment: stay connected and ramp to nominal.
do
 local st,load=fixture(regulatorConfig()); st.concurrent=true
 local seq=0; local armed=false; local shifted=false; local returned=false; local lastTarget; local fallbackSamples=0
 st.onSend=function(m)
  if m.type~='status' then return end
  if m.phase=='live' and m.currentTarget and math.abs(m.currentTarget-2638)<.001 then shifted=true end
  if shifted then
   check(st.closed[1] and st.closed[2],'communication loss opened contacts')
   if m.controlMode=='single' then
    fallbackSamples=fallbackSamples+1
    if lastTarget then check(math.abs(m.currentTarget-lastTarget)<=1.01,'return to nominal jumped the setpoint') end
    lastTarget=m.currentTarget
    returned=math.abs(m.currentTarget-2640)<.001
   end
   return -- Drop every subsequent main-controller heartbeat.
  end
  if m.phase=='live' then armed=true end
  seq=seq+1
  st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=seq,sentAt=st.time*1000,enabled=true,
    grid={voltage=2640,healthy=true,sampledAt=st.time*1000},
    transition=armed and {id='connect-gen',generator=12,targetVolts=2638,expiresAt=st.time*1000+10000} or nil}
 end
 st.onSleep=function() if returned then error('Stopped by user',0) end end
 load(false)
 check(shifted and returned and fallbackSamples>0,'lost supervisor did not revert optional target to nominal')
end
-- Explicit disable persists through timeout, release and a reboot, and can be cleared locally.
do
 local c=regulatorConfig(); local st,load=fixture(c); local api=load(true); api.initialise(); local net,session=api.network()
 st.onSleep=function() error('batch complete',0) end
 local function send(m)
  m.schema=1; m.node=3; m.session=session; m.sentAt=st.time*1000; st.inbox={m}; pcall(api.receiver)
 end
 send({type='dispatch',enabled=false,seq=1}); st.time=10
 check(not pcall(api.guard) and not api.statusMessage().enabled,'disable expired into autonomous enable')
 send({type='release',seq=2}); check(not api.statusMessage().enabled,'release cancelled explicit disable')
 local reboot,reload=fixture(regulatorConfig(),st.files); reboot.time=20
 local nextApi=reload(true); nextApi.initialise()
 check(not pcall(nextApi.guard) and not nextApi.statusMessage().enabled,'reboot cleared disable')
 reload(false,'enable')
 local enabled=reload(true); enabled.initialise(); check(pcall(enabled.guard) and enabled.statusMessage().enabled,'local enable command failed')
end
-- Local thermal protection remains authoritative without any supervisor.
do
 local c=regulatorConfig(); c.protectionMode='temperature'; local st,load,devices=fixture(c)
 devices['powergrid:variac_2'].getThermalStatus=function() return {available=true,unit='C',temperature=140} end
 local api=load(true)
 check(not pcall(api.initialise) and api.context().code=='thermal_overtemperature' and not st.closed[1] and not st.closed[2],'autonomy bypassed thermal protection')
end
-- Supervisor startup, stale readings, restart and exit do not stop autonomous units.
do
 local c={version=2,monitor='m',modem='back',voltageGauge='v',currentGauge='',nominalVoltage=2640,gridMinVoltage=2376,gridMaxVoltage=2904,
   currentLimitAmps=0,sampleMaxAgeMs=1000,nodeTimeoutMs=2000,upstreamId=-1,transformers={{id=3,name='Regulator'}},generators={},
   transmission={inputGauge='',outputGauge='',ratio=0}}
 local sent={}; local main=Core.new(c,9,'main',function(_,m) sent[#sent+1]=m; return true end)
 local function report(time,session,enabled)
  return main.receive(3,{schema=1,type='status',node=3,session=session,sentAt=time,lastSeq=20,phase='live',enabled=enabled,
    autonomousFallback=true,nominalTarget=2640,breakers={{closed=true},{closed=true}}},Core.REGULATOR,time)
 end
 check(report(0,'unit',true),'autonomous status rejected'); main.tick(0)
 check(#sent==0 and main.snapshot(0).transformers[1].desired,'supervisor boot sent unsolicited disable')
 main.tick(3000); check(#sent==0,'offline regulator received shutdown intent')
 main.release(3001); check(sent[#sent].type=='release','supervisor exit disabled autonomous unit')
 report(4000,'unit',true); main.measure(2640,nil,4000); main.action(3,'enable',4000); main.tick(4000)
 check(sent[#sent].enabled,'supervision could not resume')
 main.tick(5500); check(sent[#sent].type=='release','missing grid failed to release supervision')
 main.action(3,'disable',5600); report(6000,'new-unit',true); main.tick(6000)
 check(sent[#sent].enabled==false,'pending explicit disable lost on regulator reboot')
end
print(('PASS: %d independent-regulation checks'):format(checks))
