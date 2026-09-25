-- Three isolated Lua environments, shared physical peripherals, rednet queues,
-- CC-style event filtering and yielding native calls. No real Minecraft I/O.
local base='Powerplant/distributed/'
local U=dofile(base..'common.lua')
local checks=0
local function check(v,why) assert(v,why); checks=checks+1 end
local settings={target=2640,stepUp=2.5,entryRatio=5,travelDegrees=315,maxInputVolts=2800,accuracyVolts=.1,fallbackVolts=1,
  moveTimeout=30,chargeTimeout=60,positionToleranceDegrees=1,thermalMaxAgeSeconds=1,thermalGraceSeconds=5,thermalCoolSeconds=5,
  rampVoltsPerSecond=1,maxRampStepVolts=1,outputTripPercent=10,inputBreakers={'input'},plusBreaker='plus',minusBreaker='minus',
  inputGauge='vin',outputGauge='vout',sourceGauge='',preStepUpGauge='',sourceCurrentGauge='',sourcePowerGauge='',sourceCurrentTripAmps=0,
  variacsA={'a1','a2'},variacsB={'b1'},variacsC={'c1'},gearA='ga',gearB='gb',gearC='gc',pollSeconds=.1,settleSeconds=.2}
local cfg={schema=1,revision=1,ids={master=1,regulation=2,protection=3},settings=settings}
local function world(restore,thermalFault,options)
  options=options or {}
  local cfg=U.copy(cfg); local settings=cfg.settings
  if options.multiInput then settings.inputBreakers={'input','input2'} end
  if options.ignoreSmallMoves then settings.positionToleranceDegrees=2 end
  local W={time=0,nodes={},contacts={input=false,plus=false,minus=false},positions={a1=.8,a2=.5,b1=.9,c1=.98},temperature={},motion={},moves={},closes={},drop={}}
  if options.multiInput then W.contacts.input2=false end
  if options.lowStart then for name in pairs(W.positions) do W.positions[name]=.05 end end
  local function powered() for _,name in ipairs(settings.inputBreakers) do if not W.contacts[name] then return false end end; return true end
  local function serialize(v)
    if type(v)=='string' then return string.format('%q',v) end
    if type(v)~='table' then return tostring(v) end
    local parts={'{'}; for k,x in pairs(v) do parts[#parts+1]='['..serialize(k)..']='..serialize(x)..',' end; parts[#parts+1]='}'; return table.concat(parts)
  end
  for _,role in ipairs(U.roles) do
    local N={id=cfg.ids[role],role=role,queue={},timers={},files={},timer=0}; W.nodes[N.id]=N
    if restore then N.files['/config/distributed-state.json']=serialize(restore[role] or {events={},latched=true,runRequested=false}) end
    if options.cachedPreset and role=='regulation' then N.files['/config/distributed-startup.json']=options.cachedPreset end
    if thermalFault and role=='protection' then N.files['/config/distributed-thermal.json']=serialize({version=2,members={},fault={code='thermal_overtemperature',reason='Saved thermal trip'}}) end
    local env=setmetatable({}, {__index=_G}); env._G=env
    env.os={epoch=function() return W.time*1000 end,clock=function() return W.time end,getComputerID=function() return N.id end,
      startTimer=function(seconds) N.timer=N.timer+1; N.timers[N.timer]=W.time+seconds; return N.timer end,
      queueEvent=function(...) N.queue[#N.queue+1]={...} end,
      pullEvent=function(filter) return coroutine.yield(filter) end,
      reboot=function() error('REBOOT',0) end}
    env.sleep=function(seconds) local id=env.os.startTimer(seconds); repeat local _,v=env.os.pullEvent('timer') until v==id end
    env.parallel={waitForAny=function(...)
      local workers,filters={},{}
      for i,fn in ipairs({...}) do workers[i]=coroutine.create(fn) end
      local event={}
      while true do
        for i,co in ipairs(workers) do
          if not filters[i] or filters[i]==event[1] or event[1]=='terminate' then
            local ok,filter=coroutine.resume(co,table.unpack(event)); if not ok then error(filter,0) end
            if coroutine.status(co)=='dead' then return end; filters[i]=filter
          end
        end
        event={env.os.pullEvent()}
      end
    end}
    env.textutils={serializeJSON=serialize,unserializeJSON=function(s) local f=load('return '..s,'json','t',{}); return f and f() end}
    env.fs={makeDir=function(path) N.files[path]=true end,exists=function(path) return N.files[path]~=nil end,getDir=function(p) return p:match('^(.*)/') or '' end,combine=function(a,b) return a=='' and b or a..'/'..b end,
      delete=function(path) N.files[path]=nil end,move=function(a,b) N.files[b]=assert(N.files[a]); N.files[a]=nil end,
      open=function(path,mode) local value='' return {readAll=function() return assert(N.files[path]) end,write=function(s) value=value..s end,close=function() if mode~='r' then N.files[path]=value end end} end}
    env.rednet={isOpen=function() return true end,open=function() end,
      send=function(id,m,protocol)
        if not W.drop[N.role] and not W.drop[W.nodes[id].role] and not (W.dropHeartbeat and m.kind=='heartbeat' and N.role=='regulation') then W.nodes[id].queue[#W.nodes[id].queue+1]={'rednet_message',N.id,U.copy(m),protocol} end
        return true
      end,
      receive=function(protocol,timeout)
        local timer=env.os.startTimer(timeout)
        while true do local e={env.os.pullEvent()}; if e[1]=='rednet_message' and e[4]==protocol then return e[2],e[3],e[4] end; if e[1]=='timer' and e[2]==timer then return nil end end
      end}
    local function native() env.sleep(options.nativeDelay or .001) end
    local devices={back={isWireless=function() return true end}}
    for name in pairs(W.contacts) do
      devices[name]={isClosed=function() native(); return W.contacts[name] end,
        open=function() native(); W.contacts[name]=false end,
        close=function() native(); if options.closeDelay then env.sleep(options.closeDelay) end; W.closes[#W.closes+1]={role=N.role,name=name}; check(N.role=='protection','non-protection closed a breaker'); if options.failClose~=name then W.contacts[name]=true end end,
        getStatus=function() native(); return {closed=W.contacts[name],canClose=true,currentValid=true,current=1,tripEnabled=true,tripCurrent=50} end}
    end
    for name in pairs(W.positions) do devices[name]={
      getStatus=function() native(); return {position=W.positions[name],ratio=.01+.99*W.positions[name],shaftSpeed=W.motion[name] and 32 or 0} end,
      getThermalStatus=function() native(); return {available=true,unit='C',temperature=W.temperature[name] or 100} end} end
    for i,key in ipairs({'A','B','C'}) do devices[settings['gear'..key]]={isRunning=function() native(); return false end,
      rotate=function(degrees,direction)
        native(); W.moves[#W.moves+1]={phase=N.R.state.phase,stage=i,at=W.time,degrees=degrees,isolated=not W.contacts.input and not W.contacts.plus and not W.contacts.minus}
        for name in pairs(W.motion) do
          assert(N.R.state.phase=='positioning' and not W.contacts.plus and not W.contacts.minus,'New movement before shaft stopped: '..name)
          W.concurrentStartup=true
        end
        if N.R.state.startupPlan then W.maxStartupAttempt=math.max(W.maxStartupAttempt or 0,N.R.state.startupPlan.attempt) end
        for _,name in ipairs(settings['variacs'..key]) do
          if name~=W.jammed and not (options.ignoreSmallMoves and N.R.state.phase=='fine_tuning' and degrees<=2) then W.motion[name]={from=W.positions[name],to=math.max(0,math.min(1,W.positions[name]+degrees*direction/315)),start=W.time,finish=W.time+(N.R.state.phase=='positioning' and options.startupMoveTime or .15)} end
        end
      end} end
    devices.vin={voltage=function()
      native()
      if W.openOnInputRead and role=='protection' then
        W.openOnInputRead=false; W.contacts.input=false
      end
      return powered() and (W.inputVoltage or 1500) or 0
    end}
    devices.vout={voltage=function() native(); local value=powered() and 3750*(options.voltageScale or 1)*(W.loadScale or 1) or 0; for _,name in ipairs({'a1','b1','c1'}) do value=value*(.00999996389330349+.989990071137444*W.positions[name]) end; if options.transientInBand and role=='regulation' and N.R.state.phase=='tuning' and W.maxStartupAttempt==1 and not W.transientUsed then W.transientUsed=true; return settings.target end; if options.oscillating then value=value*((W.maxStartupAttempt or 0)%2==0 and .97 or 1.03) end; return options.voltageExponent and 3750*(value/3750)^options.voltageExponent or value end}
    env.peripheral={wrap=function(name) return devices[name] end}; env.print=function() end
    local function mod(name) return assert(loadfile(base..name..'.lua','t',env))() end
    local modules={common=mod('common'),thermal=mod('thermal_protection'),planner=mod('planner'),hash=mod('sha256'),updater=mod('updater')}
    N.R=mod('runtime').new(U.copy(cfg),{role=role,modem='back'},modules,'')
    local worker=role~='master' and mod(role).new(N.R)
    N.co=coroutine.create(function() env.parallel.waitForAny(N.R.receive,N.R.heartbeat,N.R.watchdog,function() if worker then worker.run() else while true do env.sleep(1) end end end) end)
    N.env=env; N.devices=devices
  end
  function W.step()
    W.time=W.time+.001
    for name,motion in pairs(W.motion) do
      if W.time>=motion.finish then W.positions[name]=motion.to; W.motion[name]=nil
      else W.positions[name]=motion.from+(motion.to-motion.from)*(W.time-motion.start)/(motion.finish-motion.start) end
    end
    for _,N in ipairs(W.nodes) do
      if not N.started then N.started=true; local ok,e=coroutine.resume(N.co); assert(ok,e); N.filter=e end
      for id,deadline in pairs(N.timers) do if deadline<=W.time then N.timers[id]=nil; N.queue[#N.queue+1]={'timer',id} end end
      local e=table.remove(N.queue,1)
      if e and (not N.filter or N.filter==e[1]) then local ok,f=coroutine.resume(N.co,table.unpack(e)); assert(ok,f); N.filter=f end
    end
  end
  function W.untilTrue(predicate,timeout)
    local finish=W.time+timeout
    repeat W.step(); if predicate() then return true end until W.time>=finish
    return false
  end
  function W.command(kind,data)
    -- send is non-yielding in the mock, matching rednet's API return behavior.
    W.nodes[1].R.send('protection',kind,data or {})
  end
  return W
end
local W=world()
check(W.untilTrue(function() return W.nodes[3].R.fresh('regulation')~=nil end,3),'discovery failed')
W.command('start')
local live=W.untilTrue(function() return W.nodes[2].R.state.phase=='live' end,150)
if not live then
  for _,N in ipairs(W.nodes) do print(N.role,N.R.state.phase,N.R.state.message); for _,e in ipairs(N.R.events) do print(e.code,e.reason) end end
end
check(live,'did not reach live operation')
check(W.contacts.input and W.contacts.plus and W.contacts.minus,'missing closed contacts')
local homed=false; for _,m in ipairs(W.moves) do if m.degrees==318 then homed=true; check(m.isolated,'homing energized') end end
check(homed,'mismatched bank did not home')
W.command('start'); W.command('target',{target=0})
W.untilTrue(function() return false end,.5)
check(W.contacts.input and W.contacts.plus and W.contacts.minus,'repeat start or rejected target tripped an operating unit')
-- Losing only the UI does not interrupt autonomous worker cooperation.
W.drop.master=true
W.untilTrue(function() return false end,3)
check(W.contacts.input and W.contacts.plus and W.contacts.minus,'UI loss tripped workers')
-- A hot follower trips without requiring master communication.
W.temperature.a2=140
check(W.untilTrue(function() return not W.contacts.input and not W.contacts.plus and not W.contacts.minus end,2),'thermal trip failed')
check(W.nodes[3].R.state.latched,'thermal latch absent')
W.untilTrue(function() return false end,.1)
local found=false; for _,e in ipairs(W.nodes[3].R.events) do if e.code=='thermal_overtemperature' and e.detail.member=='a2' then found=true end end
check(found,'thermal member reason missing')
W.drop.master=nil; W.temperature.a2=100
W.untilTrue(function() return false end,1)
W.command('start')
check(W.untilTrue(function() return W.nodes[2].R.state.phase=='live' end,150),'reset/start failed')
-- An unexplained physical opening gets an explicit unknown incident.
W.contacts.plus=false
check(W.untilTrue(function() return not W.contacts.input and not W.contacts.minus end,2),'unexpected opening did not isolate all')
W.untilTrue(function() return false end,.2)
found=false; for _,e in ipairs(W.nodes[3].R.events) do if e.code=='unknown_opening' then found=true end end
check(found,'unknown opening reason missing')
check(W.nodes[3].R.state.tripPending==true,'unexplained opening not marked awaiting cause')
W.untilTrue(function() return false end,2.2)
check(not W.nodes[3].R.state.tripPending and W.nodes[3].R.state.fault:find('Unknown breaker opening',1,true),'unexplained opening remained pending indefinitely')
W.untilTrue(function() return false end,1); W.command('start')
check(W.untilTrue(function() return W.nodes[2].R.state.phase=='live' end,150),'second restart failed')
W.dropHeartbeat=true -- hello packets alone must not renew regulation readiness.
check(W.untilTrue(function() return not W.contacts.input and not W.contacts.plus and not W.contacts.minus end,4),'worker loss failed to trip')
local ledger=W.nodes[1].R
ledger.record({id='observation',origin='regulation',code='unknown_opening',reason='Unknown',cycle='correlation',observedAt=500})
ledger.record({id='later',origin='protection',code='thermal_overtemperature',reason='Hot',cycle='correlation',commandedAt=600})
local function event(id) for _,e in ipairs(ledger.events) do if e.id==id then return e end end end
check(not event('observation').resolvedBy,'later trip falsely explained an earlier opening')
ledger.record({id='earlier',origin='master',code='emergency_stop',reason='Operator stop',cycle='correlation',commandedAt=400})
check(event('observation').resolvedBy=='earlier','delayed earlier command did not explain opening')
ledger.state.tripPending=true; ledger.state.tripEventId='observation'; ledger.tripPendingUntil=ledger.now()+2000
ledger.refreshTripReason()
check(not ledger.state.tripPending and ledger.state.fault=='master: Operator stop','delayed cause did not replace pending trip reason')
check(event('later') and event('earlier') and event('observation'),'multiple reasons lost during merge')
-- Boot from a persisted running state without a UI start command.
local previouslyRunning={regulation={events={},latched=false,runRequested=true},protection={events={},latched=false,runRequested=true}}
local resumed=world(previouslyRunning); resumed.drop.master=true
check(resumed.untilTrue(function() return resumed.nodes[2].R.state.phase=='live' end,150),'previously running workers failed automatic startup without UI')
check(resumed.contacts.input and resumed.contacts.plus and resumed.contacts.minus,'automatic startup did not connect')
resumed.positions.a2=resumed.positions.a1+0.000001
check(resumed.untilTrue(function() return not resumed.contacts.input and not resumed.contacts.plus and not resumed.contacts.minus end,2),'small live bank spread did not trip')
check(resumed.untilTrue(function() return resumed.nodes[2].R.state.phase=='live' and resumed.contacts.plus end,150),'misaligned bank did not automatically realign/reenter service')
check(resumed.positions.a1==resumed.positions.a2,'reconnected misaligned bank')
for _,move in ipairs(resumed.moves) do if move.degrees==318 then check(move.isolated,'automatic recovery homed while energized') end end
resumed.jammed='a2'; resumed.positions.a2=resumed.positions.a1+0.001
check(resumed.untilTrue(function() return resumed.nodes[2].R.state.phase=='tripped' and not resumed.nodes[2].R.state.realignRequested end,150),'jammed recovery did not latch a fault')
local movesAfterJam=#resumed.moves
resumed.untilTrue(function() return false end,3)
check(not resumed.contacts.input and not resumed.contacts.plus and not resumed.contacts.minus and #resumed.moves==movesAfterJam,'jammed recovery retried or reconnected')
local stopped=world({regulation={events={},latched=true,runRequested=false},protection={events={},latched=true,runRequested=false}})
stopped.untilTrue(function() return false end,3)
check(not stopped.contacts.input and #stopped.closes==0,'maintenance reboot reconnected')
local blocked=world(previouslyRunning,true)
blocked.untilTrue(function() return false end,3)
check(#blocked.closes==0 and not blocked.nodes[3].R.state.runRequested,'automatic startup cleared thermal fault')
check(W.nodes[3].R.state.runRequested==false,'trip did not clear restart intent')
local multiple=world(nil,nil,{multiInput=true,closeDelay=.4})
multiple.untilTrue(function() return multiple.nodes[3].R.fresh('regulation')~=nil end,3)
multiple.command('start')
local multiLive=multiple.untilTrue(function() return multiple.nodes[2].R.state.phase=='live' end,150)
if not multiLive then for _,node in ipairs(multiple.nodes) do for _,event in ipairs(node.R.events) do print(node.role,event.code,event.reason) end end end
check(multiLive and multiple.contacts.input2,'sequential input contacts interrupted startup')
local failed=world(nil,nil,{multiInput=true,closeDelay=.4,failClose='input2'})
failed.untilTrue(function() return failed.nodes[3].R.fresh('regulation')~=nil end,3)
failed.command('start')
check(failed.untilTrue(function() return failed.nodes[3].R.state.phase=='tripped' and not failed.contacts.input end,150),'failed second input did not trip/open first input')
check(not failed.contacts.plus and not failed.contacts.minus,'output closed despite failed input connection')
local direct=world(nil,nil,{lowStart=true,startupMoveTime=6,nativeDelay=.01})
direct.untilTrue(function() return direct.nodes[3].R.fresh('regulation')~=nil end,3); direct.command('start')
check(direct.untilTrue(function() return direct.nodes[2].R.state.phase=='live' end,60),'calculated simultaneous startup did not converge')
check(direct.concurrentStartup and direct.maxStartupAttempt==1,'startup did not issue one concurrent calculated plan')
local first,last
for _,move in ipairs(direct.moves) do if move.phase=='positioning' then first=first or move.at; last=move.at end end
check(first and last-first<1,'startup waited for one bank before starting the others')
local fullTravel=false; for _,move in ipairs(direct.moves) do if move.phase=='positioning' and move.degrees>16 then fullTravel=true end end
check(fullTravel,'startup split full travel into live-regulation steps')
local corrected=world(nil,nil,{lowStart=true,voltageScale=.95})
corrected.untilTrue(function() return corrected.nodes[3].R.fresh('regulation')~=nil end,3); corrected.command('start')
check(corrected.untilTrue(function() return corrected.nodes[2].R.state.phase=='live' end,60),'measured voltage correction failed')
check(corrected.maxStartupAttempt==2,'startup correction was not a bounded recalculation')
local fine=world(nil,nil,{lowStart=true,voltageScale=.999})
fine.untilTrue(function() return fine.nodes[3].R.fresh('regulation')~=nil end,3); fine.command('start')
check(fine.untilTrue(function() return fine.nodes[2].R.state.phase=='live' end,60),'coarse-to-live-feedback startup did not converge')
local sawFine=false
for _,sample in ipairs(fine.nodes[2].R.state.startupMeasurements) do
 if sample.mode=='fine' then sawFine=true; check(math.abs(sample.outputBefore-sample.target)<=10,'fine mode entered outside 10V band') end
end
check(sawFine,'startup did not switch to fine feedback inside 10V')
for _,move in ipairs(fine.moves) do if move.phase=='fine_tuning' then check(move.degrees<=16,'fine movement exceeded live algorithm limit') end end
local preset=fine.nodes[2].files['/config/distributed-startup.json']
check(type(preset)=='string','successful no-load startup did not save preset under /config')
local reused=world(nil,nil,{lowStart=true,voltageScale=.999,cachedPreset=preset})
reused.untilTrue(function() return reused.nodes[3].R.fresh('regulation')~=nil end,3); reused.command('start')
check(reused.untilTrue(function() return reused.nodes[2].R.state.phase=='live' end,60),'cached startup did not reach service')
check(reused.nodes[2].R.state.startupMeasurements[1].mode=='cached' and reused.maxStartupAttempt==1,'cached startup did not reuse learned bank positions')
fine.loadScale=.97
local function loadedError()
 local v=3750*.999*.97
 for _,name in ipairs({'a1','b1','c1'}) do v=v*(.00999996389330349+.989990071137444*fine.positions[name]) end
 return math.abs(v-2640)
end
check(fine.untilTrue(function() return loadedError()<=1 end,120),'small-step live feedback did not recover load sag')
check(fine.nodes[2].R.state.phase=='live','load correction tripped')
local liveMoves=0
for _,move in ipairs(fine.moves) do if move.phase=='live' then liveMoves=liveMoves+1; check(move.degrees<=1,'large bank movement issued under load') end end
check(liveMoves>0,'load test did not exercise live movements')
check(fine.nodes[2].files['/config/distributed-startup.json']==preset,'loaded operation overwrote no-load preset')
local corrupt=world(nil,nil,{lowStart=true,cachedPreset='not a table'})
corrupt.untilTrue(function() return corrupt.nodes[3].R.fresh('regulation')~=nil end,3); corrupt.command('start')
check(corrupt.untilTrue(function() return corrupt.nodes[2].R.state.phase=='live' end,60),'corrupt optional preset prevented startup')
check(corrupt.nodes[2].R.state.startupMeasurements[1].mode=='coarse','corrupt preset was used')
local lost=world(nil,nil,{lowStart=true,voltageScale=.999,ignoreSmallMoves=true})
lost.untilTrue(function() return lost.nodes[3].R.fresh('regulation')~=nil end,3); lost.command('start')
check(lost.untilTrue(function() return lost.nodes[2].R.state.phase=='tripped' end,60),'lost small command passed movement tolerance')
lost.untilTrue(function() return false end,.5)
local lostReason=false
for _,event in ipairs(lost.nodes[2].R.events) do
 if event.code=='variac_stuck' and event.reason:find('no movement in commanded direction',1,true) then
  lostReason=event.detail and #event.detail.startupMeasurements>0
 end
end
check(lostReason and not lost.contacts.plus and not lost.contacts.minus,'missing per-stage no-motion diagnostic or output connected')
local transient=world(nil,nil,{lowStart=true,voltageScale=.95,transientInBand=true})
transient.untilTrue(function() return transient.nodes[3].R.fresh('regulation')~=nil end,3); transient.command('start')
check(transient.untilTrue(function() return transient.nodes[2].R.state.phase=='live' end,60),'single transient acceptable reading prevented startup correction')
check(transient.transientUsed and transient.maxStartupAttempt==2,'startup accepted one transient in-band reading')
local nonlinear=world(nil,nil,{lowStart=true,voltageExponent=1.5})
nonlinear.untilTrue(function() return nonlinear.nodes[3].R.fresh('regulation')~=nil end,3); nonlinear.command('start')
check(nonlinear.untilTrue(function() return nonlinear.nodes[2].R.state.phase=='live' end,120),'nonlinear startup corrections did not converge')
check(nonlinear.maxStartupAttempt>3 and nonlinear.maxStartupAttempt<=12,'nonlinear fixture did not exercise extended correction budget')
check(#nonlinear.nodes[2].R.state.startupMeasurements==nonlinear.maxStartupAttempt,'startup measurements missing')
local diverging=world(nil,nil,{lowStart=true,oscillating=true})
diverging.untilTrue(function() return diverging.nodes[3].R.fresh('regulation')~=nil end,3); diverging.command('start')
check(diverging.untilTrue(function() return diverging.nodes[2].R.state.phase=='tripped' end,180),'nonconverging startup did not stop')
check(diverging.maxStartupAttempt==12 and not diverging.contacts.plus and not diverging.contacts.minus,'correction limit or isolation failed')
diverging.untilTrue(function() return false end,.5)
local historyReason=false
for _,event in ipairs(diverging.nodes[2].R.events) do if event.reason and event.reason:find('output history',1,true) then historyReason=true end end
check(historyReason,'nonconverging startup did not record voltage history')
local diagnostic
for _,event in ipairs(diverging.nodes[2].R.events) do
 if event.detail and event.detail.startupMeasurements then diagnostic=event.detail.startupMeasurements end
end
check(diagnostic and #diagnostic==12,'startup measurement detail was not attached to trip')
for _,sample in ipairs(diagnostic) do
 check(sample.outputBefore and sample.output and sample.input and sample.predicted,'missing electrical prediction diagnostic')
 for _,bank in ipairs(sample.banks) do check(bank.beforeDegrees and bank.commandDegrees and bank.targetDegrees and bank.actualDegrees,'missing movement diagnostic') end
end
-- An opening between the contact snapshot and gauge read is a contact fault,
-- while genuinely low voltage with closed contacts still trips.
direct.openOnInputRead=true
direct.untilTrue(function() return direct.nodes[3].R.state.latched end,3)
direct.untilTrue(function() return false end,.5)
local falseInputFault=false
for _,event in ipairs(direct.nodes[3].R.events) do if event.reason and event.reason:find('Input voltage outside safe range',1,true) then falseInputFault=true end end
check(direct.nodes[3].R.state.latched and not falseInputFault,'contact opening generated false input-voltage fault')
nonlinear.inputVoltage=0
check(nonlinear.untilTrue(function() return nonlinear.nodes[3].R.state.latched and not nonlinear.contacts.input end,3),'real undervoltage did not trip')
local unreachable=world(nil,nil,{lowStart=true,voltageScale=.5})
unreachable.untilTrue(function() return unreachable.nodes[3].R.fresh('regulation')~=nil end,3); unreachable.command('start')
check(unreachable.untilTrue(function() return unreachable.nodes[2].R.state.phase=='tripped' end,60),'unreachable startup did not trip')
check(not unreachable.contacts.plus and not unreachable.contacts.minus,'unverified voltage connected to output')
for _,temperature in ipairs({140,126}) do
 local hot=world(nil,nil,{lowStart=true,startupMoveTime=10})
 hot.untilTrue(function() return hot.nodes[3].R.fresh('regulation')~=nil end,3); hot.command('start')
 check(hot.untilTrue(function() return hot.nodes[2].R.state.phase=='positioning' and next(hot.motion)~=nil end,30),'long startup movement did not begin')
 local started=hot.time; hot.temperature.a2=temperature
 check(hot.untilTrue(function() return not hot.contacts.input and hot.nodes[3].R.state.phase=='tripped' end,temperature==140 and 1 or 6),'thermal protection stalled during startup movement')
 check(hot.time-started<10 and not hot.contacts.plus and not hot.contacts.minus,'thermal trip waited for movement or connected output')
 hot.untilTrue(function() return false end,.2)
 local thermalReason=false
 for _,event in ipairs(hot.nodes[3].R.events) do if event.detail and event.detail.member=='a2' and event.code:match('^thermal_') then thermalReason=true end end
 check(thermalReason and not hot.nodes[3].R.state.realignRequested,'thermal fault missing member or incorrectly scheduled alignment recovery')
end
print(('PASS: %d distributed integration checks'):format(checks))
