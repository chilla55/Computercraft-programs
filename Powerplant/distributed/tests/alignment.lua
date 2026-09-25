local U=dofile('Powerplant/distributed/common.lua')
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local positions={a1=.5,a2=.5,b=.2,c=.8}
peripheral={wrap=function(name) return {getStatus=function() local p=positions[name]; return {position=p,ratio=.01+.99*p} end} end}
local s={variacsA={'a1','a2'},variacsB={'b'},variacsC={'c'},travelDegrees=315,positionToleranceDegrees=1}
check(pcall(U.aligned,s),'different series stages incorrectly rejected')
positions.a2=.500001
check(not pcall(U.aligned,s),'small parallel spread accepted')
s.positionToleranceDegrees=100
check(not pcall(U.aligned,s),'movement tolerance bypassed bank alignment')
positions.a2=.5; s.positionToleranceDegrees=0
check(pcall(U.aligned,s),'identical members rejected')
print(('PASS: %d exact bank alignment checks'):format(n))
