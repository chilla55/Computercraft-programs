local P=dofile('Powerplant/distributed/planner.lua')
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local s={travelDegrees=315,stepUp=2.5,accuracyVolts=.1}
for _,case in ipairs({{1500,2640,{0,0,0}},{2794,2640,{.12345,.54321,.98765}},{1200,2300,{.8,.9,.99}}}) do
 local input,target,positions=table.unpack(case)
 local banks={}; for i,p in ipairs(positions) do banks[i]={position=p} end
 local yields=0
 local plan=P.initial(s,banks,input,nil,target,function() yields=yields+1 end)
 local output=input*s.stepUp
 for i=1,3 do
  check(plan.positions[i]>=0 and plan.positions[i]<=1,'destination outside travel')
  check(plan[i]%1==0 and math.abs(plan.positions[i]-(positions[i]+plan[i]/315))<1e-12,'destination not reachable with calculated whole-degree command')
  output=output*P.ratio(plan.positions[i])
 end
 check(math.abs(output-plan.predicted)<1e-8 and math.abs(output-target)<=1,'calculated positions do not produce target')
 check(yields>0 and yields<=40,'planner did not yield within bounded search')
end
local banks={{position=.5},{position=.5},{position=.5}}
local measured=1500*2.5*.95*P.ratio(.5)^3
local corrected=P.initial(s,banks,1500,measured,2640)
local output=1500*2.5*.95
for _,p in ipairs(corrected.positions) do output=output*P.ratio(p) end
check(math.abs(output-2640)<=1,'measured correction did not account for ratio error')
local impossible=P.initial(s,banks,500,nil,2640)
check(impossible.err>1,'unreachable target appears reachable')
-- The former 90/90/70 preset must not win merely because it needs no
-- movement; choose a tighter cluster while preserving the voltage band.
local uneven={{position=.9},{position=.9},{position=.7}}
local target=1500*s.stepUp*P.ratio(.9)^2*P.ratio(.7)
local balanced=P.initial(s,uneven,1500,nil,target)
check(balanced.err<=s.accuracyVolts/2 and balanced.spread<20,'startup retained widely separated banks')
-- Exhaustive independent search on a small travel range, including a wide
-- acceptable band where the best-balanced C is not nearest the exact target.
for _,accuracy in ipairs({.1,50,500}) do
 local small={travelDegrees=12,stepUp=2.5,accuracyVolts=accuracy}
 local b={{position=.1},{position=.5},{position=.8}}
 local p=P.initial(small,b,1500,nil,900)
 local best
 for a=0,11 do for bb=0,12 do for c=0,11 do
  local angles={.2+a,bb,.6+c}
  local output=3750
  for _,angle in ipairs(angles) do output=output*P.ratio(angle/12) end
  local err=math.abs(output-900)
  local spread=math.max(table.unpack(angles))-math.min(table.unpack(angles))
  if err<=accuracy/2 and (not best or spread<best) then best=spread end
 end end end
 if best then check(p.inside and math.abs(p.spread-best)<1e-8,'planner missed most balanced in-band destination') end
end
local count,maxError=0,0
for line in io.lines('Powerplant/distributed/tests/fixtures/variac-calibration.tsv') do
 local angle,input,output=line:match('^(%d+)%s+([%d%.]+)%s+([%d%.]+)')
 if angle then
  count=count+1
  maxError=math.max(maxError,math.abs(P.ratio(1-tonumber(angle)/315)-tonumber(output)/tonumber(input)))
 end
end
check(count==316 and maxError<2e-7,'planner does not match supplied single-variac calibration')
local settings={travelDegrees=315,stepUp=2.5,accuracyVolts=.1,fallbackVolts=1}
local entry={schema=1,key='hardware',target=2640,input=1450,output=2640,positions={.854,.851,.854}}
local start={{position=.2},{position=.3},{position=.4}}
local cached=P.cached(settings,start,entry,1450,2640,'hardware')
check(cached and cached.travel>0,'valid learned preset not available')
for i=1,3 do check(math.abs(cached.positions[i]-entry.positions[i])*315<=.5,'cached destination not nearest reachable position') end
check(not P.cached(settings,start,entry,1500,2640,'hardware'),'changed input reused preset')
check(not P.cached(settings,start,entry,1450,2400,'hardware'),'changed target reused preset')
check(not P.cached(settings,start,entry,1450,2640,'changed hardware'),'changed configuration reused preset')
entry.positions[2]=0/0
check(not P.cached(settings,start,entry,1450,2640,'hardware'),'invalid saved position accepted')
check(P.stable({input=1450,output=2640},1452,2644),'small variation stalls live feedback')
check(not P.stable({input=1450,output=2640},1500,2644),'unstable input accepted')
check(not P.stable({input=1450,output=2640},1450,2700),'unstable output accepted')
check(not P.stable(nil,1450,2640),'first reading accepted without verification')
print(('PASS: %d calculated startup planner checks'):format(n))
