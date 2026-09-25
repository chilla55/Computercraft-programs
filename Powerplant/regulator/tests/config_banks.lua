-- Run from repository root: lua Powerplant/regulator/tests/config_banks.lua
-- Deterministic CC peripheral mocks; these do not simulate electrical sharing.
local path='Powerplant/regulator/transformer_controller.lua'
local f=assert(io.open(path)); local source=f:read('*a'); f:close()
local count=0
local function check(value,message) assert(value,message); count=count+1 end
local function copy(t) local n={} for k,v in pairs(t) do n[k]=type(v)=='table' and copy(v) or v end return n end
local function fixture(saved,previousFiles)
  -- Legacy scenarios explicitly exercise lease-required operation; autonomy tests opt in.
  if saved and saved.autonomousFallback==nil then saved.autonomousFallback=false end
  local state={time=0,positions={{.8,.8},{.9},{.98}},closed={true,true},moves={},messages={},saved=nil,reads={},direction={1,1,1},logs={},sent={},inbox={}}
  state.files=copy(previousFiles or {})
  if saved then state.files['dual-variac-config.json']='CONFIG' end
  local devices={}
  local bankNames={{'powergrid:variac_1','extra_variac'},{'powergrid:variac_2'},{'powergrid:variac_4'}}
  for i,names in ipairs(bankNames) do
    for j,name in ipairs(names) do
      devices[name]={getPosition=function() return state.positions[i][j] end,getRatio=function() return .01+.99*state.positions[i][j] end,
        getThermalStatus=function() return {available=true,unit='C',temperature=100,ambientTemperature=18.02,overheated=false} end,
        getStatus=function() local p=state.positions[i][j]; return {position=p,ratio=.01+.99*p,shaftSpeed=16} end}
    end
    devices['Create_SequencedGearshift_'..(i+3)]={isRunning=function() return false end,rotate=function(n,d)
      state.moves[#state.moves+1]={stage=i,n=n,d=d,inputOpen=state.inputClosed==false,open=not state.closed[1] and not state.closed[2]}
      for j,p in ipairs(state.positions[i]) do
        if not ((state.stuck and i==1 and j==2) or state.stuckStage==i) then state.positions[i][j]=math.max(0,math.min(1,p+n*d*state.direction[i]/315)) end
      end
    end}
  end
  devices.powergrid_voltage_gauge_6={voltage=function() return 1500 end}
  devices.powergrid_voltage_gauge_7={voltage=function()
    local v=3750; for i=1,3 do v=v*(0.00999996389330349+0.989990071137444*state.positions[i][1]) end; return v
  end}
  for i=1,2 do devices['powergrid:hv_breaker_'..(i+1)]={getStatus=function() return {closed=state.closed[i],canClose=true,currentValid=true,current=1,tripEnabled=true,tripCurrent=50} end,
    open=function() state.closed[i]=false end,close=function() state.closed[i]=true end,isClosed=function() return state.closed[i] end,setTripCurrent=function() end} end
  state.inputClosed=true
  devices.input_isolator={getStatus=function() return {closed=state.inputClosed,canClose=true} end,
    open=function() state.inputClosed=false end,close=function() state.inputClosed=true end,
    isClosed=function() return state.inputClosed end,setTripCurrent=function() end}
  devices.back={isWireless=function() return true end,open=function() end,close=function() end,transmit=function() end,isOpen=function() return true end}
  devices.unrelated={getStatus=function() return {} end}
  local env=setmetatable({}, {__index=_G})
  env.fs={exists=function(p) return state.files[p]~=nil end,
    getDir=function(p) return p:match('^(.*)/') or '' end,
    combine=function(a,b) return a=='' and b or a..'/'..b end,
    open=function(p,mode)
      local buffer=mode=='a' and (state.files[p] or '') or ''
      return {readAll=function() return state.files[p] end,
        write=function(text) buffer=buffer..text end,
        writeLine=function(line) state.logs[#state.logs+1]=line end,
        close=function() if mode~='r' then state.files[p]=buffer end end}
    end,
    delete=function(p) state.files[p]=nil end,
    move=function(a,b) assert(state.files[a]~=nil); state.files[b]=state.files[a]; state.files[a]=nil end}
  local function serialize(value)
    if type(value)=='string' then return string.format('%q',value) end
    if type(value)~='table' then return tostring(value) end
    local parts={}
    for k,v in pairs(value) do parts[#parts+1]='['..serialize(k)..']='..serialize(v)..',' end
    table.sort(parts); return '{'..table.concat(parts)..'}'
  end
  env.textutils={unserializeJSON=function(text)
    if text=='CONFIG' then return copy(saved) end
    local parsed=load('return '..text,'mock-json','t',{}); return parsed and parsed() or nil
  end,serializeJSON=function(t)
    if t.target then state.saved=copy(t) end
    return serialize(t)
  end,serialize=serialize}
  env.shell={getRunningProgram=function() return path end}
  env.peripheral={wrap=function(n) return devices[n] end,getNames=function() local names={} for n in pairs(devices) do names[#names+1]=n end return names end,
    getMethods=function(n) local methods={} for m in pairs(devices[n]) do methods[#methods+1]=m end return methods end}
  env.os={clock=function() return state.time end,epoch=function() return state.time*1000 end,getComputerID=function() return 3 end}
  env.sleep=function(dt) state.time=state.time+dt; if state.onSleep then state.onSleep() end; assert(state.time<500,'Test timed out') end
  env.print=function(s) state.messages[#state.messages+1]=tostring(s) end
  env.printError=env.print; env.write=function() end
  env.read=function() return table.remove(state.reads,1) or '' end
  env.term={clear=function() end,setCursorPos=function() end}
  env.rednet={isOpen=function() return true end,close=function() end,open=function() end,send=function(id,message,protocol)
    state.sent[#state.sent+1]=copy(message)
    if state.onSend then state.onSend(message) end
  end,receive=function(_,timeout)
    local m=table.remove(state.inbox,1)
    if m then return saved.masterId,m end
    env.sleep(timeout); return nil
  end}
  env.parallel={waitForAny=function(...) 
    if not state.concurrent then return (...)() end
    local tasks={}
    for _,fn in ipairs({...}) do tasks[#tasks+1]={co=coroutine.create(fn),wake=state.time} end
    while true do
      local nextWake=math.huge
      for _,task in ipairs(tasks) do
        if task.wake<=state.time then
          local ok,delay=coroutine.resume(task.co)
          if not ok then error(delay,0) end
          if coroutine.status(task.co)=='dead' then return end
          task.wake=state.time+(delay or .01)
        end
        nextWake=math.min(nextWake,task.wake)
      end
      state.time=nextWake
      assert(state.time<500,'Scheduler timeout')
    end
  end}
  local plainSleep=env.sleep
  env.sleep=function(dt)
    if not state.concurrent then return plainSleep(dt) end
    if state.onSleep then state.onSleep() end
    coroutine.yield(dt)
  end
  env.os.pullEvent=function() env.sleep(.1); return 'timer',0 end
  local function loadController(testOnly,command)
    local code=source
    if testOnly then
      code=code:sub(1,assert(code:find("local ok,err\nif managed then",1,true))-1)..[[
return {config=C,initialise=initialise,snapshot=snapshot,aligned=aligned,settled=settled,
 uiAction=uiAction,uiSnapshot=uiSnapshot,energizeInputs=energizeInputs,isolateAll=isolateAll,maintainIsolation=maintainIsolation,
 syncBank=syncBank,discoverDirection=discoverDirection,guard=guard,apply=apply,
 cancelThermalSampling=cancelThermalSampling,thermalPoll=thermalPoll,thermalReset=thermalReset,thermalStatus=thermalStatus,stageCurrentEstimate=stageCurrentEstimate,statusMessage=statusMessage,receiver=receiver,context=function() return faultContext end,
 network=function() networkOpened=true; return net,session end,
 setHoming=function() phase='homing' end,setLive=function() phase='live' end, setMoving=function(i,v) bankMoving[i]=v end}
]]
    end
    return assert(load(code,'@'..path,'t',env))(command or 'run')
  end
  return state,loadController,devices
end
local config={version=11,inputBreakers={'input_isolator'},protectionMode='current',variacsA={'powergrid:variac_1','extra_variac'},variacsB={'powergrid:variac_2'},variacsC={'powergrid:variac_4'}}
-- Migration retains customized v8-v10 primary mappings and preserves v7's established mapping migration.
for version=7,16 do
  local st,load=fixture({version=version,variacA='custom',maxLiveStep=8})
  local api=load(true)
  check(api.config.version==18,'migration version')
  check(api.config.variacsA[1]==(version==7 and 'powergrid:variac_1' or 'custom'),'migration primary')
  check(api.config.maxLiveStep==(version<9 and 315 or 8),'coarse migration')
end
-- Discovery selects multiple compatible members; invalid/reused choices reprompt.
do
  local st,load=fixture(nil)
  st.reads={'','','','','1,2','', 'powergrid:variac_1','powergrid:variac_2','','','','','',''}
  load(false,'configure')
  check(st.saved.version==18 and #st.saved.variacsA==2,'wizard saves bank')
  check(st.saved.variacsB[1]=='powergrid:variac_2','duplicate choice reprompt')
  check(#st.moves==0 and st.closed[1] and st.closed[2],'configure does not operate hardware')
end
-- Duplicate members, stage drives and malformed bank lists are rejected.
for _,edit in ipairs({function(c) c.variacsB={'extra_variac'} end,function(c) c.gearB='Create_SequencedGearshift_4' end,function(c) c.variacsA={bad='x'} end}) do
  local c=copy(config); edit(c); local _,load=fixture(c)
  check(not pcall(load,true),'invalid configuration accepted')
end
-- Read every bank member; telemetry retains the original primary fields.
do
  local st,load=fixture(config); local api=load(true); api.initialise()
  local s=api.snapshot(1)
  check(#s.members==2 and s.members[2].name=='extra_variac' and s.position==.8,'bank snapshot')
  st.positions[1][2]=.7
  local ok,err=pcall(api.aligned,1,api.snapshot(1))
  check(not ok and tostring(err):find('BANK_MISALIGNED: 1',1,true),'misalignment detection')
end
-- Both drive orientations and endpoint-blocked direction discovery home to minimum.
for _,direction in ipairs({1,-1}) do
  local st,load=fixture(config); st.positions[1]={1,.5}; st.direction[1]=direction
  local api=load(true); api.initialise(); api.syncBank(1)
  check(st.positions[1][1]==0 and st.positions[1][2]==0,'minimum sync')
  for _,move in ipairs(st.moves) do check(move.open and move.inputOpen,'sync motion before input/output disconnection') end
  check(st.moves[#st.moves].d==-direction,'wrong endpoint direction')
end
-- Failure to open either breaker prevents any sync movement.
do
  local st,load,devices=fixture(config); local api=load(true); api.initialise()
  st.closed[1]=true; devices['powergrid:hv_breaker_2'].open=function() end
  check(not pcall(api.syncBank,1) and #st.moves==0,'unverified open allowed movement')
end
-- A stuck follower must fail verification even when the primary homes correctly.
do
  local st,load=fixture(config); st.stuck=true; st.positions[1]={.8,.5}
  local api=load(true); api.initialise(); local ok,err=pcall(api.syncBank,1)
  check(not ok and tostring(err):find('did not reach minimum',1,true),'stuck member accepted')
  check(not st.closed[1] and not st.closed[2],'failed sync closed breakers')
end
-- The slowest arm, not merely the first member or gear, determines settling.
do
  local st,load=fixture(config); local api=load(true); api.initialise()
  local ticks=0; st.onSleep=function() ticks=ticks+1; if ticks<=8 then st.positions[1][2]=.8+(8-ticks)*.001 end end
  api.isolateAll(); api.setHoming(); api.settled(1)
  check(ticks>=12,'did not wait for follower interpolation')
end
-- Full standalone control path: startup mismatch -> disconnect -> sync -> retune -> reconnect.
do
  local st,load=fixture(config); st.positions[1]={.8,.5}
  st.onSleep=function() if st.closed[1] and st.closed[2] then error('Stopped by user',0) end end
  load(false)
  local homed=false
  for _,move in ipairs(st.moves) do if move.n==318 then homed=true; check(move.open,'full-path homing with closed breakers') end end
  check(homed,'full-path mismatch did not home')
  check(table.concat(st.messages,'\n'):find('Closing both breakers',1,true),'did not retune and reconnect')
  check(not st.closed[1] and not st.closed[2],'stop left closed contacts')
end
-- No routine homing on an aligned bank, and old single-member configurations still run.
for _,c in ipairs({config,{version=10}}) do
  local st,load=fixture(c)
  st.onSleep=function() if st.closed[1] and st.closed[2] then error('Stopped by user',0) end end
  load(false)
  for _,move in ipairs(st.moves) do check(move.n~=318,'routine endpoint homing') end
  check(table.concat(st.messages,'\n'):find('Closing both breakers',1,true),'normal start failed: '..table.concat(st.messages,' | '))
end
-- Status includes explicit transformer voltages, targets, stages and readable bank members.
do
  local st,load,devices=fixture(config); local api=load(true); api.initialise()
  local m=api.statusMessage(42)
  check(m.requestSeq==42 and m.configuredTarget==2640 and m.currentTarget==2640,'status targets')
  check(m.voltages.input.volts==1500 and m.voltages.output.volts==m.outputVoltage,'status voltages')
  check(m.stages[1].position==.8 and #m.stages[1].members==2 and m.stages[3].stage==3,'status stages')
  devices.extra_variac.getStatus=function() error('detached') end
  devices.powergrid_voltage_gauge_6.voltage=function() error('detached') end
  m=api.statusMessage()
  check(not m.stages[1].available and not m.stages[1].members[2].available and m.stages[1].members[1].available,'missing bank member')
  check(m.stages[1].position==nil and m.variacs[1]==nil,'missing bank pretended complete')
  check(not m.voltages.input.available and m.inputVoltage==nil and m.voltages.input.volts==nil,'missing gauge pretended zero')
end
-- Accepted get_status returns status correlated to the request without renewing a lease.
do
  local c=copy(config); c.masterId=9
  local st,load=fixture(c); local api=load(true); api.initialise()
  local net,session=api.network(); local lastSeen=net.lastSeen
  st.inbox={{schema=1,type='get_status',node=3,session=session,seq=8,sentAt=0}}
  st.onSleep=function() error('test complete',0) end
  pcall(api.receiver)
  check(#st.sent==2 and st.sent[1].accepted and st.sent[2].type=='status' and st.sent[2].requestSeq==8,'immediate status reply')
  check(net.lastSeen==lastSeen and not net.enabled and net.lastSeq==8,'status renewed lease')
  st.inbox={{schema=1,type='get_status',node=3,session=session,seq=8,sentAt=0}}
  pcall(api.receiver)
  check(#st.sent==3 and not st.sent[3].accepted,'replayed status request accepted')
end
-- Stuck direction detection supplies the actual stage number and member.
for stage=1,3 do
  local st,load=fixture(config); st.stuckStage=stage
  local api=load(true); api.initialise()
  local ok=pcall(api.discoverDirection,stage)
  local detail=api.context()
  check(not ok and detail.code=='variac_stuck' and detail.stage==stage and detail.member==config['variacs'..string.char(64+stage)][1],'stuck stage detail')
end
-- A stalled 1-degree fine move must be reported despite the 1-degree position tolerance.
do
  local st,load=fixture(config); local api=load(true); api.initialise()
  for i=1,3 do api.settled(i); api.discoverDirection(i) end
  st.stuckStage=2
  local ok=pcall(api.apply,{0,1,0})
  local detail=api.context()
  check(not ok and detail.code=='variac_stuck' and detail.stage==2,'stalled fine move silently retried')
end
-- A recurring mismatch gets one recovery attempt, then stays disconnected.
do
  local st,load=fixture(config); st.positions[1]={.8,.5}
  st.onSleep=function()
    if st.closed[1] and st.closed[2] then st.positions[1][2]=st.positions[1][1]-.1 end
  end
  load(false)
  local attempts=0
  for _,move in ipairs(st.moves) do if move.n==318 then attempts=attempts+1 end end
  check(attempts==1 and not st.closed[1] and not st.closed[2],'unbounded bank sync retries')
end
-- Cooperative managed run: the master receives a recoverable mismatch, then a
-- stage/member-specific stuck fault after a failed endpoint verification.
do
  local c=copy(config); c.masterId=9
  local st,load=fixture(c); st.concurrent=true; st.stuck=true; st.positions[1]={.8,.5}
  local sequence=0; local stuckFault; local sawLatched=false
  st.onSend=function(m)
    if m.type=='status' and not m.fault then
      sequence=sequence+1
      st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=sequence,sentAt=st.time*1000,
        enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000}}
    elseif m.type=='fault' and m.code=='variac_stuck' then stuckFault=m
    elseif m.type=='status' and m.fault then
      sawLatched=m.faultDetails and m.faultDetails.stage==1 and m.faultDetails.member=='extra_variac'
    end
  end
  st.onSleep=function() if sawLatched then error('Stopped by user',0) end end
  load(false)
  check(stuckFault and stuckFault.stage==1 and stuckFault.stageName=='A' and stuckFault.member=='extra_variac' and not stuckFault.recoverable,'master stuck report')
  check(sawLatched,'latched status lacks fault detail')
  local sawRecovery=false
  for _,m in ipairs(st.sent) do if m.type=='fault' and m.code=='bank_misaligned' and m.recoverable then sawRecovery=true end end
  check(sawRecovery and not st.closed[1] and not st.closed[2],'managed bank recovery sequence')
end
-- Entry ratio and all four measurements are diagnostic; control uses measured post-entry input.
do
  local c=copy(config); c.entryRatio=5; c.sourceGauge='source_gauge'; c.preStepUpGauge='before_exit'
  local st,load,devices=fixture(c)
  devices.source_gauge={voltage=function() return 7500 end}
  devices.before_exit={voltage=function() return devices.powergrid_voltage_gauge_7.voltage()/2.5 end}
  local api=load(true); api.initialise()
  local m=api.statusMessage()
  check(m.sourceVoltage==7500 and m.inputVoltage==1500 and m.entryRatio==5,'four-point input telemetry')
  check(m.entryMeasuredRatio==5 and m.exitMeasuredRatio==2.5,'measured ratios')
  check(m.entryExpectedVoltage==1500 and m.exitExpectedVoltage==m.outputVoltage,'nominal conversion')
  check(math.abs(m.minimumSourceVoltsEstimate-5*m.minimumGeneratorVolts)<1e-8,'source floor estimate')
  check(pcall(api.guard),'raw source incorrectly applied to variac voltage limit')
  devices.source_gauge.voltage=function() return 500 end
  check(pcall(api.guard),'diagnostic source estimate replaced actual input')
  devices.powergrid_voltage_gauge_6.voltage=function() return 900 end
  check(not pcall(api.guard),'post-entry undervoltage ignored')
  devices.powergrid_voltage_gauge_6.voltage=function() return 1500 end
  devices.source_gauge=nil; devices.before_exit.voltage=function() return 0/0 end
  m=api.statusMessage()
  check(m.voltages.source.configured and not m.voltages.source.available and m.sourceVoltage==nil,'missing source measurement')
  check(m.entryMeasuredRatio==nil and m.entryExpectedVoltage==nil and m.preStepUpVoltage==nil,'invented optional measurements')
  check(pcall(api.guard),'optional gauge failure disabled regulation')
  devices.source_gauge={voltage=function() return 7200 end}
  m=api.statusMessage()
  check(m.sourceVoltage==7200,'optional gauge did not reattach')
  devices.before_exit.voltage=function() return 0 end
  m=api.statusMessage()
  check(m.exitMeasuredRatio==nil and m.preStepUpVoltage==0,'zero denominator ratio')
end
-- Older configurations leave extra gauges unassigned and do not invent an entry ratio.
do
  local _,load=fixture(config); local api=load(true); api.initialise(); local m=api.statusMessage()
  check(api.config.entryRatio==1 and not m.voltages.source.configured and not m.voltages.preStepUp.configured,'optional defaults')
end
-- Wizard accepts winding-style ratio syntax and discovered optional gauges.
do
  local st,load,devices=fixture(config)
  devices.source_gauge={voltage=function() return 7500 end}; devices.before_exit={voltage=function() return 1056 end}
  -- Two initial settings; eleven required role selections; four optional gauges;
  -- six regulation settings; entry ratio. Remaining settings keep defaults.
  for i=1,13 do st.reads[#st.reads+1]='' end
  st.reads[#st.reads+1]='source_gauge'; st.reads[#st.reads+1]='before_exit'
  st.reads[#st.reads+1]=''; st.reads[#st.reads+1]=''
  for i=1,7 do st.reads[#st.reads+1]='' end
  st.reads[#st.reads+1]='200:40'
  load(false,'configure')
  check(st.saved.entryRatio==5 and st.saved.sourceGauge=='source_gauge' and st.saved.preStepUpGauge=='before_exit','wizard entry settings')
  check(#st.moves==0 and st.closed[1] and st.closed[2],'gauge discovery operated hardware')
end
for _,edit in ipairs({function(c) c.entryRatio=0 end,function(c) c.entryRatio=-5 end,
  function(c) c.sourceGauge='powergrid_voltage_gauge_6' end,
  function(c) c.sourceGauge='extra_variac' end,
  function(c) c.sourceGauge='same'; c.preStepUpGauge='same' end}) do
  local c=copy(config); edit(c); local _,load=fixture(c)
  check(not pcall(load,true),'invalid entry configuration accepted')
end
-- Ratio deviations are visible diagnostics, not automatic protection trips.
do
  local c=copy(config); c.entryRatio=5; c.sourceGauge='source_gauge'; c.preStepUpGauge='before_exit'
  local _,load,devices=fixture(c)
  devices.source_gauge={voltage=function() return 7500 end}
  devices.before_exit={voltage=function() return devices.powergrid_voltage_gauge_7.voltage()/2.5 end}
  local api=load(true); api.initialise(); local m=api.statusMessage()
  check(m.ratioChecks.entry.withinTolerance and m.ratioChecks.exit.withinTolerance,'nominal ratios flagged')
  devices.source_gauge.voltage=function() return 6000 end
  m=api.statusMessage()
  check(not m.ratioChecks.entry.withinTolerance and math.abs(m.ratioChecks.entry.deviationPercent+20)<1e-8,'ratio mismatch invisible')
  check(pcall(api.guard),'ratio mismatch incorrectly trips')
end
-- Current alone plus source voltage estimates DC power; a real power reading stays separate.
do
  local c=copy(config); c.sourceGauge='source_gauge'; c.sourceCurrentGauge='current_gauge'; c.sourcePowerGauge='power_gauge'
  local st,load,devices=fixture(c)
  devices.source_gauge={voltage=function() return 7200 end}
  devices.current_gauge={current=function() return -10 end,getValue=function() return 999 end}
  devices.power_gauge={getValue=function() return -71000 end}
  local api=load(true); api.initialise(); local m=api.statusMessage()
  check(m.sourceCurrentAmps==-10 and m.sourcePowerWatts==-71000,'signed source meters')
  check(m.sourcePowerEstimateWatts==72000 and m.sourceMeters.power.method=='getValue','independent DC estimate')
  devices.power_gauge=nil
  m=api.statusMessage()
  check(m.sourcePowerWatts==nil and m.sourcePowerEstimateWatts==72000,'missing power gauge lost estimate')
  devices.current_gauge.current=function() st.time=st.time+.3; return 10 end
  m=api.statusMessage()
  check(m.sourcePowerEstimateWatts==nil,'stale paired power estimate')
  devices.current_gauge={getValue=function() return 0 end}
  m=api.statusMessage()
  check(m.sourceCurrentAmps==0 and m.sourcePowerEstimateWatts==0,'valid zero-current sample')
  devices.current_gauge.getValue=function() return '10 A' end
  m=api.statusMessage()
  check(not m.sourceMeters.current.available and m.sourcePowerEstimateWatts==nil,'nonnumeric current accepted')
  check(pcall(api.guard),'monitor-only current gauge failure trips')
end
-- Source overcurrent is absolute, configurable and fails closed when enabled without a valid reading.
for _,reading in ipairs({11,-11,'missing'}) do
  local c=copy(config); c.sourceCurrentGauge='current_gauge'; c.sourceCurrentTripAmps=10
  local _,load,devices=fixture(c)
  devices.current_gauge={getValue=function() if reading=='missing' then error('detached') end return reading end}
  local api=load(true); api.initialise(); local ok=pcall(api.guard); local detail=api.context()
  check(not ok and detail.code==(reading=='missing' and 'source_current_unavailable' or 'source_overcurrent'),'source trip not enforced')
  check(detail.limitAmps==10 and detail.peripheral=='current_gauge' and detail.stage==nil,'source fault attributes')
end
do
  local c=copy(config); c.sourceCurrentGauge='current_gauge'; c.sourceCurrentTripAmps=10
  local _,load,devices=fixture(c); devices.current_gauge={current=function() return 10 end}
  local api=load(true); api.initialise()
  check(pcall(api.guard) and api.statusMessage().sourceCurrentProtectionEnabled,'source threshold equality')
end
for _,edit in ipairs({function(c) c.sourceCurrentTripAmps=10 end,
  function(c) c.sourceCurrentTripAmps=-1 end,
  function(c) c.sourceCurrentGauge='extra_variac' end,
  function(c) c.ratioTolerancePercent=0 end}) do
  local c=copy(config); edit(c); local _,load=fixture(c)
  check(not pcall(load,true),'invalid source protection configuration accepted')
end
-- In managed mode source overcurrent opens/latches, reports measured/limit amps,
-- and cannot be cleared by continuing enable heartbeats.
do
  local c=copy(config); c.masterId=9; c.sourceCurrentGauge='current_gauge'; c.sourceCurrentTripAmps=10
  local st,load,devices=fixture(c); st.concurrent=true
  devices.current_gauge={current=function() return 11 end}
  local sequence=0; local report; local latchedCount=0
  st.onSend=function(m)
    if m.type=='status' then
      if m.faultDetails and m.faultDetails.code=='source_overcurrent' then latchedCount=latchedCount+1 end
      sequence=sequence+1
      st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=sequence,sentAt=st.time*1000,
        enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000}}
    elseif m.type=='fault' and m.code=='source_overcurrent' then report=m end
  end
  st.onSleep=function() if latchedCount>=3 then error('Stopped by user',0) end end
  load(false)
  check(report and report.currentAmps==11 and report.limitAmps==10 and not report.recoverable,'master source trip report')
  check(#st.moves==0 and not st.closed[1] and not st.closed[2] and latchedCount>=3,'source fault bypassed by heartbeat')
end
local function stageFixture(counts,sourceAmps)
  local c=copy(config); c.entryRatio=5; c.sourceGauge='source_gauge'; c.sourceCurrentGauge='current_gauge'; c.preStepUpGauge='before_exit'
  for i,key in ipairs({'A','B','C'}) do
    c['variacs'..key]={}
    for j=1,counts[i] do c['variacs'..key][j]='bank_'..key..'_'..j end
  end
  local st,load,devices=fixture(c)
  local maximum=0.00999996389330349+0.989990071137444
  local positions={1,1,(1056/(1500*maximum^2)-0.00999996389330349)/0.989990071137444}
  for i,key in ipairs({'A','B','C'}) do
    for _,name in ipairs(c['variacs'..key]) do
      devices[name]={getThermalStatus=function() return {available=true,unit='C',temperature=100} end,getStatus=function() return {position=positions[i],ratio=.01+.99*positions[i],shaftSpeed=16} end}
    end
  end
  devices.source_gauge={voltage=function() return 7200 end}
  devices.current_gauge={current=function() return sourceAmps end}
  devices.before_exit={voltage=function() return 1056 end}
  local api=load(true); api.initialise()
  st.closed={true,true}; api.setLive()
  return api,st,devices
end
-- 29 A remains a current cap: three members at 1056 V permit 12.76 A at a 7200 V source.
do
  local api,st,devices=stageFixture({3,3,3},12.75)
  local e=api.stageCurrentEstimate()
  check(e.enabled and e.available and e.limitingStage==3,'limiting stage estimate')
  check(math.abs(e.sourceLimitAmps-12.76)<1e-8 and e.perVariacLimitAmps==29,'incorrect 29 A translation')
  check(math.abs(e.stages[3].perVariacCurrentEstimate-7200*12.75/1056/3)<1e-8,'per-member current estimate')
  check(pcall(api.guard),'below stage limit trips')
  devices.current_gauge.current=function() return 12.77 end
  local ok=pcall(api.guard); local d=api.context()
  check(not ok and d.code=='stage_overcurrent_estimate' and d.stage==3 and d.perVariacLimitAmps==29,'stage limit not enforced')
  api.config.sourceCurrentTripAmps=12
  e=api.stageCurrentEstimate()
  check(e.effectiveSourceLimitAmps==12,'fixed source cap not retained')
end
-- The smallest bank, not always the final stage, can constrain the source.
do
  local api=stageFixture({1,3,3},5)
  local e=api.stageCurrentEstimate()
  check(e.limitingStage==1 and e.sourceLimitAmps<12.76,'small upstream bank ignored')
end
-- A one-member stage at 1056 V is limited to 30.624 kW, not the 81.038 kW reference product.
do
  local api=stageFixture({1,1,1},4)
  local e=api.stageCurrentEstimate()
  check(math.abs(e.sourceLimitAmps-4.2533333333333)<1e-8,'reference power incorrectly made constant')
end
-- Loaded pre-exit sag lowers the limit; a high output sample never inflates the calibrated ceiling.
do
  local api,st,devices=stageFixture({3,3,3},12)
  local before=api.stageCurrentEstimate().sourceLimitAmps
  devices.before_exit.voltage=function() return 1000 end
  local e=api.stageCurrentEstimate()
  check(e.sourceLimitAmps<before and math.abs(e.sourceLimitAmps-29*3*1000/7200)<1e-8,'sag failed to lower current limit')
  devices.before_exit.voltage=function() return 70000 end
  e=api.stageCurrentEstimate()
  check(e.sourceLimitAmps<=before+1e-8,'output spike raised current ceiling')
end
-- Required model readings fail closed only when connecting/connected; the feature can be disabled explicitly.
do
  local api,st,devices=stageFixture({3,3,3},12)
  devices.source_gauge=nil
  local ok=pcall(api.guard)
  check(not ok and api.context().code=='stage_current_unavailable','missing source voltage not latched')
  api.config.perVariacTripAmps=0
  check(not api.stageCurrentEstimate().enabled and pcall(api.guard),'explicit stage protection disable failed')
end
-- No pre-exit gauge: use final output/exit multiplier, labelled as estimated.
do
  local api,st,devices=stageFixture({3,3,3},12)
  api.config.preStepUpGauge=''; devices.powergrid_voltage_gauge_7.voltage=function() return 2640 end
  local e=api.stageCurrentEstimate()
  check(e.available and not e.preExitVoltageMeasured and math.abs(e.sourceLimitAmps-12.76)<1e-8,'pre-exit fallback incorrect')
end
-- Managed estimated stage overcurrent opens/latches and reports its stage to the master.
do
  local c=copy(config); c.masterId=9; c.sourceGauge='source_gauge'; c.sourceCurrentGauge='current_gauge'
  local st,load,devices=fixture(c); st.concurrent=true
  devices.source_gauge={voltage=function() return 7200 end}
  devices.current_gauge={current=function() return 100 end}
  local sequence=0; local report; local latched=false
  st.onSend=function(m)
    if m.type=='status' then
      if m.faultDetails and m.faultDetails.code=='stage_overcurrent_estimate' then latched=true end
      sequence=sequence+1
      st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=sequence,sentAt=st.time*1000,
        enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000}}
    elseif m.type=='fault' and m.code=='stage_overcurrent_estimate' then report=m end
  end
  st.onSleep=function() if latched then error('Stopped by user',0) end end
  load(false)
  check(report and report.stage>=1 and report.stage<=3 and report.perVariacCurrentEstimate>29 and report.perVariacLimitAmps==29,'master estimated stage trip report')
  check(latched and not st.closed[1] and not st.closed[2],'estimated stage trip did not latch open')
end

local function thermalFixture(previous)
  local c=copy(config); c.protectionMode='temperature'
  local st,load,devices=fixture(c,previous)
  return st,load,devices,c
end
-- Every member is checked, including secondary members of a shared drive.
for _,reading in ipairs({{available=true,unit='C',temperature=140},
  {available=false,unit='C',reason='initializing'},
  {available=false,unit='C',reason='disabled_or_unavailable'},
  {available=true,unit='K',temperature=100},
  {available=true,unit='C',temperature=0/0}}) do
  local st,load,devices=thermalFixture()
  devices.extra_variac.getThermalStatus=function() return reading end
  local api=load(true)
  check(not pcall(api.initialise),'unsafe thermal initialization accepted')
  check(not st.closed[1] and not st.closed[2] and #st.moves==0,'thermal startup failed open')
  check(api.context().stage==1 and api.context().member=='extra_variac','thermal fault member attribution')
end
-- Continuous hot duration, cooling reset and hard-trip reset remain independent.
do
  local st,load,devices=thermalFixture(); local temperature=126
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=temperature} end
  local api=load(true); api.initialise()
  for i=1,49 do st.time=i/10; check(pcall(api.thermalPoll,true),'grace ended early') end
  st.time=5
  check(not pcall(api.thermalPoll,true) and api.context().code=='thermal_hot_timeout','five second timeout missed')
  check(not api.thermalReset(),'hot reset accepted')
  temperature=125; st.time=5.1
  check(api.thermalReset(),'cooled reset rejected')
  check(api.thermalStatus().fault==nil,'reset retained thermal latch')
  temperature=140; st.time=5.2
  check(not pcall(api.thermalPoll,true) and api.context().code=='thermal_overtemperature','140 C grace incorrectly applied')
end
-- Restart preserves a hot timer and a latched fault, without restoring old samples.
do
  local st,load,devices=thermalFixture()
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=130} end
  local api=load(true); api.initialise()
  local restarted,reload,newDevices=thermalFixture(st.files); restarted.time=5
  newDevices.extra_variac.getThermalStatus=devices.extra_variac.getThermalStatus
  local nextApi=reload(true)
  check(not pcall(nextApi.initialise) and nextApi.context().code=='thermal_hot_timeout','restart erased hot timer')
  local cold,coldLoad=thermalFixture(restarted.files); cold.time=6
  local coldApi=coldLoad(true)
  check(not pcall(coldApi.initialise),'cold restart cleared latch')
  cold.time=6.1; check(coldApi.thermalReset(),'fresh cold reset failed after restart')
  check(not cold.closed[1] and not cold.closed[2],'reset closed breakers')
  local command,commandLoad=thermalFixture(restarted.files); command.time=7
  check(pcall(commandLoad,false,'reset_thermal'),'standalone reset command failed')
  check(not command.closed[1] and not command.closed[2] and #command.moves==0,'reset command operated plant')
end
-- Sampling gaps are rejected before replacing stale data with a new sample.
do
  local st,load=thermalFixture(); local api=load(true); api.initialise(); st.time=1.01
  check(not pcall(api.thermalPoll,true) and api.context().code=='thermal_reading_unavailable','sampling gap hidden')
end
-- Legacy stage estimates remain diagnostic in temperature mode.
do
  local api,st,devices=stageFixture({3,3,3},100)
  api.config.protectionMode='temperature'
  check(pcall(api.guard),'legacy current estimate still enforced in temperature mode')
  api.config.sourceCurrentTripAmps=12
  check(not pcall(api.guard),'independent source current trip disabled')
end
-- Full managed control path opens both breakers and reports a thermal fault.
do
  local st,load,devices,c=thermalFixture(); c.masterId=9; st.concurrent=true
  local temperature=100; local report; local latched=false; local sequence=0
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=temperature} end
  st.onSend=function(m)
    if m.type=='status' then
      if m.phase=='live' then temperature=140 end
      if m.faultDetails and m.faultDetails.code=='thermal_overtemperature' then latched=true end
      sequence=sequence+1
      st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=sequence,sentAt=st.time*1000,
        enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000}}
    elseif m.type=='fault' and m.code=='thermal_overtemperature' then report=m end
  end
  st.onSleep=function() if latched then error('Stopped by user',0) end end
  load(false)
  check(report and report.stage==1 and report.member=='extra_variac' and report.temperatureC==140,'master thermal report missing')
  check(latched and not st.closed[1] and not st.closed[2],'live thermal fault failed to latch open')
end

-- Managed reset rejects enabled/hot members, then accepts fresh cool readings.
do
  local st,load,devices,c=thermalFixture(); c.masterId=9
  local temperature=130
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=temperature} end
  local api=load(true); api.initialise(); local net,session=api.network()
  st.onSleep=function() error('test complete',0) end
  local function reset(seq)
    st.inbox={{schema=1,type='reset',node=3,session=session,seq=seq,sentAt=st.time*1000}}
    pcall(api.receiver); return st.sent[#st.sent]
  end
  net.enabled=true; check(not reset(1).accepted,'enabled reset accepted')
  net.enabled=false; check(not reset(2).accepted and not net.reset,'hot managed reset accepted')
  temperature=125; st.time=st.time+.1
  check(reset(3).accepted and net.reset and not net.enabled,'cool managed reset failed')
  local status=api.statusMessage()
  check(status.thermal.enabled and #status.thermal.members==4 and status.thermal.members[2].temperatureC==125,'thermal status omitted member')
end
-- A missing API and damaged checkpoint never permit startup; explicit local reset can recover the latter.
do
  local st,load,devices=thermalFixture(); devices.extra_variac.getThermalStatus=nil
  local api=load(true)
  check(not pcall(api.initialise) and api.context().code=='thermal_reading_unavailable','missing API accepted')
  local bad,badLoad=thermalFixture({['transformer-thermal-state.json']='invalid'})
  check(not pcall(badLoad(true).initialise),'corrupt checkpoint accepted')
  check(pcall(badLoad,false,'reset_thermal') and not bad.closed[1] and not bad.closed[2],'checkpoint recovery failed')
end

-- Native readings expose curve credits to the master and retain them through local reset/restart.
do
  local st,load,devices=thermalFixture(); local temperature=100
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=temperature} end
  local api=load(true); api.initialise()
  temperature=136; st.time=.05; api.thermalPoll(true)
  temperature=135; st.time=.10; api.thermalPoll(true)
  st.time=.35; api.thermalPoll(true)
  local t=api.statusMessage().thermal
  check(t.curve[2].seconds==2 and t.coolSeconds==5,'master curve parameters missing')
  check(t.members[2].recoveryUsed['135'] and math.abs(t.members[2].exposure-.125)<1e-7,'native cooling credit not reported')
  temperature=125; st.time=.45; api.thermalPoll(true)
  local restarted,reload=thermalFixture(st.files); restarted.time=1
  reload(false,'reset_thermal')
  local afterReset=reload(true); afterReset.initialise()
  check(afterReset.thermalStatus().members[2].recoveryUsed['135'],'local reset/restart replenished recovery credit')
  check(#restarted.moves==0 and not restarted.closed[1] and not restarted.closed[2],'reset moved or connected plant')
end
-- The full live controller trips on the shorter 130 C curve deadline.
do
  local st,load,devices,c=thermalFixture(); c.masterId=9; st.concurrent=true
  local temperature=100; local hotAt; local report; local latched=false; local sequence=0
  devices.extra_variac.getThermalStatus=function() return {available=true,unit='C',temperature=temperature} end
  st.onSend=function(m)
    if m.type=='status' then
      if m.phase=='live' and not hotAt then hotAt=st.time; temperature=130 end
      if m.faultDetails and m.faultDetails.code=='thermal_hot_timeout' then latched=true end
      sequence=sequence+1
      st.inbox[#st.inbox+1]={schema=1,type='dispatch',node=3,session=m.session,seq=sequence,sentAt=st.time*1000,
        enabled=true,grid={voltage=2640,healthy=true,sampledAt=st.time*1000}}
    elseif m.type=='fault' and m.code=='thermal_hot_timeout' then report=m; report.elapsed=st.time-hotAt end
  end
  st.onSleep=function() if latched then error('Stopped by user',0) end end
  load(false)
  check(report and report.elapsed>=2 and report.elapsed<2.25 and report.exposure>=1-1e-9,'live inverse-time trip deadline/report failed')
  check(report.stage==1 and report.member=='extra_variac' and not st.closed[1] and not st.closed[2],'live curve fault did not isolate bank')
end
-- Local maintenance / emergency latch and persisted settings.
do
  local c=copy(config); c.inputBreakers={'input_1','input_2'}
  local st,load,devices=fixture(c)
  local contacts={true,true}; local attempts={0,0}
  for i=1,2 do devices['input_'..i]={open=function() attempts[i]=attempts[i]+1; contacts[i]=false end,
    close=function() contacts[i]=true end,isClosed=function() return contacts[i] end,
    getStatus=function() return {closed=contacts[i],canClose=true} end} end
  local api=load(true); api.initialise()
  local before=st.closed[1]
  check(not pcall(api.uiAction,{kind='setting',key='stepUp',value='3'}),'live wiring edit allowed')
  check(st.closed[1]==before and contacts[1],'rejected edit operated breaker')
  api.uiAction({kind='setting',key='target',value='2600'})
  check(st.saved.target==2600 and api.statusMessage().nominalTarget==2600 and api.config.target==2640,'live target changed active setpoint abruptly')
  api.uiAction({kind='maintenance'})
  local m=api.statusMessage().maintenance
  check(m.active and m.verified and m.drivesIdle and not contacts[1] and not contacts[2],'maintenance isolation')
  check(not st.closed[1] and not st.closed[2],'maintenance output isolation')
  api.uiAction({kind='resume'})
  check(not api.statusMessage().maintenance.active and not contacts[1],'resume closed inputs directly')
  api.energizeInputs(); check(contacts[1] and contacts[2] and not st.closed[1],'input startup order')
  -- A failed first input cannot prevent an opening attempt on the other input.
  devices.input_1.open=function() attempts[1]=attempts[1]+1; error('jammed') end
  api.uiAction({kind='emergency'})
  check(api.statusMessage().emergencyStopped and not api.statusMessage().maintenance.verified,'emergency failure incorrectly verified')
  check(attempts[2]>=3 and not contacts[2],'failed breaker blocked remaining emergency opens')
  check(not st.closed[1] and not st.closed[2],'emergency outputs stayed closed')
  check(not pcall(api.uiAction,{kind='resume'}),'reset accepted failed contact')
  local _,reload=fixture(c,st.files); local restarted=reload(true)
  check(not pcall(restarted.initialise),'restart ignored emergency latch')
  check(restarted.statusMessage().emergencyStopped,'emergency state lost on restart')
  devices.input_1.open=function() contacts[1]=false end
  api.uiAction({kind='resume'})
  check(not api.statusMessage().emergencyStopped,'local reset did not clear emergency')
  api.uiAction({kind='maintenance'})
  api.uiAction({kind='setting',key='entryRatio',value='5'})
  check(st.saved.entryRatio==5 and st.saved.target==2600,'maintenance save lost nominal target')
  local view=api.uiSnapshot()
  check(view.stages[1].members[1].temperature==100 and view.sparkGapVolts==7500,'UI telemetry missing')
end
-- Enter preserves prior settings, including temporarily disconnected mappings.
do
  local c=copy(config); c.target=2500; c.entryRatio=5; c.uiEnabled=false
  c.inputBreakers={'offline_input'}; c.sourceGauge='offline_source'
  local st,load=fixture(c)
  load(false,'configure')
  check(st.saved.target==2500 and st.saved.entryRatio==5 and not st.saved.uiEnabled,'wizard discarded saved settings')
  check(st.saved.inputBreakers[1]=='offline_input' and st.saved.sourceGauge=='offline_source','wizard discarded offline mappings')
  check(#st.moves==0 and st.closed[1] and st.closed[2],'configuration operated hardware')
end
do
  local st,load=fixture(config)
  load(false,'emergency')
  check(not st.closed[1] and not st.closed[2],'shell emergency failed to open outputs')
  local again,reload=fixture(config,st.files)
  reload(false,'resume')
  check(not again.closed[1] and not again.closed[2] and #again.moves==0,'shell reset moved/closed hardware')
end
-- Repeated Resume while running is a harmless status message, not an error.
do
  local st,load=fixture(config); local api=load(true); api.initialise()
  st.closed[1]=true; st.closed[2]=true
  check(pcall(api.uiAction,{kind='resume'}),'running Resume raised an assertion')
  check(st.closed[1] and st.closed[2] and #st.moves==0,'running Resume disturbed hardware')
  check(api.uiSnapshot().message=='Transformer is already running.','running Resume status missing')
end
-- Display polling must not duplicate the active thermal protection scan or
-- build a full network report with repeated position reads.
do
  local c=copy(config); c.protectionMode='temperature'
  local st,load,devices=fixture(c); local api=load(true); api.initialise()
  local positions,temperatures,opens=0,0,0
  for _,name in ipairs({'powergrid:variac_1','extra_variac','powergrid:variac_2','powergrid:variac_4'}) do
    local device=devices[name]; local originalStatus,originalThermal=device.getStatus,device.getThermalStatus
    device.getStatus=function() positions=positions+1; return originalStatus() end
    device.getThermalStatus=function() temperatures=temperatures+1; return originalThermal() end
  end
  local view=api.uiSnapshot()
  check(positions==4,'display read member positions more than once')
  check(temperatures==0 and view.stages[1].members[1].temperature==100,'display duplicated thermal protection polling')
  for i=1,2 do
    local device=devices['powergrid:hv_breaker_'..(i+1)]; local original=device.open
    device.open=function() opens=opens+1; original() end
  end
  api.maintainIsolation(); api.maintainIsolation()
  check(opens==0,'maintenance repeatedly commanded already-open contacts')
  st.closed[2]=true; api.maintainIsolation()
  check(opens==1 and not st.closed[2],'maintenance failed to reopen unexpected closed contact')
  st.time=st.time+10
  check(api.uiSnapshot().stages[1].members[1].temperature==nil,'display presented stale protection temperature as current')
end
-- A moving bank cannot bypass alignment protection, and input closure must
-- use every member's actual position rather than the primary alone.
do
  local st,load=fixture(config); local api=load(true); api.initialise()
  st.closed[1]=true; st.closed[2]=true; api.setLive(); api.setMoving(1,true)
  st.positions[1][2]=.7
  local ok,reason=pcall(api.guard)
  check(not ok and tostring(reason):find('BANK_MISALIGNED: 1',1,true),'moving bank bypassed alignment protection')
  api.isolateAll()
  ok,reason=pcall(api.energizeInputs)
  check(not ok and not st.inputClosed,'misaligned bank energized before alignment')
end
-- No configured input isolation means no automatic energized endpoint sync.
do
  local c=copy(config); c.inputBreakers={}
  local st,load=fixture(c); local api=load(true); api.initialise(); st.positions[1][2]=.5
  local ok=pcall(api.syncBank,1)
  check(not ok and #st.moves==0 and api.context().code=='bank_sync_requires_input_isolation','sync ran without input isolation')
end
-- A jammed input contact must prevent all homing movement.
do
  local st,load,devices=fixture(config); local api=load(true); api.initialise()
  devices.input_isolator.open=function() end
  st.positions[1][2]=.5
  check(not pcall(api.syncBank,1) and #st.moves==0,'sync ran with input stuck closed')
end
-- Readings may be zero behind open input isolation. Startup must home first,
-- then energize; every closing attempt must observe all banks aligned.
do
  local st,load,devices=fixture(config); st.positions[1][2]=.5
  local input=devices.powergrid_voltage_gauge_6.voltage
  devices.powergrid_voltage_gauge_6.voltage=function() return st.inputClosed and input() or 0 end
  local output=devices.powergrid_voltage_gauge_7.voltage
  devices.powergrid_voltage_gauge_7.voltage=function() return st.inputClosed and output() or 0 end
  local closes=0
  devices.input_isolator.close=function()
    check(math.abs(st.positions[1][1]-st.positions[1][2])*315<=1,'input closed on mismatched bank')
    closes=closes+1; st.inputClosed=true
  end
  st.onSleep=function() if st.closed[1] and st.closed[2] then error('Stopped by user',0) end end
  load(false)
  check(closes==1,'isolated zero-voltage startup never energized')
  local homed=false
  for _,move in ipairs(st.moves) do if move.n==318 then homed=true; check(move.inputOpen and move.open,'homing supplied electrically') end end
  check(homed and not st.inputClosed,'homing or final isolation failed')
end
-- Interrupting a native temperature read discards its coroutine cleanup when
-- the controller transitions into homing. The next group must resume sampling.
do
  local st,load,devices=thermalFixture(); local api=load(true); api.initialise()
  local original=devices.extra_variac.getThermalStatus
  local reads=0
  devices.extra_variac.getThermalStatus=function() reads=reads+1; coroutine.yield('native_read'); return original() end
  st.time=.1
  local abandoned=coroutine.create(function() api.thermalPoll(true) end)
  local ok,wait=coroutine.resume(abandoned)
  check(ok and wait=='native_read','temperature scan did not suspend')
  -- Model waitForAny cancelling that worker during a bank-misalignment trip.
  api.cancelThermalSampling(); api.isolateAll(); api.setHoming()
  devices.extra_variac.getThermalStatus=function() reads=reads+1; return original() end
  st.time=.2
  check(pcall(api.thermalPoll,true) and reads==2,'abandoned thermal lock prevented homing scan')
  st.time=2
  check(not pcall(api.thermalPoll,true),'real stale gap lost protection')
  check(api.thermalReset(),'fresh cool reset failed after stale fault')
end
-- A second protection task must not latch an unvisited member as missing
-- while a timely first scan is still reading native peripherals.
do
  local st,load,devices=thermalFixture(); local api=load(true)
  local original=devices.extra_variac.getThermalStatus
  devices.extra_variac.getThermalStatus=function() coroutine.yield('native_read'); return original() end
  local worker=coroutine.create(function() api.thermalPoll(true) end)
  local ok,wait=coroutine.resume(worker)
  check(ok and wait=='native_read','initial scan did not suspend')
  st.time=.1
  check(pcall(api.thermalPoll,true),'partial initial scan falsely latched missing readings')
  check(coroutine.resume(worker),'initial scan failed after concurrent guard')
  check(not api.thermalStatus().fault,'initial scan persisted false fault')
end
-- A permanently blocked initial scan still fails at its freshness deadline.
do
  local st,load,devices=thermalFixture(); local api=load(true)
  devices.extra_variac.getThermalStatus=function() coroutine.yield('native_read') end
  local worker=coroutine.create(function() api.thermalPoll(true) end)
  check(coroutine.resume(worker),'blocked scan setup failed')
  st.time=2
  check(not pcall(api.thermalPoll,true),'blocked first scan bypassed watchdog')
  api.cancelThermalSampling()
end
print(('PASS: %d checks'):format(count))
