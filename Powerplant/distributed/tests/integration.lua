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
local function world(restore,thermalFault)
  local W={time=0,nodes={},contacts={input=false,plus=false,minus=false},positions={a1=.8,a2=.5,b1=.9,c1=.98},temperature={},moves={},closes={},drop={}}
  local function serialize(v)
    if type(v)=='string' then return string.format('%q',v) end
    if type(v)~='table' then return tostring(v) end
    local parts={'{'}; for k,x in pairs(v) do parts[#parts+1]='['..serialize(k)..']='..serialize(x)..',' end; parts[#parts+1]='}'; return table.concat(parts)
  end
  for _,role in ipairs(U.roles) do
    local N={id=cfg.ids[role],role=role,queue={},timers={},files={},timer=0}; W.nodes[N.id]=N
    if restore then N.files['/config/distributed-state.json']=serialize(restore[role] or {events={},latched=true,runRequested=false}) end
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
    local function native() env.sleep(.001) end
    local devices={back={isWireless=function() return true end}}
    for name in pairs(W.contacts) do
      devices[name]={isClosed=function() native(); return W.contacts[name] end,
        open=function() native(); W.contacts[name]=false end,
        close=function() native(); W.closes[#W.closes+1]={role=N.role,name=name}; check(N.role=='protection','non-protection closed a breaker'); W.contacts[name]=true end,
        getStatus=function() native(); return {closed=W.contacts[name],canClose=true,currentValid=true,current=1,tripEnabled=true,tripCurrent=50} end}
    end
    for name in pairs(W.positions) do devices[name]={
      getStatus=function() native(); return {position=W.positions[name],ratio=.01+.99*W.positions[name]} end,
      getThermalStatus=function() native(); return {available=true,unit='C',temperature=W.temperature[name] or 100} end} end
    for i,key in ipairs({'A','B','C'}) do devices[settings['gear'..key]]={isRunning=function() native(); return false end,
      rotate=function(degrees,direction)
        native(); W.moves[#W.moves+1]={degrees=degrees,isolated=not W.contacts.input and not W.contacts.plus and not W.contacts.minus}
        for _,name in ipairs(settings['variacs'..key]) do W.positions[name]=math.max(0,math.min(1,W.positions[name]+degrees*direction/315)) end
      end} end
    devices.vin={voltage=function() native(); return W.contacts.input and 1500 or 0 end}
    devices.vout={voltage=function() native(); local value=W.contacts.input and 3750 or 0; for _,name in ipairs({'a1','b1','c1'}) do value=value*(.00999996389330349+.989990071137444*W.positions[name]) end; return value end}
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
check(event('later') and event('earlier') and event('observation'),'multiple reasons lost during merge')
-- Boot from a persisted running state without a UI start command.
local previouslyRunning={regulation={events={},latched=false,runRequested=true},protection={events={},latched=false,runRequested=true}}
local resumed=world(previouslyRunning); resumed.drop.master=true
check(resumed.untilTrue(function() return resumed.nodes[2].R.state.phase=='live' end,150),'previously running workers failed automatic startup without UI')
check(resumed.contacts.input and resumed.contacts.plus and resumed.contacts.minus,'automatic startup did not connect')
resumed.positions.a2=resumed.positions.a1+0.000001
check(resumed.untilTrue(function() return not resumed.contacts.input and not resumed.contacts.plus and not resumed.contacts.minus end,2),'small live bank spread did not trip')
local stopped=world({regulation={events={},latched=true,runRequested=false},protection={events={},latched=true,runRequested=false}})
stopped.untilTrue(function() return false end,3)
check(not stopped.contacts.input and #stopped.closes==0,'maintenance reboot reconnected')
local blocked=world(previouslyRunning,true)
blocked.untilTrue(function() return false end,3)
check(#blocked.closes==0 and not blocked.nodes[3].R.state.runRequested,'automatic startup cleared thermal fault')
check(W.nodes[3].R.state.runRequested==false,'trip did not clear restart intent')
print(('PASS: %d distributed integration checks'):format(checks))
