-- Pure plant supervision state; runtime supplies samples, clocks and transport.
local M={}
M.REGULATOR='powerplant.regulator.v1'
M.NETWORK='powerplant.controller.v1'
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
M.finite=finite
local function copy(v)
  if type(v)~='table' then return v end
  local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
function M.buses(c)
  local out={{id='local',name='Local plant',voltageGauge=c.voltageGauge,currentGauge=c.currentGauge,
    nominalVoltage=c.nominalVoltage,gridMinVoltage=c.gridMinVoltage,gridMaxVoltage=c.gridMaxVoltage,currentLimitAmps=c.currentLimitAmps}}
  for _,b in ipairs(c.buses or {}) do out[#out+1]=b end
  return out
end
function M.validate(c)
  assert(type(c)=='table' and (c.version==1 or c.version==2),'Unsupported controller configuration')
  for _,key in ipairs({'monitor','modem','voltageGauge'}) do assert(type(c[key])=='string' and c[key]~='','Missing '..key) end
  assert(type(c.currentGauge)=='string','Invalid current gauge')
  assert(c.currentGauge=='' or c.currentGauge~=c.voltageGauge,'Voltage/current gauges must be distinct')
  for _,key in ipairs({'nominalVoltage','gridMinVoltage','gridMaxVoltage','sampleMaxAgeMs','nodeTimeoutMs'}) do
    assert(finite(c[key]) and c[key]>0,'Invalid '..key)
  end
  assert(c.gridMinVoltage<c.nominalVoltage and c.gridMaxVoltage>c.nominalVoltage,'Grid range must surround nominal voltage')
  assert(c.sampleMaxAgeMs<=1500 and c.nodeTimeoutMs<=2500,'Freshness limits exceed regulator lease margins')
  assert(finite(c.currentLimitAmps) and c.currentLimitAmps>=0,'Invalid current limit')
  assert(c.currentLimitAmps==0 or c.currentGauge~='','Current limit requires a gauge')
  assert(type(c.transmission)=='table' and type(c.transmission.inputGauge)=='string' and type(c.transmission.outputGauge)=='string','Invalid transmission measurement configuration')
  assert(finite(c.transmission.ratio) and c.transmission.ratio>=0,'Invalid transmission output/input ratio')
  assert(c.transmission.inputGauge=='' or c.transmission.inputGauge~=c.transmission.outputGauge,'Transmission gauges must be distinct')
  local seen={}
  for _,key in ipairs({'transformers','generators'}) do
    assert(type(c[key])=='table','Missing '..key)
    for _,n in ipairs(c[key]) do
      assert(type(n)=='table' and finite(n.id) and n.id>=0 and n.id%1==0 and not seen[n.id],'Invalid/duplicate node ID')
      assert(type(n.name)=='string' and #n.name>0,'Missing node label')
      seen[n.id]=true
    end
  end
  c.buses=c.buses or {}
  local busIds={}
  for _,b in ipairs(M.buses(c)) do
    assert(type(b.id)=='string' and b.id~='' and not busIds[b.id],'Invalid/duplicate bus ID')
    busIds[b.id]=true
    assert(type(b.name)=='string' and type(b.voltageGauge)=='string' and b.voltageGauge~='' and type(b.currentGauge)=='string','Invalid bus gauges/label')
    assert(finite(b.nominalVoltage) and finite(b.gridMinVoltage) and finite(b.gridMaxVoltage)
      and b.gridMinVoltage>0 and b.gridMinVoltage<b.nominalVoltage and b.gridMaxVoltage>b.nominalVoltage,'Invalid bus voltage limits')
    assert(finite(b.currentLimitAmps) and b.currentLimitAmps>=0 and (b.currentLimitAmps==0 or b.currentGauge~=''),'Invalid bus current limit')
  end
  for _,n in ipairs(c.transformers) do
    n.role=n.role or 'generator'; n.bus=n.bus or 'local'; n.generatorId=n.generatorId or -1
    n.connectionMode=n.connectionMode or 'parallel'; n.deadBusVolts=n.deadBusVolts or 5
    assert(n.connectionMode=='parallel' or n.connectionMode=='supply','Invalid transformer connection mode')
    assert(finite(n.deadBusVolts) and n.deadBusVolts>=0,'Invalid dead bus threshold')
    assert(n.role=='generator' or n.role=='consumer' or n.role=='transmission','Unknown transformer role')
    assert(busIds[n.bus],'Unknown transformer output bus')
    local found=n.generatorId==-1
    for _,g in ipairs(c.generators) do if n.generatorId==g.id then found=true end end
    assert(found,'Generator association must name a configured generator')
  end
  for _,n in ipairs(c.transformers) do
    if n.connectionMode=='supply' then
      for _,other in ipairs(c.transformers) do assert(n==other or other.bus~=n.bus,'Supply transformer must exclusively own its output bus') end
      for _,b in ipairs(M.buses(c)) do if b.id==n.bus then assert(n.deadBusVolts<b.gridMinVoltage,'Dead bus threshold overlaps healthy bus range') end end
    end
  end
  assert(#c.transformers>0,'Configure at least one transformer')
  assert(finite(c.upstreamId) and c.upstreamId%1==0 and c.upstreamId>=-1 and not seen[c.upstreamId],'Invalid/conflicting upstream ID')
  return c
end
function M.new(config,nodeId,session,send)
  local c=M.validate(config)
  assert(c.upstreamId~=nodeId,'Upstream cannot be this computer')
  for _,list in ipairs({c.transformers,c.generators}) do for _,entry in ipairs(list) do assert(entry.id~=nodeId,'Remote node cannot be this computer') end end
  local nodes,ordered,generators={},{},{}
  for _,entry in ipairs(c.transformers) do
    local n={id=entry.id,name=entry.name,role=entry.role,bus=entry.bus,generatorId=entry.generatorId,connectionMode=entry.connectionMode,deadBusVolts=entry.deadBusVolts,desired=false,seq=0,retired={}}
    nodes[n.id]=n; ordered[#ordered+1]=n
  end
  for _,entry in ipairs(c.generators) do generators[entry.id]={id=entry.id,name=entry.name,available=false} end
  local grid={available=false,healthy=false,reason='Waiting for grid measurement'}
  local current={configured=c.currentGauge~='',available=false}
  local transmission={configured=c.transmission.inputGauge~='' or c.transmission.outputGauge~='',
    ratio=c.transmission.ratio>0 and c.transmission.ratio or nil,input={available=false},output={available=false}}
  local busConfigs,busReadings={},{}
  for _,b in ipairs(M.buses(c)) do busConfigs[b.id]=b; busReadings[b.id]={grid={available=false,healthy=false,reason='Waiting for bus measurement'},current={configured=b.currentGauge~='',available=false}} end
  local upstreamSeq=-1
  local api={nodes=ordered,generators=generators}
  local function fresh(time,now,age) return finite(time) and time<=now+250 and now-time<=age end
  local function online(n,now) return n.status and fresh(n.receivedAt,now,c.nodeTimeoutMs) and fresh(n.status.sentAt,now,c.nodeTimeoutMs) end
  local function command(n,kind,now,extra)
    if not n.session then return end
    n.seq=n.seq+1
    local m={schema=1,type=kind,node=n.id,session=n.session,seq=n.seq,sentAt=now}
    for k,v in pairs(extra or {}) do m[k]=copy(v) end
    local ok,result=pcall(send,n.id,m,M.REGULATOR)
    if not ok or result==false then n.notice='Send failed; contact state unconfirmed' end
    return n.seq
  end
  function api.measureBus(id,voltage,amps,now)
    local b=assert(busConfigs[id],'Unknown bus')
    local g={available=finite(voltage),voltage=finite(voltage) and voltage or nil,sampledAt=now}
    local i={configured=b.currentGauge~='',available=b.currentGauge~='' and finite(amps),
      amps=b.currentGauge~='' and finite(amps) and amps or nil,sampledAt=now}
    g.healthy=g.available and voltage>=b.gridMinVoltage and voltage<=b.gridMaxVoltage
    g.reason=not g.available and 'Bus voltage unavailable' or not g.healthy and 'Bus voltage outside configured range' or nil
    if b.currentLimitAmps>0 and (not i.available or math.abs(amps)>b.currentLimitAmps) then
      g.healthy=false; g.reason=not i.available and 'Required current reading unavailable' or 'Bus current exceeds limit'
    end
    busReadings[id]={grid=g,current=i}
    if id=='local' then grid=g; current=i end
  end
  function api.measure(voltage,amps,now) api.measureBus('local',voltage,amps,now) end
  function api.measureTransmission(input,output,now)
    transmission.input={configured=c.transmission.inputGauge~='',available=c.transmission.inputGauge~='' and finite(input),
      volts=c.transmission.inputGauge~='' and finite(input) and input or nil,sampledAt=now}
    transmission.output={configured=c.transmission.outputGauge~='',available=c.transmission.outputGauge~='' and finite(output),
      volts=c.transmission.outputGauge~='' and finite(output) and output or nil,sampledAt=now}
  end
  function api.health(now,id)
    local reading=busReadings[id or 'local'].grid
    local result=copy(reading)
    if not fresh(reading.sampledAt,now,c.sampleMaxAgeMs) then result.available=false; result.healthy=false; result.reason='Grid sample stale' end
    return result
  end
  local function nodeHealth(n,now)
    local g=api.health(now,n.bus)
    if n.connectionMode=='supply' and g.available and g.voltage>=0 and g.voltage<=n.deadBusVolts then
      local b=busConfigs[n.bus]; local i=busReadings[n.bus].current
      if b.currentLimitAmps==0 or (i.available and fresh(i.sampledAt,now,c.sampleMaxAgeMs) and math.abs(i.amps)<=b.currentLimitAmps) then
        g.healthy=true; g.reason=nil; g.energizingDeadBus=true
      end
    end
    return g
  end
  local function upstream(m,now)
    local reason
    if m.session~=session then reason='Wrong main-controller session'
    elseif not finite(m.seq) or m.seq%1~=0 or m.seq<=upstreamSeq or m.seq>=9007199254740000 then reason='Old/invalid upstream sequence'
    elseif m.type=='shutdown_prepare' or m.type=='generator_transition' then
      if m.type=='generator_transition' and m.direction~='connect' and m.direction~='disconnect' then reason='Generator transition direction must be connect or disconnect' end
      if reason or not generators[m.generator] or type(m.eventId)~='string' or #m.eventId==0 or #m.eventId>80
        or not finite(m.expiresAt) or m.expiresAt<=now or m.expiresAt-now>30000
        or type(m.targets)~='table' or #m.targets==0 then reason='Generator, event, deadline and explicit targets required'
      else
        local seen={}
        for _,t in ipairs(m.targets) do
          local n=type(t)=='table' and nodes[t.node]
          local cap=n and n.status and n.status.remoteControl
          if not n or seen[t.node] or not online(n,now) or not n.desired or n.status.phase~='live'
            or n.status.fault or not nodeHealth(n,now).healthy or not cap or not cap.enabled
            or not finite(t.voltage) or not finite(cap.minTarget) or not finite(cap.maxTarget)
            or t.voltage<cap.minTarget or t.voltage>cap.maxTarget
            or t.voltage<busConfigs[n.bus].gridMinVoltage or t.voltage>busConfigs[n.bus].gridMaxVoltage then
            reason='Target node offline, not live/enabled, or target outside permitted bus/regulator range'; break
          end
          if n.transition and (n.transition.id~=m.eventId or n.transition.generator~=m.generator) and n.transition.expiresAt>now then reason='Conflicting shutdown preparation'; break end
          seen[t.node]=true
        end
        if not reason then
          -- Validate the entire request before modifying any transformer.
          for _,n in ipairs(ordered) do if n.transition and n.transition.id==m.eventId then n.transition=nil end end
          for _,t in ipairs(m.targets) do
            local n=nodes[t.node]; n.intent=true; n.supervising=true
            n.transition={id=m.eventId,generator=m.generator,targetVolts=t.voltage,expiresAt=m.expiresAt,
              direction=m.direction or 'disconnect'}
            n.notice='Generator '..(m.direction or 'disconnect')..' preparation: target '..t.voltage..' V'
          end
        end
      end
    elseif m.type=='shutdown_cancel' or m.type=='shutdown_complete' then
      if type(m.eventId)~='string' then reason='Event ID required' else
        for _,n in ipairs(ordered) do if n.transition and n.transition.id==m.eventId then n.transition=nil; n.notice='Returning toward configured target' end end
      end
    elseif m.type=='generator_isolate' then
      if not generators[m.generator] then reason='Unknown generator' else
        local found=false
        for _,n in ipairs(ordered) do if n.generatorId==m.generator then found=true; api.action(n.id,'disable',now) end end
        if not found then reason='No associated generator transformers configured' end
      end
    elseif m.type=='generator_command' then
      local g=generators[m.generator]
      if not g or not g.available or not fresh(g.sampledAt,now,c.sampleMaxAgeMs)
        or type(g.controlSession)~='string' or not g.supportedCommands or g.supportedCommands[m.command]~=true
        or (m.command~='start' and m.command~='stop') then reason='Generator unavailable or command capability not advertised'
      elseif m.command=='stop' then
        local found=false
        for _,n in ipairs(ordered) do if n.generatorId==m.generator then
          found=true; local b=n.status and n.status.breakers or {}
          if n.desired or not online(n,now) or not n.disableSeq or n.status.lastSeq<n.disableSeq
            or n.status.sentAt<n.disableAt or n.status.enabled or not b[1] or not b[2]
            or b[1].closed~=false or b[2].closed~=false then reason='Isolate generator transformers and verify both contacts first' end
        end end
        if not found then reason='No associated generator transformers configured' end
      end
      if not reason then
        g.commandSeq=(g.commandSeq or 0)+1
        local ok,result=pcall(send,g.id,{schema=1,type='generator_command',node=g.id,session=g.controlSession,
          seq=g.commandSeq,sentAt=now,command=m.command},M.NETWORK)
        if not ok or result==false then reason='Generator command delivery failed' else g.commandPending={seq=g.commandSeq,command=m.command,sentAt=now} end
      end
    else reason='Unknown upstream command' end
    if not reason then upstreamSeq=m.seq end
    pcall(send,c.upstreamId,{schema=1,type='upstream_ack',node=nodeId,session=session,sentAt=now,
      seq=m.seq,accepted=not reason,reason=reason},M.NETWORK)
    return not reason
  end
  function api.receive(sender,m,protocol,now)
    if type(m)~='table' or m.schema~=1 or m.node~=sender or not fresh(m.sentAt,now,c.nodeTimeoutMs) then return false end
    if protocol==M.NETWORK then
      if sender==c.upstreamId then return upstream(m,now) end
      local g=generators[sender]
      if g and m.type=='generator_ack' then
        if m.session~=g.controlSession or not g.commandPending or m.seq~=g.commandPending.seq or type(m.accepted)~='boolean' then return false end
        g.commandAck=copy(m); if not m.accepted then g.commandPending=nil end
        return true
      end
      local pair=type(m.measurements)=='table' and m.measurements or {}
      local volts=m.voltage~=nil and m.voltage or pair[1]
      local amps=m.current~=nil and m.current or pair[2]
      if (m.voltage~=nil and pair[1]~=nil and m.voltage~=pair[1]) or (m.current~=nil and pair[2]~=nil and m.current~=pair[2]) then return false end
      if not g or m.type~='generator_status' or not fresh(m.sampledAt,now,c.sampleMaxAgeMs)
        or not finite(volts) or not finite(amps) or (g.sentAt and m.sentAt<=g.sentAt) then return false end
      if (m.maxPowerWatts~=nil or m.currentPowerWatts~=nil) and (not finite(m.maxPowerWatts) or m.maxPowerWatts<0 or not finite(m.currentPowerWatts)) then return false end
      if m.controlSession~=nil and (type(m.controlSession)~='string' or not finite(m.lastCommandSeq) or m.lastCommandSeq%1~=0 or m.lastCommandSeq< -1 or m.lastCommandSeq>=9007199254740000) then return false end
      if g.controlSession~=m.controlSession then g.commandSeq=0; g.commandPending=nil; g.commandAck=nil end
      g.controlSession=m.controlSession
      g.commandSeq=math.max(g.commandSeq or 0,m.lastCommandSeq or 0)
      g.supportedCommands=type(m.supportedCommands)=='table' and {start=m.supportedCommands.start==true,stop=m.supportedCommands.stop==true} or nil
      g.running=type(m.running)=='boolean' and m.running or nil
      if m.running==false then g.running=false end
      if g.commandPending and m.lastCommandSeq and m.lastCommandSeq>=g.commandPending.seq and m.running==(g.commandPending.command=='start') then g.commandPending=nil end
      g.maxPowerWatts=m.maxPowerWatts; g.currentPowerWatts=m.currentPowerWatts
      g.voltage=volts; g.current=amps; g.sampledAt=m.sampledAt; g.sentAt=m.sentAt; g.available=true
      return true
    end
    local n=nodes[sender]
    if protocol~=M.REGULATOR or not n or type(m.session)~='string' or m.session=='standalone' then return false end
    if m.type=='status' then
      if not finite(m.lastSeq) or m.lastSeq%1~=0 or m.lastSeq< -1 or m.lastSeq>=9007199254740000
        or type(m.phase)~='string' or type(m.enabled)~='boolean' then return false end
      if n.retired[m.session] or (n.status and m.sentAt<=n.status.sentAt) then return false end
      if n.session~=m.session then
        if n.session then n.retired[n.session]=true end
        n.session=m.session; n.autonomous=m.autonomousFallback==true
        if n.intent~=false then n.intent=nil end; n.supervising=false
        n.desired=n.autonomous and n.intent~=false and m.enabled or false
        n.reset=nil; n.seq=0; n.transition=nil; n.disableSeq=nil; n.disableAt=nil
        n.notice=n.autonomous and 'Local regulator owns operation; supervisor observing' or 'Session discovered; disabled until operator enables'
      end
      n.seq=math.max(n.seq,m.lastSeq); n.status=copy(m); n.receivedAt=now
      if n.autonomous and n.intent==nil then n.desired=m.enabled end
      if m.fault or m.phase=='fault' or m.phase=='stopping' then n.desired=false end
      if n.reset and n.reset.seq and m.lastSeq>=n.reset.seq and not m.fault and m.phase=='standby' and not m.enabled then
        n.reset=nil; n.notice='Reset complete; enable separately'
      end
      return true
    end
    if m.session~=n.session then return false end
    if m.type=='ack' then
      if not finite(m.seq) or m.seq>n.seq or type(m.accepted)~='boolean' then return false end
      if not n.ack or m.seq>n.ack.seq then n.ack=copy(m) end
      if n.reset and m.seq==n.reset.seq and not m.accepted then n.reset=nil; n.notice='Reset rejected: '..tostring(m.reason) end
      return true
    elseif m.type=='fault' or m.type=='stopped' then
      if n.status and m.sentAt<n.status.sentAt then return false end
      -- Preserve the regulator's bounded, isolated bank-resynchronisation recovery.
      if m.type=='stopped' or m.recoverable~=true then n.desired=false end
      n.notice=tostring(m.reason or m.type); n.event=copy(m)
      return true
    end
    return false
  end
  function api.action(id,action,now)
    local n=nodes[id]; if not n then return false,'Unknown transformer' end
    if action=='disable' then
      n.intent=false; n.supervising=false
      n.desired=false; n.reset=nil; n.transition=nil; n.notice='Disable requested; verify contacts'
      n.disableAt=now; n.disableSeq=command(n,'dispatch',now,{enabled=false}); return true
    elseif action=='enable' then
      if not online(n,now) then return false,'Transformer offline' end
      local nominal=n.status.configuredTarget or n.status.nominalTarget
      local bus=busConfigs[n.bus]
      if not finite(nominal) or nominal<bus.gridMinVoltage or nominal>bus.gridMaxVoltage then return false,'Regulator nominal target does not match assigned bus range' end
      if not n.autonomous and not nodeHealth(n,now).healthy then return false,nodeHealth(n,now).reason end
      if n.connectionMode=='supply' and (n.status.connectionMode~='supply' or n.status.deadBusVolts~=n.deadBusVolts) then return false,'Regulator supply mode/dead threshold must match local configuration' end
      if (n.event and n.event.sentAt>=n.status.sentAt) or n.reset or n.status.fault or n.status.phase=='fault' or n.status.phase=='stopping' then return false,'Reset fault / wait for standby first' end
      n.intent=true; n.desired=true; n.disableSeq=nil; n.disableAt=nil; n.notice='Enable requested; contacts shown separately'
      if n.autonomous and not nodeHealth(n,now).healthy then
        command(n,'dispatch',now,{enabled=true,autonomous=true}); n.supervising=false
      end
      return true
    elseif action=='reset' then
      if not online(n,now) then return false,'Transformer offline' end
      n.intent=false; n.supervising=false; n.desired=false; n.reset={since=now}; n.notice='Waiting for disabled state and both contacts open'
      n.reset.disableSeq=command(n,'dispatch',now,{enabled=false}); return true
    end
    return false,'Unknown action'
  end
  function api.stop(now)
    for _,n in ipairs(ordered) do api.action(n.id,'disable',now) end
  end
  function api.release(now)
    for _,n in ipairs(ordered) do
      if n.autonomous then
        command(n,'release',now); n.transition=nil; n.supervising=false; n.intent=nil
      else api.action(n.id,'disable',now) end
    end
  end
  function api.tick(now)
    for _,n in ipairs(ordered) do
      local health=nodeHealth(n,now); local healthy=health.healthy
      if n.autonomous then
        -- Missing supervisory data is not a shutdown request. Confirmed local
        -- bus/commissioned current-limit violations remain explicit protection.
        if health.available and not healthy and n.supervising then
          if n.desired then api.action(n.id,'disable',now) end
        elseif (not online(n,now) or not healthy) and n.supervising then
          command(n,'release',now); n.supervising=false; n.transition=nil
        end
      elseif not online(n,now) or not healthy then
        if n.desired then n.notice=not healthy and api.health(now,n.bus).reason or 'Telemetry lost; re-enable manually' end
        n.desired=false
      end
      if not n.desired or (n.transition and n.transition.expiresAt<=now) then n.transition=nil end
      if n.reset then
        if now-n.reset.since>5000 then n.reset=nil; n.notice='Reset timed out; inspect transformer'
        elseif online(n,now) and not n.reset.seq then
          local s=n.status; local b=s.breakers or {}
          if s.lastSeq>=n.reset.disableSeq and s.sentAt>=n.reset.since and not s.enabled and b[1] and b[2] and b[1].closed==false and b[2].closed==false then
            n.reset.seq=command(n,'reset',now); n.notice='Reset sent; waiting for fault-free standby'
          end
        end
      end
      if not n.autonomous or n.intent==false or (n.intent==true and online(n,now) and healthy) then
        command(n,'dispatch',now,{enabled=n.desired,grid=n.desired and nodeHealth(n,now) or nil,transition=n.desired and n.transition or nil})
        n.supervising=n.desired
      end
    end
  end
  function api.snapshot(now)
    local out={schema=1,type='plant_status',node=nodeId,session=session,sentAt=now,lastUpstreamSeq=upstreamSeq,
      grid=api.health(now),current=copy(current),transmission=copy(transmission),buses={},transformers={},generators={}}
    for _,b in ipairs(M.buses(c)) do
      local i=copy(busReadings[b.id].current); i.available=i.available and fresh(i.sampledAt,now,c.sampleMaxAgeMs)
      out.buses[#out.buses+1]={id=b.id,name=b.name,nominalVoltage=b.nominalVoltage,grid=api.health(now,b.id),current=i}
    end
    local tx=out.transmission
    for _,r in ipairs({tx.input,tx.output}) do r.available=r.available and fresh(r.sampledAt,now,c.sampleMaxAgeMs) end
    if tx.input.available and tx.output.available and tx.input.volts>1 then tx.measuredRatio=tx.output.volts/tx.input.volts end
    if tx.input.available and tx.ratio then tx.expectedOutputVoltage=tx.input.volts*tx.ratio end
    out.current.available=current.available and fresh(current.sampledAt,now,c.sampleMaxAgeMs)
    if out.grid.available and out.current.available then out.measurements={out.grid.voltage,out.current.amps} end
    for _,n in ipairs(ordered) do
      local atTarget=false
      local s=n.status or {}; local rc=s.remoteControl or {}; local b=s.breakers or {}
      local tolerance=rc.targetToleranceVolts
      if n.transition and n.transition.expiresAt>now and online(n,now) and s.transition and s.transition.id==n.transition.id
        and (not n.autonomous or s.controlMode=='supervised') and s.phase=='live' and not s.fault and finite(tolerance) and tolerance>0
        and finite(s.outputVoltage) and finite(s.currentTarget) and b[1] and b[2] and b[1].closed and b[2].closed then
        atTarget=math.abs(s.outputVoltage-n.transition.targetVolts)<=tolerance and math.abs(s.currentTarget-n.transition.targetVolts)<=tolerance
      end
      out.transformers[#out.transformers+1]={id=n.id,name=n.name,role=n.role,bus=n.bus,generatorId=n.generatorId,connectionMode=n.connectionMode,transition=copy(n.transition),transitionAtTarget=atTarget,grid=nodeHealth(n,now),online=not not online(n,now),desired=n.desired,autonomous=n.autonomous,supervising=n.supervising,
        status=copy(n.status),notice=n.notice,resetPending=n.reset~=nil,ack=copy(n.ack),event=copy(n.event)}
    end
    for _,entry in ipairs(c.generators) do
      local g=copy(generators[entry.id]); g.available=g.available and fresh(g.sampledAt,now,c.sampleMaxAgeMs)
      g.powerAvailable=g.available and finite(g.maxPowerWatts) and finite(g.currentPowerWatts)
      if g.available then g.measurements={g.voltage,g.current} end
      out.generators[#out.generators+1]=g
    end
    return out
  end
  return api
end
return M
