-- Same calibrated whole-degree search as the standalone regulator, pure inputs.
local M={}
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
