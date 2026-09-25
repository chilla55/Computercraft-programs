-- Only this module may call breaker.close(). It reads physical interlocks.
local M={}
function M.new(R)
  local U,s=R.U,R.config.settings
  local policy=R.modules.thermal.new({s.variacsA,s.variacsB,s.variacsC},{graceSeconds=s.thermalGraceSeconds,maxAgeSeconds=s.thermalMaxAgeSeconds,coolSeconds=s.thermalCoolSeconds})
  local saved=U.read('distributed-thermal.json'); if saved then policy.restore(saved) end
  local lastSaved,expected,processed=nil,{},{}
  local temperatures={}
  local thermalReady=false
  local movingSince={}
  local function save()
    local value=policy.export(); local encoded=textutils.serializeJSON(value)
    if encoded~=lastSaved then U.write('distributed-thermal.json',value); lastSaved=encoded end
  end
  local function sample()
    temperatures={}
    for i,key in ipairs({'A','B','C'}) do
      for _,name in ipairs(s['variacs'..key]) do
        local ok,v=pcall(function()
          local t=U.device(name).getThermalStatus()
          assert(type(t)=='table' and t.available==true and t.unit=='C' and U.finite(t.temperature) and t.temperature>=-273.15,'Invalid temperature '..name)
          return t.temperature
        end)
        local fault=policy.update(name,ok and v or nil,R.now()/1000,'measured')
        temperatures[#temperatures+1]={name=name,stage=i,temperature=ok and v or nil,reason=not ok and tostring(v) or nil,sampledAt=R.now()}
        if fault and (not R.state.latched or R.state.realignRequested) then R.trip(fault.code,fault.reason,fault) end
      end
    end
    local fault=policy.check(R.now()/1000); save()
    R.state.thermal=policy.status(R.now()/1000); R.state.temperatures=temperatures; thermalReady=true
    if fault and (not R.state.latched or R.state.realignRequested) then R.trip(fault.code,fault.reason,fault) end
  end
  local function banksReady()
    U.aligned(s); assert(U.idle(s),'Gearshift still moving')
  end
  local function check()
    if not R.state.latched then
      local fault=policy.check(R.now()/1000)
      if fault then save(); R.trip(fault.code,fault.reason,fault); return end
    end
    local generation=R.state.generation
    local contacts=U.contacts(s); R.state.contacts=contacts
    -- A thermal/remote trip can yield while opening contacts. Discard a
    -- snapshot spanning that transition and re-read after opening completes.
    if generation~=R.state.generation or (R.openingBreakers or 0)>0 then return end
    local energized=false
    for _,name in ipairs(s.inputBreakers) do energized=energized or contacts[name].closed end
    if not R.state.latched then
      for name,wanted in pairs(expected) do
        if wanted and not contacts[name].closed then R.trip('unknown_opening','Uncommanded opening; cause unknown',{breaker=name,observed=true}); return end
      end
    end
    if R.state.latched then
      expected={}; movingSince={}
      for name,v in pairs(contacts) do
        if v.closed then R.trip('unexpected_closed','Contact closed while latched',{breaker=name}); return end
      end
      return
    end
    if energized then
      local peer=R.fresh('regulation'); assert(peer and peer.cycle==R.state.cycle and not peer.latched,'Regulation heartbeat unavailable or not ready')
      local banks=U.checkAlignment(s)
      for i,bank in ipairs(banks) do
        if bank.stationary then movingSince[i]=nil
        else
          movingSince[i]=movingSince[i] or R.now()
          assert(R.now()-movingSince[i]<s.moveTimeout*1000,'variac_stuck: stage '..i..' did not stop')
        end
      end
      local input=U.voltage(s.inputGauge); local output=U.voltage(s.outputGauge)
      R.state.inputVoltage=input; R.state.outputVoltage=output
      -- Native reads yield: a peer trip can open inputs after the contact
      -- snapshot above. Do not label the resulting dead input as a new fault.
      if R.state.latched then return end
      if input<=1 then
        for _,name in ipairs(s.inputBreakers) do
          if not U.device(name).isClosed() then return end
        end
      end
      assert(input>1 and input<=s.maxInputVolts,'Input voltage outside safe range')
      if s.sourceCurrentTripAmps>0 then
        local p=U.device(s.sourceCurrentGauge); local amps=(p.current or p.getValue)()
        assert(U.finite(amps) and math.abs(amps)<=s.sourceCurrentTripAmps,'Source current unavailable/over limit')
      end
      local target=peer.activeTarget or R.state.target
      assert(U.finite(target) and target>0 and target/(s.stepUp*.99999^3)<s.maxInputVolts,'Invalid regulation target')
      if contacts[s.plusBreaker].closed or contacts[s.minusBreaker].closed then
        assert(output>1 and output<=target*(1+s.outputTripPercent/100),'Output voltage outside safe range')
        for _,name in ipairs({s.plusBreaker,s.minusBreaker}) do
          local v=contacts[name]; assert(v.currentValid and U.finite(v.current),'Invalid native breaker current')
          if v.tripEnabled and U.finite(v.tripCurrent) and v.tripCurrent>0 then assert(math.abs(v.current)<=v.tripCurrent,'Native breaker current exceeded') end
        end
      end
    end
  end
  local function close(group)
    local generation=R.state.generation
    local function veto()
      assert(not R.state.latched and generation==R.state.generation,'Trip superseded close request')
      local p=R.fresh('regulation')
      assert(p and p.cycle==R.state.cycle and not p.latched,'No current regulation clearance')
      assert(not policy.check(R.now()/1000),'Thermal interlock not satisfied')
    end
    veto(); banksReady()
    local names
    if group=='input' then
      assert(U.device(s.plusBreaker).isClosed()==false and U.device(s.minusBreaker).isClosed()==false,'Output must be isolated')
      names=s.inputBreakers
    elseif group=='output' then
      for _,name in ipairs(s.inputBreakers) do assert(U.device(name).isClosed(),'Input not energized') end
      local p=assert(R.fresh('regulation')); local output=U.voltage(s.outputGauge)
      assert(p.phase=='await_output' and U.finite(p.activeTarget),'Regulation not ready for output connection')
      assert(math.abs(output-p.activeTarget)<=s.fallbackVolts,'Output not tuned')
      names={s.minusBreaker,s.plusBreaker}
    else error('Unknown breaker group') end
    R.state.phase='closing_'..group
    for _,name in ipairs(names) do
      veto(); banksReady()
      local device=U.device(name); local status=device.getStatus()
      assert(status.closed or status.canClose,'Breaker not charged: '..name)
      veto(); device.close()
      veto(); assert(device.isClosed(),'Breaker failed to close: '..name)
      expected[name]=true
    end
    R.state.phase=group=='input' and 'input_on' or 'connected'
  end
  local function command(m)
    if m.kind=='start' then
      if not R.state.latched then R.state.message='Already running.'; return end
      local generation=R.state.generation
      assert(U.isolated(s) and U.idle(s),'Reset requires verified open contacts and idle drives')
      assert(generation==R.state.generation,'A new trip superseded the start request')
      local ok,why=policy.reset(R.now()/1000); assert(ok,why); save()
      assert(generation==R.state.generation,'A new trip superseded the start request')
      R.clearFaults(); R.state.cycle=R.token(); R.state.phase='armed'; expected={}; processed={}
      R.persist(); R.publish('arm',{cycle=R.state.cycle,target=R.state.target})
    elseif m.kind=='target' then
      local target=m.data.target
      assert(U.finite(target) and target>0 and target/(s.stepUp*.99999^3)<s.maxInputVolts,'Target outside configured range')
      R.state.target=target; R.persist()
    elseif m.kind=='close' then
      if R.state.latched or m.data.cycle~=R.state.cycle or processed[m.data.group] then return end
      local peer=R.fresh('regulation')
      if not peer or peer.phase~='await_'..m.data.group then return end
      close(m.data.group); processed[m.data.group]=true
    end
  end
  local function interlocks()
    while true do
      local ok,why=pcall(function()
        check()
        if R.bootResume and R.state.latched and thermalReady then
          local peer=R.fresh('regulation')
          if peer then
            if not peer.runRequested or peer.phase=='tripped' then
              R.trip('auto_resume_blocked','Regulation did not request automatic restart; use Resume/reset')
            elseif peer.latched and U.isolated(s) and U.idle(s) then
              R.bootResume=false -- one boot attempt; no repeated automatic resets
              local fault=policy.check(R.now()/1000)
              if fault then R.trip(fault.code,fault.reason,fault)
              else
                local accepted,reason=pcall(command,{kind='start',data={}})
                if not accepted then R.trip('auto_resume_blocked',tostring(reason)) end
              end
            end
          else R.state.message='Waiting for regulation before automatic restart.' end
        end
        if R.state.realignRequested and R.state.latched and thermalReady then
          local peer=R.fresh('regulation')
          if peer and peer.latched then
            if not (peer.realignRequested or peer.runRequested) then
              R.trip('realignment_blocked','Regulation has another stop/fault; manual reset required')
            elseif U.isolated(s) and U.idle(s) then
              local fault=policy.check(R.now()/1000)
              if fault then R.trip(fault.code,fault.reason,fault)
              else
                -- Start uses the same fresh-temperature reset and isolated
                -- homing path as a manual start. Nothing closes here.
                local accepted,reason=pcall(command,{kind='start',data={}})
                if not accepted then R.trip('realignment_blocked',tostring(reason)) end
              end
            end
          else R.state.message='Alignment trip: waiting for isolated regulation worker.' end
        end
        local m=R.commands[1]
        if m and (m.kind~='start' or thermalReady) then
          table.remove(R.commands,1)
          if m.kind=='close' then command(m)
          else
            local accepted,reason=pcall(command,m)
            R.state.message=accepted and (m.kind..' accepted') or tostring(reason)
            R.publish('command_result',{command=m.kind,accepted=accepted,reason=R.state.message})
          end
        end
        if not R.state.latched then
          local peer=R.fresh('regulation')
          if not peer or peer.cycle~=R.state.cycle then R.publish('arm',{cycle=R.state.cycle,target=R.state.target}) end
        end
      end)
      if not ok then local reason=tostring(why); R.trip(reason:find('bank_misaligned',1,true) and 'bank_misaligned' or reason:find('variac_stuck',1,true) and 'variac_stuck' or 'protection_interlock',reason) end
      sleep(.05)
    end
  end
  local function thermal()
    while true do
      local ok,why=pcall(sample)
      if not ok then R.trip('thermal_sampler_failure',tostring(why)) end
      sleep(.05)
    end
  end
  return {run=function() parallel.waitForAny(thermal,interlocks) end}
end
return M
