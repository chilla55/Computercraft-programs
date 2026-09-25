-- Same calibrated whole-degree search as the standalone regulator, pure inputs.
local M={}
function M.ratio(p) return .00999996389330349+.989990071137444*p end
function M.choose(s,banks,input,output,target,limit,yieldFn)
  local angle,lo,hi={},{},{}
  local product=1
  for i=1,3 do angle[i]=banks[i].position*s.travelDegrees; product=product*M.ratio(banks[i].position); lo[i]=math.max(-limit,math.ceil(-angle[i])); hi[i]=math.min(limit,math.floor(s.travelDegrees-angle[i])) end
  local basis=output and output>1 and output/product or input*s.stepUp
  local best
  local function consider(a,b,c)
    if c<lo[3] or c>hi[3] then return end
    local predicted=basis*M.ratio((angle[1]+a)/s.travelDegrees)*M.ratio((angle[2]+b)/s.travelDegrees)*M.ratio((angle[3]+c)/s.travelDegrees)
    local err,travel=math.abs(predicted-target),math.abs(a)+math.abs(b)+math.abs(c)
    local inside=err<=s.accuracyVolts/2
    if not best or (inside and not best.inside) or (inside==best.inside and ((inside and (travel<best.travel or travel==best.travel and err<best.err)) or (not inside and err<best.err))) then
      best={a,b,c,err=err,travel=travel,predicted=predicted,inside=inside}
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
    end
    rows=rows+1; if rows%8==0 and yieldFn then yieldFn() end
  end
  return assert(best,'No available variac setting')
end
return M
