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
local count,maxError=0,0
for line in io.lines('Powerplant/distributed/tests/fixtures/variac-calibration.tsv') do
 local angle,input,output=line:match('^(%d+)%s+([%d%.]+)%s+([%d%.]+)')
 if angle then
  count=count+1
  maxError=math.max(maxError,math.abs(P.ratio(1-tonumber(angle)/315)-tonumber(output)/tonumber(input)))
 end
end
check(count==316 and maxError<2e-7,'planner does not match supplied single-variac calibration')
print(('PASS: %d calculated startup planner checks'):format(n))
