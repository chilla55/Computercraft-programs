local U=dofile('Powerplant/distributed/common.lua')
local n=0
local function check(v,m) assert(v,m); n=n+1 end
local primary,source,closed=0,7140.4,true
local reads=0
peripheral={wrap=function(name)
 if name=='input' then return {isClosed=function() return closed end} end
 return {voltage=function() reads=reads+1; if name=='vin' then return primary else return source end end}
end}
local s={inputGauge='vin',sourceGauge='source',entryRatio=5,maxInputVolts=2700,inputBreakers={'input'}}
local reader=U.inputReader(s)
local value,estimated=reader('cycle','live')
check(math.abs(value-1428.08)<1e-6 and estimated,'source ratio fallback wrong')
local ok,why=pcall(reader,'cycle','live')
check(not ok and why:find('second consecutive',1,true),'second zero did not trip')
primary=1448
value,estimated=reader('cycle','live')
check(value==1448 and not estimated,'valid primary did not restore direct reading')
primary=0; check(reader('cycle','live')>1,'recovered primary did not reset allowance')
check(reader('new-cycle','live')>1,'new cycle retained old failure count')
primary=2800; reads=0
check(not pcall(reader,'over','live') and reads==1,'overvoltage used fallback')
primary=0; source=0
check(not pcall(reader,'dead','live'),'dead source accepted')
source=14000
check(not pcall(reader,'source-over','live'),'source overvoltage accepted')
source=7140.4; closed=false
check(not pcall(reader,'open','live'),'open contact accepted')
closed=true; s.sourceGauge=''
check(not pcall(U.inputReader(s),'unconfigured','live'),'unconfigured fallback accepted')
s.sourceGauge='source'; primary=0/0
check(not pcall(reader,'invalid','live'),'invalid native reading accepted')
s.preStepUpGauge='pre'; s.outputGauge='vin'; s.stepUp=2.5
primary=0; source=1056
local outputReader=U.outputReader(s)
value,estimated=outputReader('output','live',2904)
check(value==2640 and estimated,'pre-exit multiplier wrong')
check(not pcall(outputReader,'output','live',2904),'second output zero did not trip')
primary=2640
value,estimated=outputReader('output','live',2904)
check(value==2640 and not estimated,'output gauge did not recover')
primary=0; source=1200
check(not pcall(outputReader,'output-over','live',2904),'estimated output overvoltage accepted')
print(('PASS: %d input fallback checks'):format(n))
