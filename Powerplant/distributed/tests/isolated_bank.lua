local count=0
local function check(v,m) assert(v,m); count=count+1 end
local function run(options)
 options=options or {}
 local time,moves,files,report=0,{},{}
 local sharedStatus,sharedThermal,sharedExtra={},{},{}
 local pending={}
 local positions={a=.5,b=.6,c1=options.atMaximum and 1 or .3,c2=options.atMaximum and 1 or .8}
 local contacts={input=options.closed or false,plus=false,minus=false}; local opens={}
 local settings={inputBreakers={'input'},plusBreaker='plus',minusBreaker='minus',gearA='ga',gearB='gb',gearC='gc',variacsA={'a'},variacsB={'b'},variacsC={'c1','c2'},travelDegrees=315,moveTimeout=1,positionToleranceDegrees=1}
 local env=setmetatable({},{__index=_G})
 env.os={epoch=function() time=time+1; return time end}; env.print=function() end
 env.sleep=function(dt) time=time+dt*1000; if options.terminate and #moves>0 then options.terminate=false; error('Terminated') end end
 env.textutils={unserializeJSON=function() return {role='master',config={settings=settings}} end,serializeJSON=function(v)
  local seen={}
  local function visit(item)
   if type(item)~='table' then return end
   assert(not seen[item],'Cannot serialize table with repeated entries')
   seen[item]=true; for _,child in pairs(item) do visit(child) end
  end
  visit(v); report=v; return 'report'
 end}
 env.fs={exists=function(p) return files[p]~=nil end,delete=function(p) files[p]=nil end,move=function(a,b) files[b]=files[a];files[a]=nil end,
 open=function(p,mode) return {readAll=function() return 'config' end,write=function(v) files[p]=v end,close=function() end} end}
 env.peripheral={wrap=function(name)
  if options.missing==name then return nil end
  if contacts[name]~=nil then return {isClosed=function() return contacts[name] end,open=function() contacts[name]=false; opens[#opens+1]=name end,close=function() error('must not close') end} end
  if name:sub(1,1)=='g' then return {isRunning=function() return false end,rotate=function(degrees,direction)
   check(options.all or name=='gc','another bank moved'); moves[#moves+1]={gear=name,degrees=degrees,direction=direction}
   for _,n in ipairs(name=='ga' and {'a'} or name=='gb' and {'b'} or {'c1','c2'}) do
    if not (options.jam and n=='c2') then
     local sign=(options.reverse or options.all and name=='gb') and -1 or 1
     if options.opposite and n=='c2' then sign=-sign end
     local target=math.max(0,math.min(1,positions[n]+degrees*direction*sign/315))
     if options.async then pending[n]={from=positions[n],target=target,start=time,finish=time+180}
     else positions[n]=target end
    end
   end
   if options.loseIsolation then contacts.input=true end
  end} end
  return {getStatus=function()
   local motion=pending[name]
   if motion then
    local fraction=math.min(1,(time-motion.start)/(motion.finish-motion.start))
    positions[name]=motion.from+(motion.target-motion.from)*fraction
    if fraction>=1 then pending[name]=nil end
   end
   local v=options.shared and sharedStatus or {}
   v.position=positions[name]; v.shaftSpeed=(options.stuck or pending[name]) and 32 or 0
   if options.shared then v.extra={first=sharedExtra,second=sharedExtra} end
   if options.cycle then v.extra=v end
   return v
  end, getThermalStatus=function()
   local v=options.shared and sharedThermal or {}
   v.available=true; v.unit='C'; v.temperature=options.hot and #moves>0 and 145 or 20
   return v
  end}
 end}
 assert(loadfile('Powerplant/distributed/tools/test-isolated-bank.lua','t',env))(options.all and 'ALL' or 'C')
 return report,moves,contacts,opens
end
for _,options in ipairs({{}, {reverse=true},{atMaximum=true},{shared=true},{all=true},{all=true,async=true}}) do
 local r,m,c=run(options)
 check(r.completed and r.openVerified,'isolated test failed')
 check(r.version=='isolated-bank-4','report lacks diagnostic version')
 check(r.initial.members[1].status.position==(options.all and .5 or options.atMaximum and 1 or .3),'earlier sample changed after later reads')
 check(r.plannedTestMoves>=90 and r.completedTestMoves==r.plannedTestMoves,'full profile incomplete')
 check(#m==#r.moves*(options.all and 3 or 1),'selected banks did not receive the same sequence')
 local high,low,short,medium,long,mixed=false,false,false,false,false,false
 for _,step in ipairs(r.plan) do
  high=high or step.angle==315; low=low or step.angle==0
  short=short or step.label:find('short',1,true); medium=medium or step.label:find('medium',1,true)
  long=long or step.label:find('long',1,true); mixed=mixed or step.label:find('mixed',1,true)
 end
 check(high and low and short and medium and long and mixed,'missing travel/profile coverage')
 if options.async then
  for _,key in ipairs({'A','B','C'}) do check(r.coverage.banks[key].movesWithShaftSamples>0,'asynchronous bank movement not sampled: '..key) end
 end
 if options.all then check(r.increasingDirections.A==1 and r.increasingDirections.B==-1 and r.increasingDirections.C==1,'independent bank directions lost') end
 check(r.final.members[1].status.position<1e-8 and r.final.aligned,'bank not left aligned at minimum')
 check(not c.input and not c.plus and not c.minus,'contacts not open')
end
for _,options in ipairs({{jam=true},{opposite=true},{closed=true},{missing='c2'},{loseIsolation=true},{terminate=true},{hot=true},{stuck=true},{cycle=true},{all=true,jam=true},{all=true,loseIsolation=true},{all=true,missing='c2'}}) do
 local r,m,c,opens=run(options)
 check(not r.completed and r.error,'fault did not abort')
 check(not c.input and not c.plus and not c.minus,'fault did not isolate')
 check(opens[1]=='input','fault did not prioritize source opening')
 if options.closed or options.missing or options.stuck or options.cycle then check(#m==0,'moved without valid precheck') end
 if options.terminate or options.hot or options.loseIsolation then check(#m==1,'movement continued after abort condition') end
end
print(('PASS: %d isolated bank diagnostic checks'):format(count))
