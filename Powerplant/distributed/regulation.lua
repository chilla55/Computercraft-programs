-- Shaft control only. Breaker closure is a request to the protection computer.
local M={}
function M.new(R)
  local U,s,P=R.U,R.config.settings,R.modules.planner
  local directions={}
  local readInput=U.inputReader(s)
  local function inputVoltage()
    local value,estimated=readInput(R.state.cycle,R.state.phase)
    R.state.inputEstimated=estimated
    return value
  end
  local readOutput=U.outputReader(s)
  local function outputVoltage()
    -- Before tuning succeeds a low output can be intentional. Fallback is
    -- enabled for connection/service, never used to certify a no-load preset.
    if R.state.phase~='live' and R.state.phase~='await_output' then return U.voltage(s.outputGauge) end
    local target=R.state.activeTarget or s.target
    local value,estimated=readOutput(R.state.cycle,R.state.phase,target*(1+s.outputTripPercent/100))
    R.state.outputEstimated=estimated
    return value
  end
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
      local input=inputVoltage()
      assert(input>1 and input<=s.maxInputVolts,('Invalid regulator input: %.6f V from %s; required >1 V and <=%.2f V; phase %s'):format(input,s.inputGauge,s.maxInputVolts,tostring(R.state.phase)))
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
    local steps=plan.steps or {}
    if not plan.steps then
      for _,sign in ipairs({-1,1}) do
        for i=1,3 do if plan[i]*sign>0 then steps[#steps+1]={stage=i,degrees=plan[i]} end end
      end
    end
    for _,step in ipairs(steps) do
      local i,delta=step.stage,step.degrees
      U.aligned(s)
      local before=U.positions(s)[i]
      if plan.balance then
        local output=outputVoltage()
        local predicted=output*P.ratio(before.position+delta/s.travelDegrees)/P.ratio(before.position)
        if math.abs(output-plan.target)>10 or math.abs(predicted-plan.target)>10 then return end
      end
      local after=move(i,math.abs(delta),(delta>0 and 1 or -1)*directions[i],false)
      for j,member in ipairs(after.members) do
        local expected=math.max(0,math.min(1,before.members[j].position+delta/s.travelDegrees))
        verifyMovement(i,member,before.members[j].position,delta,expected)
      end
    end
  end
  local function feedbackPlan(banks,input,output,target,yieldFn,isolated)
    return P.feedback(s,banks,input,output,target,yieldFn,isolated)
  end
  local previousLive,unreachableSince
  local function tune()
    local input,output=inputVoltage(),outputVoltage()
    local target=R.state.activeTarget; local err=math.abs(output-target)
    local previous=previousLive; previousLive={input=input,output=output}
    -- A significant sag/rise needs a prompt bounded correction. Fine tuning
    -- still waits for stable readings; every completed move is re-measured.
    if err/target<=.02+1e-12 and not P.stable(previous,input,output) then unreachableSince=nil; return false end
    local banks=U.positions(s)
    local balance=err<=10 and P.balance(s,banks,output,target) or nil
    if balance then
      apply(balance); previousLive=nil; unreachableSince=nil
      pause(s.settleSeconds or .2,false)
      return math.abs(outputVoltage()-target)<=10
    end
    -- Accept the balancing band instead of undoing a successful balance
    -- solely to chase sub-volt precision and then balancing back again.
    if err<=10 then unreachableSince=nil; return true end
    local plan=feedbackPlan(banks,input,output,target,function()
      -- Pure search needs a cooperative yield, not another full peripheral scan.
      assert(not R.state.latched,'Live planning interrupted by trip')
      local peer=R.fresh('protection')
      assert(peer and not peer.latched and peer.cycle==R.state.cycle,'Protection unavailable during live planning')
      sleep(0)
    end)
    if plan.travel==0 or plan.err>=err-.001 then
      if err<=s.fallbackVolts then unreachableSince=nil; return true end
      unreachableSince=unreachableSince or R.now()
      assert(R.now()-unreachableSince<3000,('No improving local adjustment: input %.3f V, output %.3f V, target %.3f V; nearest predicted %.3f V; banks %.3f/%.3f/%.3f degrees; phase live'):format(input,output,target,plan.predicted,banks[1].position*s.travelDegrees,banks[2].position*s.travelDegrees,banks[3].position*s.travelDegrees))
      return false
    end
    apply(plan); previousLive=nil; unreachableSince=nil; pause(s.settleSeconds or .2,false)
    return math.abs(outputVoltage()-target)<=s.fallbackVolts
  end
  local function initialTune()
    local input,output
    local loaded,preset=pcall(U.read,presetPath)
    if not loaded then preset=nil end
    R.state.startupPreset='Learning no-load preset'
    local function verified(output)
      for sample=1,3 do
        if math.abs(output-R.state.activeTarget)>s.fallbackVolts then return false,output end
        if sample<3 then pause(.15,false); output=outputVoltage() end
      end
      return true,output
    end
    local measurements={}
    R.state.startupMeasurements=measurements
    local attempt=0
    while true do
      attempt=attempt+1
      guard(false)
      assert(U.device(s.plusBreaker).isClosed()==false and U.device(s.minusBreaker).isClosed()==false,'Output must remain isolated during startup positioning')
      local before=U.stationaryBanks(s); U.aligned(s,before)
      input,output=inputVoltage(),outputVoltage()
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
      if plan.travel==0 or (attempt>1 and plan.err>=err-.001) then
        -- A discrete local minimum or changing input need not be a fault.
        -- Keep the outputs isolated and resample without issuing blind moves.
        R.state.phase='tuning'
        R.state.startupPreset='Waiting for an improving startup setting'
        pause(math.max(.5,s.settleSeconds or .2),false)
      else
        guard(false)
        local checked=U.stationaryBanks(s); U.aligned(s,checked)
        for i=1,3 do assert(checked[i].position==before[i].position,'Variac position changed during planning: stage '..i) end
        R.state.startupPlan={positions=plan.positions,degrees=plan.degrees,predicted=plan.predicted,target=R.state.activeTarget,attempt=attempt}
        local measurement={attempt=attempt,mode=plan==cached and 'cached' or fine and 'fine' or 'coarse',input=input,outputBefore=output,predicted=plan.predicted,target=R.state.activeTarget,banks={}}
        for i=1,3 do
          measurement.banks[i]={beforeDegrees=before[i].position*s.travelDegrees,commandDegrees=plan[i],targetDegrees=plan.degrees[i]}
        end
        if #measurements>=32 then table.remove(measurements,1) end
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
        output=outputVoltage()
        measurement.output=output
        ready,output=verified(output)
        if ready then return end
      end -- improving movement
    end
  end
  local function diagnose()
    local test=R.state.diagnostic
    local report={schema=1,kind='bank_c',id=test.id,release=U.release,startedAt=R.now(),config=U.copy(s),preExitGauge=test.gauge,samples={}}
    R.state.diagnosticReport=report
    R.state.phase='diagnostic_isolated'; guard(true)
    local initial=U.stationaryBanks(s); U.aligned(s,initial)
    direction(3) -- Discover only C's drive direction with every breaker open.
    local current=U.positions(s)[3].position
    local restore=math.floor((initial[3].position-current)*s.travelDegrees+.5)
    if restore~=0 then move(3,math.abs(restore),(restore>0 and 1 or -1)*directions[3],true) end
    local baseline=U.stationaryBanks(s); U.aligned(s,baseline)
    assert(math.abs(baseline[3].position-initial[3].position)*s.travelDegrees<.02,'Diagnostic direction probe did not restore C')
    local distance=math.min(5,math.floor(baseline[3].position*s.travelDegrees))
    assert(distance>=1,'Bank C is too close to minimum for a downward test')
    R.state.activeTarget=R.state.target
    request('input')
    local function sample(label)
      R.state.phase='diagnostic_'..label
      pause(math.max(s.settleSeconds or .2,.5),false)
      for n=1,5 do
        guard(false)
        assert(not U.device(s.plusBreaker).isClosed() and not U.device(s.minusBreaker).isClosed(),'Diagnostic output must remain isolated')
        local banks=U.stationaryBanks(s); U.aligned(s,banks)
        for i=1,2 do
          for j,member in ipairs(banks[i].members) do assert(member.position==baseline[i].members[j].position,'Bank A/B moved during C-only diagnostic') end
        end
        local item={label=label,at=R.now(),banks=banks,input=inputVoltage(),preExit=U.voltage(test.gauge),output=outputVoltage()}
        if s.sourceGauge~='' then item.source=U.voltage(s.sourceGauge) end
        local peer=assert(R.fresh('protection')); item.temperatures=U.copy(peer.temperatures or {})
        report.samples[#report.samples+1]=item
        pause(.25,false)
      end
    end
    sample('baseline')
    R.state.phase='diagnostic_moving'; move(3,distance,-directions[3],false)
    sample('lowered')
    R.state.phase='diagnostic_moving'; move(3,distance,directions[3],false)
    sample('restored')
    local final=U.stationaryBanks(s); U.aligned(s,final)
    assert(math.abs(final[3].position-baseline[3].position)*s.travelDegrees<.02,'C did not return to diagnostic baseline')
    guard(false); assert(not R.state.latched,'Diagnostic interrupted by trip')
    report.finishing=true
    R.trip('operator_stop','Bank C diagnostic complete; all breakers opened')
    assert(R.state.isolationVerified,'Diagnostic could not verify open breakers')
    report.complete=true; report.finishedAt=R.now()
    U.write('/config/transformer-diagnostic.json',report)
  end
  local function operate()
    previousLive=nil; unreachableSince=nil
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
    local input,output=inputVoltage(),outputVoltage()
    if math.abs(output-R.state.activeTarget)<=s.fallbackVolts then
      local positions={}; for i,bank in ipairs(banks) do positions[i]=bank.position end
      local saved,why=pcall(U.write,presetPath,{schema=1,key=presetKey,target=R.state.activeTarget,input=input,output=output,positions=positions})
      R.state.startupPreset=saved and 'No-load preset saved' or 'Could not save preset: '..tostring(why)
    end
    if R.state.diagnostic then
      assert(R.state.startupPreset=='No-load preset saved','Calibration could not save the no-load preset')
      local report={schema=1,kind='calibrate',id=R.state.diagnostic.id,release=U.release,measurements=U.copy(R.state.startupMeasurements),input=input,output=output,positions={},finishing=true}
      for i,bank in ipairs(banks) do report.positions[i]=bank.position end
      R.state.diagnosticReport=report
      guard(false); assert(not R.state.latched,'Calibration interrupted')
      R.trip('operator_stop','No-load calibration complete; all breakers opened')
      assert(R.state.isolationVerified,'Calibration could not verify isolation')
      report.complete=true; report.finishedAt=R.now()
      U.write('/config/transformer-diagnostic.json',report)
      return
    end
    request('output'); R.state.phase='live'; R.state.startupPlan=nil
    local last=R.now()
    while true do
      guard(false)
      local p=assert(R.fresh('protection')); R.state.target=p.target
      local now=R.now(); local step=math.min(s.maxRampStepVolts,s.rampVoltsPerSecond*(now-last)/1000); last=now
      if math.abs(outputVoltage()-R.state.activeTarget)<=s.fallbackVolts then
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
        local ok,why=pcall(R.state.diagnostic and R.state.diagnostic.kind~='calibrate' and diagnose or operate)
        if not ok and not R.state.latched then R.trip(tostring(why):find('unknown_opening',1,true) and 'unknown_opening' or tostring(why):find('bank_misaligned',1,true) and 'bank_misaligned' or tostring(why):find('variac_stuck',1,true) and 'variac_stuck' or 'regulation_fault',tostring(why),R.state.phase~='live' and R.state.startupMeasurements and {startupMeasurements=R.state.startupMeasurements} or nil) end
      end
    end
  end}
end
return M
