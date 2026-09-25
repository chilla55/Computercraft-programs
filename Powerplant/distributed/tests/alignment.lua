local U=dofile('Powerplant/distributed/common.lua')
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local speeds={}
local positions={a1=.5,a2=.5,b=.2,c=.8}
peripheral={wrap=function(name) return {isRunning=function() return false end,getStatus=function() local p=positions[name]; return {position=p,ratio=.01+.99*p,shaftSpeed=speeds[name] or 0} end} end}
local s={gearA='ga',gearB='gb',gearC='gc',variacsA={'a1','a2'},variacsB={'b'},variacsC={'c'},travelDegrees=315,positionToleranceDegrees=1}
check(pcall(U.aligned,s),'different series stages incorrectly rejected')
positions.a2=.500001
check(not pcall(U.aligned,s),'small parallel spread accepted')
s.positionToleranceDegrees=100
check(not pcall(U.aligned,s),'movement tolerance bypassed bank alignment')
positions.a2=.5; s.positionToleranceDegrees=0
check(pcall(U.aligned,s),'identical members rejected')
positions.a2=.6; speeds.a1=32; speeds.a2=32
check(pcall(U.checkAlignment,s),'moving snapshot treated as static mismatch')
check(not pcall(U.aligned,s),'moving bank cleared for connection')
speeds.a1=0; speeds.a2=0
check(not pcall(U.checkAlignment,s),'stopped mismatch not detected')
speeds.a2=0/0
check(not pcall(U.checkAlignment,s),'invalid shaft speed accepted')
print(('PASS: %d exact bank alignment checks'):format(n))
