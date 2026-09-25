-- Shaft control only. Breaker closure is a request to the protection computer.
local M={}
function M.new(R)
  local U,s,P=R.U,R.config.settings,R.modules.planner
  local directions={}
  local presetKey=R.modules.hash(U.canonical(s))
  local presetPath='distributed-startup.json'
  local function guard(isolated)
    assert(not R.state.latched,'Regulation tripped/stopped')
    local protection=R.fresh('protection')
    assert(protection and not protection.latched and protection.cycle==R.state.cycle,'Protection unavailable or cycle changed')
    if isolated then assert(U.isolated(s),'Input/output contacts must be open for homing')
    else
      for _,name in ipairs(s.inputBreakers) do assert(U.device(name).isClosed(),'unknown_opening: input contact unexpectedly open') end
      U.checkAlignment(s)
      local input=U.voltage(s.inputGauge)
      assert(input>1 and input<=s.maxInputVolts,'Invalid regulator input')
      if R.state.phase=='live' then
        assert(U.device(s.plusBreaker).isClosed() and U.device(s.minusBreaker).isClosed(),'unknown_opening: output contact unexpectedly open')
      end
    end
  end
  local function pause(dt,isolated)
    guard(isolated); sleep(dt or .05); guard(isolated)
  end
  local function settle(i,isolated)
    local untilAt=R.now()+s.moveTimeout*1000
    while true do
      guard(isolated)
      local banks,stationary=U.stationaryBanks(s)
      -- In-service movement must pass every bank before another step begins.
      -- Isolated homing is allowed to start with mismatched members.
      if not isolated then
        for stage,bank in ipairs(banks) do
          if bank.stationary then assert(bank.aligned,'bank_misaligned: stage '..stage) end
        end
      end
      if stationary then return banks[i] end
      if R.now()>=untilAt then
        for stage,bank in ipairs(banks) do
          if not bank.stationary then
            local name=bank.members[1].name
            for _,member in ipairs(bank.members) do if member.shaftSpeed~=0 then name=member.name; break end end
            error('variac_stuck: stage '..stage..' '..name..' failed to stop')
          end
        end
      end
      pause(.05,isolated)
    end
  end
  local function move(i,degrees,direction,isolated)
    guard(isolated)
    local gear=U.device(s['gear'..string.char(64+i)])
    assert(not gear.isRunning(),'Drive already running: stage '..i)
    gear.rotate(math.abs(degrees),direction)
    sleep(.05) -- Allow the native movement command to reach the next tick.
    return settle(i,isolated)
  end
  local function direction(i)
    local before=U.positions(s)[i].position
    local after=move(i,3,1,true).position; local modifier=1
    if math.abs(after-before)*s.travelDegrees<.2 then before=after; modifier=-1; after=move(i,3,-1,true).position end
    assert(math.abs(after-before)*s.travelDegrees>=.2,'variac_stuck: stage '..i)
    directions[i]=after>before and modifier or -modifier
  end
  local function request(group)
    R.state.phase='await_'..group
    guard(group=='input') -- Verify full isolation before requesting input closure.
    local untilAt=R.now()+s.chargeTimeout*1000
    repeat
      if group=='input' then
        -- Protection closes contacts sequentially. A partially closed input
        -- group is expected here; shafts remain idle and outputs stay open.
        assert(not R.state.latched,'Regulation tripped/stopped')
        local p=R.fresh('protection')
        assert(p and not p.latched and p.cycle==R.state.cycle,'Protection unavailable during input connection')
        assert(U.device(s.plusBreaker).isClosed()==false and U.device(s.minusBreaker).isClosed()==false,'Output must stay isolated during input connection')
        U.aligned(s); assert(U.idle(s),'Drives moved during input connection')
      else guard(false) end
      R.publish('close',{cycle=R.state.cycle,group=group})
      sleep(.25)
      assert(not R.state.latched and R.now()<untilAt,'Breaker permission timed out: '..group)
      local p=R.fresh('protection')
      if p and not p.latched and p.cycle==R.state.cycle and p.phase==(group=='input' and 'input_on' or 'connected') then
        local names=group=='input' and s.inputBreakers or {s.plusBreaker,s.minusBreaker}
        for _,name in ipairs(names) do assert(U.device(name).isClosed(),'Breaker not closed after permission: '..name) end
        return
      end
    until false
  end
  local function verifyMovement(stage,member,before,command,expected)
    local moved=(member.position-before)*s.travelDegrees
    local prefix=('variac_stuck: stage %d %s commanded %+.3f deg, moved %+.3f deg'):format(stage,member.name,command,moved)
    assert(command==0 or moved*command>0,prefix..'; no movement in commanded direction')
    assert(math.abs(member.position-expected)*s.travelDegrees<=s.positionToleranceDegrees+1e-9,prefix..'; destination outside movement tolerance')
  end
  local function apply(plan)
    for _,sign in ipairs({-1,1}) do
      for i=1,3 do
        if plan[i]*sign>0 then
          U.aligned(s)
          local before=U.positions(s)[i]; local after=move(i,math.abs(plan[i]),sign*directions[i],false)
          for j,member in ipairs(after.members) do
            local expected=math.max(0,math.min(1,before.members[j].position+plan[i]/s.travelDegrees))
            verifyMovement(i,member,before.members[j].position,plan[i],expected)
          end
        end
      end
    end
  end
  local function feedbackPlan(banks,input,output,target,yieldFn,isolated)
    local err=math.abs(output-target)
    local limit=isolated and err>target*.02 and 16 or 1
    local plan=P.choose(s,banks,input,output,target,limit,yieldFn,false,false)
    if isolated and limit==1 and err>s.fallbackVolts and (plan.travel==0 or plan.err>=err-.001 or plan.err>s.fallbackVolts) then
      plan=P.choose(s,banks,input,output,target,16,yieldFn,false,false)
    end
    return plan
  end
  local previousLive
  local function tune()
    local input,output=U.voltage(s.inputGauge),U.voltage(s.outputGauge)
    local target=R.state.activeTarget; local err=math.abs(output-target)
    if err<=s.accuracyVolts then previousLive=nil; return true end
    local previous=previousLive; previousLive={input=input,output=output}
    if not previous or math.abs(output-previous.output)>s.fallbackVolts
      or math.abs(input-previous.input)*target/math.max(input,1)>s.fallbackVolts then return false end
    local plan=feedbackPlan(U.positions(s),input,output,target,function() pause(.01,false) end)
    if plan.travel==0 or plan.err>=err-.001 then
      if err<=s.fallbackVolts then return true end
      error('Target unreachable at current input/load')
    end
    apply(plan); previousLive=nil; pause(math.max(s.settleSeconds or .2,.5),false)
    return math.abs(U.voltage(s.outputGauge)-target)<=s.fallbackVolts
  end
  local function initialTune()
    local input,output
    local loaded,preset=pcall(U.read,presetPath)
    if not loaded then preset=nil end
    R.state.startupPreset='Learning no-load preset'
    local function verified(output)
      for sample=1,3 do
        if math.abs(output-R.state.activeTarget)>s.fallbackVolts then return false,output end
        if sample<3 then pause(.15,false); output=U.voltage(s.outputGauge) end
      end
      return true,output
    end
    local measurements={}
    R.state.startupMeasurements=measurements
    for attempt=1,12 do
      guard(false)
      assert(U.device(s.plusBreaker).isClosed()==false and U.device(s.minusBreaker).isClosed()==false,'Output must remain isolated during startup positioning')
      local before=U.stationaryBanks(s); U.aligned(s,before)
      input,output=U.voltage(s.inputGauge),U.voltage(s.outputGauge)
      local ready
      ready,output=verified(output)
      if ready then return end
      R.state.phase='planning'
      local function planningYield()
        -- Yield for independent protection/heartbeats without rescanning every
        -- wired peripheral inside a pure mathematical search.
        assert(not R.state.latched,'Startup planning interrupted by trip')
        local peer=R.fresh('protection')
        assert(peer and not peer.latched and peer.cycle==R.state.cycle,'Protection unavailable during startup planning')
        sleep(0)
      end
      local err=math.abs(output-R.state.activeTarget)
      local fine=err<=10
      local cached=attempt==1 and P.cached(s,before,preset,input,R.state.activeTarget,presetKey) or nil
      local plan
      if cached and cached.travel>0 then
        plan=cached; fine=false; R.state.startupPreset='Using saved no-load preset'
      elseif fine then
        plan=feedbackPlan(before,input,output,R.state.activeTarget,planningYield,true)
        plan.positions={}; plan.degrees={}
        for i=1,3 do
          plan.positions[i]=math.max(0,math.min(1,before[i].position+plan[i]/s.travelDegrees))
          plan.degrees[i]=plan.positions[i]*s.travelDegrees
        end
      else
        plan=P.initial(s,before,input,attempt>1 and output or nil,R.state.activeTarget,planningYield)
      end
      assert(cached or fine or attempt>1 or plan.err<=s.fallbackVolts,('Startup target unreachable: predicted %.2f V, target %.2f V'):format(plan.predicted,R.state.activeTarget))
      assert(plan.travel>0 and (attempt==1 or plan.err<err-.001),'Startup voltage cannot improve with measured corrections; check gauges, settling delay and ratios')
      guard(false)
      local checked=U.stationaryBanks(s); U.aligned(s,checked)
      for i=1,3 do assert(checked[i].position==before[i].position,'Variac position changed during planning: stage '..i) end
      R.state.startupPlan={positions=plan.positions,degrees=plan.degrees,predicted=plan.predicted,target=R.state.activeTarget,attempt=attempt}
      local measurement={attempt=attempt,mode=plan==cached and 'cached' or fine and 'fine' or 'coarse',input=input,outputBefore=output,predicted=plan.predicted,target=R.state.activeTarget,banks={}}
      for i=1,3 do
        measurement.banks[i]={beforeDegrees=before[i].position*s.travelDegrees,commandDegrees=plan[i],targetDegrees=plan.degrees[i]}
      end
      measurements[#measurements+1]=measurement
      if fine then
        R.state.phase='fine_tuning'
        apply(plan) -- Same sequential, lower-before-raise execution as live regulation.
      else
        R.state.phase='positioning'
        local generation=R.state.generation
        for i=1,3 do
          if plan[i]~=0 then
            assert(not R.state.latched and R.state.generation==generation,'Trip superseded startup movement')
            U.device(s['gear'..string.char(64+i)]).rotate(math.abs(plan[i]),(plan[i]>0 and 1 or -1)*directions[i])
          end
        end
        sleep(.05)
        settle(1,false)
      end
      local after=U.stationaryBanks(s); U.aligned(s,after)
      for i,bank in ipairs(after) do measurement.banks[i].actualDegrees=bank.position*s.travelDegrees end
      for i,bank in ipairs(after) do
        for j,member in ipairs(bank.members) do
          verifyMovement(i,member,before[i].members[j].position,plan[i],plan.positions[i])
        end
      end
      R.state.phase='tuning'
      pause(s.settleSeconds or .2,false)
      output=U.voltage(s.outputGauge)
      measurement.output=output
      ready,output=verified(output)
      if ready then return end
    end
    local history={}
    for _,v in ipairs(measurements) do history[#history+1]=('%.2f'):format(v.output) end
    error(('Startup voltage verification failed after 12 calculated plans: measured %.2f V, target %.2f V, input %.2f V; output history [%s]. Check input stability, settling delay, gauges and transformer ratios.'):format(output,R.state.activeTarget,input,table.concat(history,', ')))
  end
  local function operate()
    previousLive=nil
    R.state.startupMeasurements=nil; R.state.startupPlan=nil
    R.state.phase='homing'; guard(true)
    for i=1,3 do
      local bank=settle(i,true); direction(i)
      if not bank.aligned then
        bank=move(i,math.ceil(s.travelDegrees)+3,-directions[i],true)
        for _,m in ipairs(bank.members) do assert(m.position*s.travelDegrees<=.1,'variac_stuck: stage '..i..' '..m.name..' did not home') end
      end
    end
    U.aligned(s); assert(U.idle(s),'Drives not idle')
    R.state.activeTarget=R.state.target
    request('input'); R.state.phase='tuning'
    initialTune()
    -- Learn only with both output contacts open, never from loaded regulation.
    guard(false)
    assert(not U.device(s.plusBreaker).isClosed() and not U.device(s.minusBreaker).isClosed(),'Output must be isolated when saving no-load preset')
    local banks=U.stationaryBanks(s); U.aligned(s,banks)
    local input,output=U.voltage(s.inputGauge),U.voltage(s.outputGauge)
    if math.abs(output-R.state.activeTarget)<=s.fallbackVolts then
      local positions={}; for i,bank in ipairs(banks) do positions[i]=bank.position end
      local saved,why=pcall(U.write,presetPath,{schema=1,key=presetKey,target=R.state.activeTarget,input=input,output=output,positions=positions})
      R.state.startupPreset=saved and 'No-load preset saved' or 'Could not save preset: '..tostring(why)
    end
    request('output'); R.state.phase='live'; R.state.startupPlan=nil
    local last=R.now()
    while true do
      guard(false)
      local p=assert(R.fresh('protection')); R.state.target=p.target
      local now=R.now(); local step=math.min(s.maxRampStepVolts,s.rampVoltsPerSecond*(now-last)/1000); last=now
      if math.abs(U.voltage(s.outputGauge)-R.state.activeTarget)<=s.fallbackVolts then
        local d=R.state.target-R.state.activeTarget; R.state.activeTarget=R.state.activeTarget+math.max(-step,math.min(step,d))
      end
      tune(); pause(s.pollSeconds or .1,false)
    end
  end
  return {run=function()
    while true do
      local peer=R.fresh('protection')
      if R.state.latched or not R.state.cycle or not peer or peer.latched or peer.cycle~=R.state.cycle then sleep(.1)
      else
        local ok,why=pcall(operate)
        if not ok and not R.state.latched then R.trip(tostring(why):find('unknown_opening',1,true) and 'unknown_opening' or tostring(why):find('bank_misaligned',1,true) and 'bank_misaligned' or tostring(why):find('variac_stuck',1,true) and 'variac_stuck' or 'regulation_fault',tostring(why),R.state.phase~='live' and R.state.startupMeasurements and {startupMeasurements=R.state.startupMeasurements} or nil) end
      end
    end
  end}
end
return M
