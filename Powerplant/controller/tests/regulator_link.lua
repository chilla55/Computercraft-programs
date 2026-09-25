-- Reuse deterministic peripherals, but execute the actual regulator receiver.
local f=assert(io.open('Powerplant/regulator/tests/config_banks.lua')); local tests=f:read('*a'); f:close()
local prefix=tests:sub(1,assert(tests:find('local config={',1,true))-1)
local fixture=assert(load(prefix..'\nreturn fixture','regulator-fixture','t',_G))()
local Core=dofile('Powerplant/controller/controller_core.lua')
for _,mode in ipairs({'current','temperature'}) do
  local st,loadController,devices=fixture({version=15,masterId=9,protectionMode=mode,
    variacsA={'powergrid:variac_1','extra_variac'},variacsB={'powergrid:variac_2'},variacsC={'powergrid:variac_4'}})
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=130} end
  local regulator=loadController(true); regulator.initialise(); local net,session=regulator.network()
  local main=Core.new({version=1,monitor='m',modem='back',voltageGauge='grid',currentGauge='',
    nominalVoltage=2640,gridMinVoltage=2376,gridMaxVoltage=2904,currentLimitAmps=0,
    sampleMaxAgeMs=1000,nodeTimeoutMs=2000,upstreamId=-1,generators={},transformers={{id=3,name='Actual regulator'}},
    transmission={inputGauge='',outputGauge='',ratio=0}},9,'master-session',function(id,m,protocol)
      assert(id==3 and protocol==Core.REGULATOR); st.inbox[#st.inbox+1]=m; return true
    end)
  local function report()
    local m=regulator.statusMessage(); m.schema=1; m.node=3; m.session=session; m.sentAt=st.time*1000
    assert(main.receive(3,m,Core.REGULATOR,st.time*1000),'actual status rejected')
  end
  st.onSend=function(m) main.receive(3,m,Core.REGULATOR,st.time*1000) end
  st.onSleep=function() error('end receive batch',0) end
  main.measure(2640,nil,0); report()
  assert(main.action(3,'enable',0)); main.tick(0); pcall(regulator.receiver)
  assert(net.enabled and net.grid.voltage==2640 and net.lastSeq>=0,'regulator rejected real enable envelope')
  local ok,reason=pcall(regulator.guard); assert(ok,reason)
  assert(main.action(3,'reset',st.time*1000)); pcall(regulator.receiver)
  assert(not net.enabled,'reset did not disable regulator first')
  report(); main.measure(2640,nil,st.time*1000); main.tick(st.time*1000); pcall(regulator.receiver)
  local state=main.snapshot(st.time*1000).transformers[1]
  if mode=='temperature' then
    assert(not net.reset and not state.resetPending and state.notice:find('cool'),'real thermal reset rejection lost')
  else
    assert(net.reset and state.resetPending,'reset acceptance confused with completed standby')
  end
  assert(not st.closed[1] and not st.closed[2],'protocol test unexpectedly closed contacts')
end
print('PASS: actual regulator enable/disable/reset handler and native thermal reset rejection')
-- Temporary targets are checked by the real regulator, then ramped in its run loop.
do
 local st,loadController=fixture({version=16,masterId=9,protectionMode='current',remoteTargetPercent=2})
 st.concurrent=true
 local seq=0; local prepared=false; local reached=false; local returned=false; local nominal
 st.onSend=function(m)
  if m.type=='status' then
   if m.phase=='live' and m.joinStage=='nominal' and not prepared then prepared=true end
   if prepared and m.currentTarget and math.abs(m.currentTarget-2638)<.001 then reached=true end
   if reached and m.currentTarget and math.abs(m.currentTarget-2640)<.001 then returned=true end
   nominal=m.configuredTarget
   seq=seq+1
   st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=seq,sentAt=st.time*1000,
     enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000},
     transition=prepared and not reached and {id='shutdown-test',generator=12,targetVolts=2638,expiresAt=st.time*1000+10000} or nil}
  end
 end
 st.onSleep=function() if returned then error('Stopped by user',0) end end
 loadController(false)
 assert(prepared and reached and returned and nominal==2640,'temporary target failed to ramp/return without changing nominal')
end
for _,mode in ipairs({'parallel','supply'}) do
 local st,loadController=fixture({version=16,masterId=9,protectionMode='current',connectionMode=mode})
 st.concurrent=true; local seq=0; local live=false
 st.onSend=function(m)
  if m.type=='status' then
   if m.phase=='live' then live=true end
   seq=seq+1
   st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=seq,sentAt=st.time*1000,
     enabled=true,grid={voltage=st.closed[1] and st.closed[2] and 2640 or 0,healthy=true,sampledAt=st.time*1000}}
  end
 end
 st.onSleep=function() if live or (mode=='parallel' and st.time>3) then error('Stopped by user',0) end end
 loadController(false)
 assert(mode=='supply' and live or mode=='parallel' and not live and #st.moves==0,'dead-start mode gating failed')
end
print('PASS: real regulator temporary-target ramp/return and explicit dead-start versus parallel joining')
-- Local opt-in and expiry bounds cannot be bypassed by the master.
for _,limit in ipairs({0,1}) do
 local st,loadController=fixture({version=16,masterId=9,protectionMode='current',remoteTargetPercent=limit})
 local api=loadController(true); api.initialise(); local net,session=api.network()
 st.onSleep=function() error('end receive batch',0) end
 local function dispatch(seq,target,expiry)
  st.inbox={{schema=1,type='dispatch',node=3,session=session,seq=seq,sentAt=st.time*1000,enabled=true,
   grid={voltage=2640,healthy=true,sampledAt=st.time*1000},
   transition={id='test',generator=12,targetVolts=target,expiresAt=expiry}}}
  pcall(api.receiver); return st.sent[#st.sent].accepted
 end
 assert(not dispatch(1,3000,10000),'out-of-range target accepted')
 assert(not dispatch(2,2645,st.time*1000),'expired target accepted')
 assert(dispatch(3,2645,st.time*1000+10000)==(limit>0),'local modulation opt-in ignored')
end
-- A supply gauge that remains dead after closure causes isolation rather than indefinite supply-mode exemption.
do
 local st,loadController=fixture({version=16,masterId=9,protectionMode='current',connectionMode='supply'})
 st.concurrent=true; local seq=0; local tripped=false
 st.onSend=function(m)
  if m.type=='status' then
   seq=seq+1; st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=seq,sentAt=st.time*1000,
    enabled=true,grid={voltage=0,healthy=true,sampledAt=st.time*1000}}
  elseif m.type=='fault' and tostring(m.reason):find('Supply bus remained dead',1,true) then tripped=true end
 end
 st.onSleep=function() if tripped then error('Stopped by user',0) end end
 loadController(false)
 assert(tripped and not st.closed[1] and not st.closed[2],'persistent dead supply bus failed to trip')
end
print('PASS: temporary-target limits/expiry and persistent dead-bus trip')
