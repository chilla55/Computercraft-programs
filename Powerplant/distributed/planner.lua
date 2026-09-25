-- Same calibrated whole-degree search as the standalone regulator, pure inputs.
local M={}
-- The original feedback loop accepts modest source/load variation while
-- retaining two samples after every completed correction.
function M.stable(previous,input,output)
  return previous~=nil and math.abs(input-previous.input)<=math.max(1,math.abs(previous.input)*.005)
    and math.abs(output-previous.output)<=math.max(1,math.abs(previous.output)*.005)
end
function M.ratio(p) return .00999996389330349+.989990071137444*p end
function M.choose(s,banks,input,output,target,limit,yieldFn,simultaneous,preferBalance)
  local angle,lo,hi={},{},{}
  local product=1
  for i=1,3 do angle[i]=banks[i].position*s.travelDegrees; product=product*M.ratio(banks[i].position); lo[i]=math.max(-limit,math.ceil(-angle[i])); hi[i]=math.min(limit,math.floor(s.travelDegrees-angle[i])) end
  local basis=output and output>1 and output/product or input*s.stepUp
  local best
  local function consider(a,b,c)
    if c<lo[3] or c>hi[3] then return end
    local predicted=basis*M.ratio((angle[1]+a)/s.travelDegrees)*M.ratio((angle[2]+b)/s.travelDegrees)*M.ratio((angle[3]+c)/s.travelDegrees)
    local err,travel=math.abs(predicted-target),math.abs(a)+math.abs(b)+math.abs(c)
    local cost=simultaneous and math.max(math.abs(a),math.abs(b),math.abs(c)) or travel
    local spread=math.max(angle[1]+a,angle[2]+b,angle[3]+c)-math.min(angle[1]+a,angle[2]+b,angle[3]+c)
    local rankSpread=preferBalance==false and 0 or spread
    local inside=err<=s.accuracyVolts/2
    if not best or (inside and not best.inside) or (inside==best.inside and ((inside and (rankSpread<best.rankSpread-1e-9 or math.abs(rankSpread-best.rankSpread)<=1e-9 and (cost<best.cost or cost==best.cost and err<best.err))) or (not inside and err<best.err))) then
      best={a,b,c,err=err,travel=travel,predicted=predicted,inside=inside,cost=cost,spread=spread,rankSpread=rankSpread}
    end
  end
  local rows=0
  for a=lo[1],hi[1] do
    for b=lo[2],hi[2] do
      local ratio=target/(basis*M.ratio((angle[1]+a)/s.travelDegrees)*M.ratio((angle[2]+b)/s.travelDegrees))
      local wanted=(ratio-.00999996389330349)*s.travelDegrees/.989990071137444-angle[3]
      local c=math.floor(wanted+.5)
      for d=-1,1 do consider(a,b,c+d) end
      consider(a,b,lo[3]); consider(a,b,hi[3])
      -- With a wide voltage band, its most balanced C may not be the
      -- nearest-voltage C. Search band edges and the shortest-travel point
      -- in the interval that minimizes spread against the fixed A/B pair.
      local perDegree=basis*M.ratio((angle[1]+a)/s.travelDegrees)*M.ratio((angle[2]+b)/s.travelDegrees)*.989990071137444/s.travelDegrees
      local low=math.max(lo[3],math.ceil(wanted-s.accuracyVolts/2/perDegree))
      local high=math.min(hi[3],math.floor(wanted+s.accuracyVolts/2/perDegree))
      if low<=high then
        local left=math.max(low,math.min(high,math.min(angle[1]+a,angle[2]+b)-angle[3]))
        local right=math.max(low,math.min(high,math.max(angle[1]+a,angle[2]+b)-angle[3]))
        local closest=math.max(left,math.min(right,0))
        consider(a,b,low); consider(a,b,high)
        consider(a,b,math.floor(closest)); consider(a,b,math.ceil(closest))
      end
    end
    rows=rows+1; if rows%8==0 and yieldFn then yieldFn() end
  end
  return assert(best,'No available variac setting')
end
-- Search tiny balancing paths, checking BOTH voltage bounds at every
-- intermediate destination. A balanced final product alone is insufficient.
function M.balance(s,banks,output,target)
  if math.abs(output-target)>10 then return nil end
  local positions={banks[1].position,banks[2].position,banks[3].position}
  local spread=(math.max(table.unpack(positions))-math.min(table.unpack(positions)))*s.travelDegrees
  local best
  local function visit(pos,voltage,used,steps)
    local nextSpread=(math.max(table.unpack(pos))-math.min(table.unpack(pos)))*s.travelDegrees
    if nextSpread<spread-.001 and (not best or nextSpread<best.spread-.001
      or math.abs(nextSpread-best.spread)<=.001 and (#steps<#best.steps
      or #steps==#best.steps and math.abs(voltage-target)<best.err)) then
      local copied={}; for i,step in ipairs(steps) do copied[i]={stage=step.stage,degrees=step.degrees} end
      best={balance=true,steps=copied,spread=nextSpread,err=math.abs(voltage-target),predicted=voltage,travel=#steps,target=target}
    end
    if #steps==3 then return end
    for i=1,3 do if not used[i] then
      for _,delta in ipairs({-1,1}) do
        local after=pos[i]+delta/s.travelDegrees
        if after>=0 and after<=1 then
          local predicted=voltage*M.ratio(after)/M.ratio(pos[i])
          if math.abs(predicted-target)<=10 then
            local before=pos[i]; pos[i]=after; used[i]=true; steps[#steps+1]={stage=i,degrees=delta}
            visit(pos,predicted,used,steps)
            steps[#steps]=nil; used[i]=nil; pos[i]=before
          end
        end
      end
    end end
  end
  visit(positions,output,{},{}); return best
end
-- Coarse live recovery prioritizes one useful movement over a precise
-- multi-bank combination. Re-measure before selecting the next movement.
function M.fastFeedback(s,banks,output,target,limit)
  if output<=1 then return nil end
  local err=math.abs(output-target)
  local sign=target>output and 1 or -1
  local best
  for i=1,3 do
    for degrees=1,limit do
      local position=banks[i].position+sign*degrees/s.travelDegrees
      if position>=0 and position<=1 then
        local predicted=output*M.ratio(position)/M.ratio(banks[i].position)
        local nextError=math.abs(predicted-target)
        -- Do not trade a sag for a predicted overshoot (or vice versa).
        local crossing=(predicted-target)*sign
        if crossing<=s.fallbackVolts and nextError<err-.001
          and (not best or nextError<best.err-.001 or math.abs(nextError-best.err)<=.001 and degrees<best.travel) then
          best={0,0,0,err=nextError,travel=degrees,predicted=predicted,limit=limit,fast=true}
          best[i]=sign*degrees
        end
      end
    end
  end
  return best
end
-- Normal feedback uses three error bands. Widen a stalled fine search only
-- outside fallback; accepting a local minimum is not a capacity test.
function M.feedback(s,banks,input,output,target,yieldFn,isolated)
  local err=math.abs(output-target)
  local deviation=err/target
  local limit=deviation>.10+1e-12 and 16 or deviation>.02+1e-12 and 8 or 1
  if not isolated and err>10 then
    local fast=M.fastFeedback(s,banks,output,target,limit)
    if fast then return fast end
  end
  local plan=M.choose(s,banks,input,output,target,limit,yieldFn,false,false)
  plan.limit=limit
  if isolated and limit==1 and err>s.fallbackVolts and (plan.travel==0 or plan.err>=err-.001 or plan.err>s.fallbackVolts) then
    plan=M.choose(s,banks,input,output,target,16,yieldFn,false,false)
  elseif not isolated and limit==1 and err>s.fallbackVolts and plan.err>=err-.001 then
    for _,radius in ipairs({2,4,8,16}) do
      local wider=M.choose(s,banks,input,output,target,radius,yieldFn,false,false)
      if wider.err<plan.err-.001 then plan=wider; plan.recovery=true; plan.limit=radius end
      if plan.err<=s.fallbackVolts then break end
    end
    if plan.recovery then plan.steps=M.recoverySteps(s,banks,output,target,plan) end
  end
  return plan
end
-- Interleave single-degree moves toward a wider destination. Choose the next
-- predicted voltage nearest target without crossing above the initial/target
-- ceiling. This avoids executing a whole lowering leg before compensation.
function M.recoverySteps(s,banks,output,target,plan)
  local positions,remaining,steps={},{},{}
  for i=1,3 do positions[i]=banks[i].position; remaining[i]=plan[i] end
  local ceiling=math.max(output,target,plan.predicted)+s.fallbackVolts
  for n=1,plan.travel do
    local best
    for i=1,3 do
      if remaining[i]~=0 then
        local delta=remaining[i]>0 and 1 or -1
        local predicted=output*M.ratio(positions[i]+delta/s.travelDegrees)/M.ratio(positions[i])
        local err=math.abs(predicted-target)
        if predicted<=ceiling and (not best or err<best.err) then best={stage=i,degrees=delta,predicted=predicted,err=err} end
      end
    end
    assert(best,'No bounded path to fine recovery setting')
    local i=best.stage
    positions[i]=positions[i]+best.degrees/s.travelDegrees
    remaining[i]=remaining[i]-best.degrees; output=best.predicted
    steps[#steps+1]=best
  end
  return steps
end
-- Absolute destinations derived from one input snapshot. Whole-degree
-- commands respect each shaft's current fractional-angle offset.
function M.initial(s,banks,input,output,target,yieldFn,limit)
  local plan=M.choose(s,banks,input,output,target,limit or math.ceil(s.travelDegrees),yieldFn,true)
  plan.positions={}; plan.degrees={}
  for i=1,3 do
    plan.positions[i]=math.max(0,math.min(1,banks[i].position+plan[i]/s.travelDegrees))
    plan.degrees[i]=plan.positions[i]*s.travelDegrees
  end
  return plan
end
-- A saved preset is only a starting guess. Never authorizes breaker closure.
function M.cached(s,banks,entry,input,target,key)
  local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
  if type(entry)~='table' or entry.schema~=1 or entry.key~=key or entry.target~=target
    or not finite(entry.input) or entry.input<=1 or not finite(entry.output) or entry.output<=1
    or math.abs(entry.output-target)>s.fallbackVolts or type(entry.positions)~='table' or #entry.positions~=3 then return end
  if math.abs(input-entry.input)*entry.output/entry.input>10 then return end
  local plan={positions={},degrees={},travel=0,predicted=entry.output*input/entry.input}
  for i=1,3 do
    local saved=entry.positions[i]
    if not finite(saved) or saved<0 or saved>1 then return end
    local angle=banks[i].position*s.travelDegrees
    local delta=math.floor((saved-banks[i].position)*s.travelDegrees+.5)
    delta=math.max(math.ceil(-angle),math.min(math.floor(s.travelDegrees-angle),delta))
    plan[i]=delta; plan.travel=plan.travel+math.abs(delta)
    plan.positions[i]=(angle+delta)/s.travelDegrees; plan.degrees[i]=angle+delta
    plan.predicted=plan.predicted*M.ratio(plan.positions[i])/M.ratio(saved)
  end
  plan.err=math.abs(plan.predicted-target)
  return plan
end
return M
