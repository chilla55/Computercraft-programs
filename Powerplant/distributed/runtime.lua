local M={}
function M.new(config,node,modules,root)
  local U=modules.common
  local R={U=U,modules=modules,config=U.validate(config),node=node,role=node.role,root=root,
    peers={},commands={},updateAcks={},updatePending={},events={},eventIndex={},sequence=0}
  R.digest=modules.hash(U.canonical(config))
  R.now=function() return os.epoch('utc') end
  R.session=tostring(os.getComputerID())..':'..R.now()..':'..math.random(1,2147483647)
  local counter=0
  R.token=function() counter=counter+1; return R.session..':'..counter end
  R.state={latched=true,phase='stopped',generation=0,target=config.settings.target,events=R.events,runRequested=false}
  local saved=U.readState(config.settings)
  if saved then
    assert(type(saved)=='table' and type(saved.events)=='table','Invalid saved state')
    R.state.message=saved.recovery
    R.state.target=saved.target or R.state.target
    R.state.runRequested=saved.runRequested==true or (saved.runRequested==nil and saved.latched==false)
    R.state.realignRequested=saved.realignRequested==true
    R.bootResume=R.state.runRequested
    if not R.state.runRequested then R.state.phase=saved.phase or 'stopped'; R.state.fault=saved.fault end
    for _,event in ipairs(saved.events) do R.events[#R.events+1]=event; R.eventIndex[event.id]=true end
  end
  assert(U.finite(R.state.target) and R.state.target>0 and R.state.target/(config.settings.stepUp*.99999^3)<config.settings.maxInputVolts,'Saved target outside current configuration limits')
  function R.persist() U.write('distributed-state.json',{target=R.state.target,events=R.events,latched=R.state.latched,runRequested=R.state.runRequested,phase=R.state.phase,realignRequested=R.state.realignRequested,fault=R.state.fault}) end
  function R.send(role,kind,data)
    R.sequence=R.sequence+1
    pcall(rednet.send,config.ids[role],{schema=1,revision=config.revision,release=U.release,role=R.role,
      digest=R.digest,session=R.session,seq=R.sequence,sentAt=R.now(),kind=kind,data=data},U.protocol)
  end
  function R.publish(kind,data) for _,role in ipairs(U.roles) do if role~=R.role then R.send(role,kind,data) end end end
  function R.fresh(role)
    local p=R.peers[role]
    return p and p.release==U.release and p.dataAt and R.now()-p.dataAt<=2000 and p.data or nil
  end
  function R.updatePeer(role)
    local p=R.peers[role]
    if p and p.dataAt and R.now()-p.dataAt<=2000 then return p.data,p.release end
  end
  function R.record(event)
    assert(type(event)=='table' and type(event.id)=='string' and #event.id<=160 and type(event.reason)=='string','Invalid incident')
    if R.eventIndex[event.id] then return false end
    R.eventIndex[event.id]=true; R.events[#R.events+1]=U.copy(event)
    if #R.events>128 then local old=table.remove(R.events,1); R.eventIndex[old.id]=nil end
    -- Keep the observation, but replace its unknown label when an earlier
    -- reported open command explains it. Never infer a cause from later trips.
    for _,observed in ipairs(R.events) do
      if observed.code=='unknown_opening' and observed.observedAt and not observed.resolvedBy then
        for _,cause in ipairs(R.events) do
          if cause.code~='unknown_opening' and cause.cycle==observed.cycle and cause.commandedAt
            and cause.commandedAt<=observed.observedAt and observed.observedAt-cause.commandedAt<=2000 then
            observed.resolvedBy=cause.id; observed.resolvedCause=cause.origin..': '..cause.reason; break
          end
        end
      end
    end
    return true
  end
  function R.trip(code,reason,detail,remote)
    local requestedAt=R.now()
    local repeated=not remote and R.state.latched and R.lastLocalFault==tostring(code)..':'..tostring(reason)
    local recover=code=='bank_misaligned' and (R.state.runRequested or R.state.realignRequested) and R.state.phase~='homing'
    R.state.realignRequested=recover or false
    R.bootResume=false; R.state.runRequested=false
    R.state.latched=true; R.state.phase=code=='operator_stop' and 'maintenance' or 'tripped'; R.state.generation=R.state.generation+1; R.commands={}
    R.state.message=reason
    R.state.fault=code~='operator_stop' and reason or nil
    R.state.tripPending=code=='unknown_opening' or nil
    R.tripPendingUntil=R.state.tripPending and requestedAt+2000 or nil
    R.faultAt=requestedAt
    R.openingBreakers=(R.openingBreakers or 0)+1
    local opened,why=U.openAll(config.settings) -- No network or disk prerequisite.
    R.openingBreakers=R.openingBreakers-1
    if repeated then R.state.message=not opened and why or R.state.message; return end
    if not remote then R.lastLocalFault=tostring(code)..':'..tostring(reason) end
    local event=remote and U.copy(remote) or {id=R.token(),origin=R.role,computer=os.getComputerID(),at=R.now(),code=code,reason=reason,detail=detail,cycle=R.state.cycle}
    R.state.tripEventId=event.id
    R.state.isolationVerified=opened
    if not remote then
      event.openVerified=opened; if not opened then event.openError=why end
      if code=='unknown_opening' then event.observedAt=requestedAt else event.commandedAt=requestedAt end
    end
    if R.record(event) then R.publish('trip',event); R.persist() end
  end
  function R.clearFaults() R.state.tripPending=nil; R.state.tripEventId=nil; R.state.fault=nil; R.state.message=nil; R.state.realignRequested=false; R.bootResume=false; R.state.runRequested=true; R.lastLocalFault=nil; R.state.latched=false; R.state.generation=R.state.generation+1 end
  function R.refreshTripReason()
    if not R.state.tripPending then return end
    for _,event in ipairs(R.events) do
      if event.id==R.state.tripEventId and event.resolvedBy then
        R.state.tripPending=nil; R.state.fault=event.resolvedCause; R.persist(); return
      end
    end
    if R.now()>=(R.tripPendingUntil or 0) then
      R.state.tripPending=nil; R.state.fault='Unknown breaker opening (no controller reported a trip)'; R.persist()
    end
  end
  local nextRegistration=0
  function R.registerPlant()
    if R.role~='master' or R.now()<nextRegistration then return end
    nextRegistration=R.now()+30000
    -- Registry announcements are transport-independent and read-only. Failure
    -- of the optional plant uplink must never interrupt local heartbeats.
    local ok,why=pcall(function()
      if node.uplinkModem and not rednet.isOpen(node.uplinkModem) then rednet.open(node.uplinkModem) end
      local protection,regulation=R.fresh('protection'),R.fresh('regulation')
      rednet.broadcast({schema=1,kind='transformer_register',computerId=os.getComputerID(),
        cluster=config.cluster or 'transformer',release=U.release,sentAt=R.now(),leaseSeconds=90,
        capabilities={autonomous=true,localMaintenance=true,remoteControl=false},
        status={phase=protection and protection.phase or 'protection offline',
          inputVoltage=protection and protection.inputVoltage,outputVoltage=protection and protection.outputVoltage,
          target=protection and protection.target,activeTarget=regulation and regulation.activeTarget}},'powerplant.registry.v1')
    end)
    R.state.plantRegistryError=not ok and tostring(why) or nil
  end
  function R.heartbeat()
    while true do
      local ok=pcall(function()
        R.refreshTripReason()
        if not rednet.isOpen(node.modem) then assert(U.device(node.modem).isWireless()==false,'Use the local wired modem'); rednet.open(node.modem) end
        R.publish('hello',{})
        if R.role=='master' then R.publish('config_offer',{config=config}) end
        -- Only bounded event tails go over the link; full history stays local.
        local state={}; for key,value in pairs(R.state) do if key~='events' then state[key]=U.copy(value) end end; state.events={}
        for i=math.max(1,#R.events-7),#R.events do state.events[#state.events+1]=R.events[i] end
        R.publish('heartbeat',state)
        R.registerPlant()
      end)
      if not ok and R.role~='master' and not R.state.latched then R.trip('modem_failure','Wired modem unavailable') end
      sleep(.25)
    end
  end
  function R.receive()
    while true do
      local sender,m=rednet.receive(U.protocol,.25)
      if type(m)=='table' and m.kind=='config_request' and R.role=='master'
        and config.ids[m.role]==sender then
        R.send(m.role,'config_bundle',{config=config})
      end
      if type(m)=='table' and m.kind=='config_offer' and R.role~='master' and sender==config.ids.master
        and m.role=='master' and U.finite(m.sentAt) and math.abs(R.now()-m.sentAt)<=2000 then
        local ok,why=pcall(function()
          local nextConfig=U.validate(m.data.config)
          if nextConfig.revision<=config.revision then return end
          for _,role in ipairs(U.roles) do assert(nextConfig.ids[role]==config.ids[role],'Recommission changed computer IDs locally') end
          assert(modules.hash(U.canonical(nextConfig))==m.digest,'Configuration digest mismatch')
          assert(R.state.latched and U.isolated(config.settings) and U.idle(config.settings),'Configuration requires maintenance')
          assert(U.isolated(nextConfig.settings) and U.idle(nextConfig.settings),'New mappings must also be isolated')
          node.config=nextConfig; U.write('distributed-node.json',node); R.rebootRequested=true
        end)
        if not ok then R.state.message=tostring(why) end
      end
      -- Activation acknowledgements can arrive from the newly booted version.
      -- Match an outstanding transfer and configured sender before accepting it.
      if type(m)=='table' and type(m.data)=='table' and m.digest==R.digest and U.finite(m.sentAt) and math.abs(R.now()-m.sentAt)<=2000 then
        if m.kind=='update_ack' and R.role=='master' and R.updatePending[m.data.id]==m.role and config.ids[m.role]==sender then R.updateAcks[m.data.id]=m.data end
        if m.kind=='update_activate' and sender==config.ids.master and R.role~='master' and m.data.version==U.release then
          local ok=pcall(function() assert(R.state.latched and U.isolated(config.settings) and U.idle(config.settings)) end)
          R.send('master','update_ack',{id=m.data.id,ok=ok,reason=not ok and 'Not isolated' or nil})
        end
      end
      local accepted,restarted
      if type(m)=='table' and m.digest==R.digest then accepted,restarted=U.accept(config,R.peers,sender,m,R.now(),m.kind=='hello' or m.kind=='heartbeat') end
      if accepted then
        local ok,why=pcall(function()
          if restarted and m.role~='master' and R.role~='master' and not R.state.latched then R.trip('worker_restart',m.role..' restarted') end
          if m.kind=='trip' then
            assert(type(m.data)=='table' and type(m.data.id)=='string' and type(m.data.reason)=='string','Invalid trip report')
            if not R.eventIndex[m.data.id] then R.trip(m.data.code,m.data.reason,m.data.detail,m.data) end
          elseif m.kind=='heartbeat' then
            for _,event in ipairs(m.data.events or {}) do
              -- Historical incidents merge without retripping a reset cycle.
              if event.cycle and event.cycle==R.state.cycle and m.data.latched and not R.state.latched then R.trip(event.code,event.reason,event.detail,event)
              elseif R.record(event) then R.persist() end
            end
            if R.role=='regulation' and m.role=='protection' and not R.state.latched and m.data.latched then R.trip('protection_trip','Protection is latched') end
          elseif m.kind=='command_result' and m.role=='protection' then
            R.state.message=m.data.reason
          elseif m.kind=='arm' and m.role=='protection' and R.role=='regulation' then
            if m.data.cycle~=R.state.cycle then
              assert(U.isolated(config.settings) and U.idle(config.settings),'Cannot arm while energized/moving')
              R.state.cycle=m.data.cycle; R.state.target=m.data.target; R.state.activeTarget=m.data.target
              R.state.diagnostic=m.data.diagnostic; R.state.diagnosticReport=nil
              R.clearFaults(); if R.state.diagnostic then R.state.runRequested=false end; R.state.phase='starting'; R.persist()
            end
          elseif (m.kind=='start' or m.kind=='diagnose' or m.kind=='target') and m.role=='master' and R.role=='protection' then
            R.commands[#R.commands+1]=m
          elseif m.kind=='close' and m.role=='regulation' and R.role=='protection' then
            if #R.commands<8 then R.commands[#R.commands+1]=m end
          elseif m.kind=='update_ack' then
            -- Handled above with outstanding-transfer and sender checks.
          elseif type(m.kind)=='string' and m.kind:match('^update_') and m.role=='master' then
            local handled,e=pcall(R.updater.receive,sender,m)
            R.send('master','update_ack',{id=m.data.id,ok=handled,reason=not handled and tostring(e) or nil})
          end
        end)
        if not ok then R.state.message=tostring(why) end
      end
    end
  end
  function R.watchdog()
    while true do
      if R.role~='master' and not R.state.latched then
        if R.state.diagnostic then
          local master=R.fresh('master')
          if not master or master.diagnosticRequest~=R.state.diagnostic.id then R.trip('diagnostic_aborted','Diagnostic master unavailable') end
        end
        local other=R.role=='regulation' and 'protection' or 'regulation'
        -- Arming waits for the counterpart while contacts are still open.
        if not R.fresh(other) and not U.isolated(config.settings) then R.trip('worker_timeout',other..' communication lost') end
      end
      if R.rebootRequested and (not R.rebootAt or R.now()>=R.rebootAt) then
        assert(R.state.latched and U.isolated(config.settings) and U.idle(config.settings),'Unsafe reboot blocked')
        os.reboot()
      end
      sleep(.1)
    end
  end
  R.updater=modules.updater.new(R)
  return R
end
return M
