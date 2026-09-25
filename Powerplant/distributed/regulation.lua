-- Shaft control only. Breaker closure is a request to the protection computer.
local M={}
function M.new(R)
  local U,s,P=R.U,R.config.settings,R.modules.planner
  local directions={}
  local function guard(isolated)
    assert(not R.state.latched,'Regulation tripped/stopped')
    local protection=R.fresh('protection')
    assert(protection and not protection.latched and protection.cycle==R.state.cycle,'Protection unavailable or cycle changed')
    if isolated then assert(U.isolated(s),'Input/output contacts must be open for homing')
    else
      for _,name in ipairs(s.inputBreakers) do assert(U.device(name).isClosed(),'unknown_opening: input contact unexpectedly open') end
      U.aligned(s)
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
    local gear=U.device(s['gear'..string.char(64+i)]); local untilAt=R.now()+s.moveTimeout*1000
    local last,stable=nil,0
    repeat
      pause(.05,isolated)
      local bank=U.positions(s)[i]; local delta=0
      if last then for j,m in ipairs(bank.members) do delta=math.max(delta,math.abs(m.position-last.members[j].position)*s.travelDegrees) end end
      if last and delta<.02 and not gear.isRunning() then stable=stable+1 else stable=0 end
      last=bank; assert(R.now()<untilAt,'variac_stuck: stage '..i..' failed to settle')
    until stable>=4
    return last
  end
  local function move(i,degrees,direction,isolated)
    guard(isolated)
    local gear=U.device(s['gear'..string.char(64+i)])
    assert(not gear.isRunning(),'Drive already running: stage '..i)
    gear.rotate(math.abs(degrees),direction)
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
    local untilAt=R.now()+s.chargeTimeout*1000
    repeat
      guard(group=='input')
      R.publish('close',{cycle=R.state.cycle,group=group})
      sleep(.25)
      assert(not R.state.latched and R.now()<untilAt,'Breaker permission timed out')
      local p=R.fresh('protection')
      if p and p.cycle==R.state.cycle and p.phase==(group=='input' and 'input_on' or 'connected') then return end
      -- Once input has closed, waiting for its acknowledgement must not
      -- interpret the intended close as an isolation violation.
      if group=='input' then
        local all=true; for _,name in ipairs(s.inputBreakers) do all=all and U.device(name).isClosed() end
        if all and p and not p.latched then return end
      end
    until false
  end
  local function apply(plan)
    for _,sign in ipairs({-1,1}) do
      for i=1,3 do
        if plan[i]*sign>0 then
          local before=U.positions(s)[i]; local after=move(i,math.abs(plan[i]),sign*directions[i],false)
          for j,member in ipairs(after.members) do
            local expected=math.max(0,math.min(1,before.members[j].position+plan[i]/s.travelDegrees))
            assert(math.abs(member.position-expected)*s.travelDegrees<=s.positionToleranceDegrees+1e-9,'variac_stuck: stage '..i..' '..member.name)
          end
        end
      end
    end
  end
  local function tune(live)
    local input,output=U.voltage(s.inputGauge),U.voltage(s.outputGauge)
    local target=R.state.activeTarget; local err=math.abs(output-target)
    if err<=s.accuracyVolts then return true end
    local limit=live and (err<=target*.02 and 1 or 16) or math.ceil(s.travelDegrees)
    local plan=P.choose(s,U.positions(s),input,output,target,limit,function() pause(.01,false) end)
    if plan.travel==0 or plan.err>=err-.001 then
      if err<=s.fallbackVolts then return true end
      if live and limit==1 then plan=P.choose(s,U.positions(s),input,output,target,16,function() pause(.01,false) end) end
      assert(plan.travel>0 and plan.err<err-.001,'Target unreachable at current input/load')
    end
    apply(plan); pause(s.settleSeconds or .2,false)
    return math.abs(U.voltage(s.outputGauge)-target)<=s.fallbackVolts
  end
  local function operate()
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
    local deadline=R.now()+120000
    while not tune(false) do assert(R.now()<deadline,'Initial tuning timed out') end
    request('output'); R.state.phase='live'
    local last=R.now()
    while true do
      guard(false)
      local p=assert(R.fresh('protection')); R.state.target=p.target
      local now=R.now(); local step=math.min(s.maxRampStepVolts,s.rampVoltsPerSecond*(now-last)/1000); last=now
      if math.abs(U.voltage(s.outputGauge)-R.state.activeTarget)<=s.fallbackVolts then
        local d=R.state.target-R.state.activeTarget; R.state.activeTarget=R.state.activeTarget+math.max(-step,math.min(step,d))
      end
      tune(true); pause(s.pollSeconds or .1,false)
    end
  end
  return {run=function()
    while true do
      local peer=R.fresh('protection')
      if R.state.latched or not R.state.cycle or not peer or peer.latched or peer.cycle~=R.state.cycle then sleep(.1)
      else
        local ok,why=pcall(operate)
        if not ok then R.trip(tostring(why):find('unknown_opening',1,true) and 'unknown_opening' or tostring(why):find('bank_misaligned',1,true) and 'bank_misaligned' or tostring(why):find('variac_stuck',1,true) and 'variac_stuck' or 'regulation_fault',tostring(why)) end
      end
    end
  end}
end
return M
