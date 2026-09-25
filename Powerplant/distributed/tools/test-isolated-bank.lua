-- Standalone master maintenance test using normal peripherals only.
-- Homes selected banks to minimum and leaves them there. NEVER closes contacts.
local VERSION='isolated-bank-4'
print('Diagnostic version: '..VERSION)
local stage=(... or 'C'):upper()
assert(stage=='A' or stage=='B' or stage=='C' or stage=='ALL','Usage: test-isolated-bank [A|B|C|ALL]')
local f=assert(fs.open('/config/distributed-node.json','r'),'Missing node configuration')
local node=textutils.unserializeJSON(f.readAll()); f.close()
assert(node and node.role=='master','Run on the master with the UI stopped in maintenance')
local s=assert(node.config and node.config.settings)
local groups,selected,members,memberStage,seen={},{},{},{},{}
for _,key in ipairs({'A','B','C'}) do
 if stage=='ALL' or stage==key then
  groups[#groups+1]=key; selected[key]=true
  assert(not seen[s['gear'..key]],'Duplicate gearbox mapping'); seen[s['gear'..key]]=true
  local bank=assert(s['variacs'..key]); assert(#bank>0,'Empty bank '..key)
  for _,name in ipairs(bank) do assert(not seen[name],'Duplicate member mapping: '..name); seen[name]=true; members[#members+1]=name; memberStage[name]=key end
 end
end
local contacts={}; for _,name in ipairs(s.inputBreakers) do contacts[#contacts+1]=name end
contacts[#contacts+1]=s.plusBreaker; contacts[#contacts+1]=s.minusBreaker
local function now() return os.epoch('utc') end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
assert(finite(s.travelDegrees) and s.travelDegrees>=160,'Invalid travel range')
local report={schema=1,version=VERSION,kind='isolated_bank_motion',stage=stage,members=members,startedAt=now(),
 atomic=false,moves={},samples={},droppedSamples=0,completed=false,
 limitation='Sequential position samples; cannot prove equal positions within a game tick or reproduce energized circuit behavior.'}
-- CC:Tweaked JSON rejects repeated table identities, even without cycles.
local function copy(value,active,path)
 if type(value)=='number' and not finite(value) then return tostring(value) end
 if type(value)~='table' then return value end
 active=active or {}; path=path or '$'
 assert(not active[value],VERSION..': circular table at '..path)
 active[value]=true
 local result={}
 for k,v in pairs(value) do result[k]=copy(v,active,path..'.'..tostring(k)) end
 active[value]=nil
 return result
end
local function endpoint(snapshot)
 local result={at=snapshot.at,finishedAt=snapshot.finishedAt,aligned=snapshot.aligned,stationary=snapshot.stationary,spreadDegrees=snapshot.spreadDegrees,members={}}
 for i,entry in ipairs(snapshot.members) do
  result.members[i]={name=entry.name,stage=entry.stage,position=entry.status.position,shaftSpeed=entry.status.shaftSpeed,temperature=entry.thermal.temperature}
 end
 return result
end
local destination='/config/isolated-bank-test.json'
local function save()
 local ok,encoded=pcall(function() return textutils.serializeJSON(copy(report)) end)
 assert(ok,VERSION..': report serialization failed: '..tostring(encoded))
 local out=assert(fs.open(destination..'.tmp','w')); out.write(encoded); out.close()
 if fs.exists(destination) then fs.delete(destination) end
 fs.move(destination..'.tmp',destination)
end
local function device(name) return assert(peripheral.wrap(name),'Missing peripheral '..name) end
local function isolation()
 for _,name in ipairs(contacts) do assert(device(name).isClosed()==false,'Isolation lost: '..name) end
end
local function openAll()
 local errors={}
 for _,name in ipairs(contacts) do local ok,why=pcall(function() device(name).open() end); if not ok then errors[#errors+1]=tostring(why) end end
 for _,name in ipairs(contacts) do local ok,why=pcall(function() assert(device(name).isClosed()==false,'Not open: '..name) end); if not ok then errors[#errors+1]=tostring(why) end end
 return #errors==0,table.concat(errors,'; ')
end
local baseline={}
local activeMove
local sampleNumber=0
local function snapshot(label,justCommanded)
 -- Immediately after rotate(), read the selected bank before scanning other
 -- peripherals. Otherwise check contacts first. Every round rechecks isolation.
 if not justCommanded then isolation() end
 sampleNumber=sampleNumber+1
 local item={at=now(),label=label,members={},readOrder=sampleNumber%2==0 and 'reverse' or 'forward'}
 local limits={}; for _,key in ipairs(groups) do limits[key]={low=1,high=0,moving=false} end
 item.stationary=true; item.shaftMoving=false
 report.samples[#report.samples+1]=item
 if #report.samples>32 then table.remove(report.samples,2); report.droppedSamples=report.droppedSamples+1 end
 for offset=1,#members do
  local i=item.readOrder=='reverse' and #members-offset+1 or offset
  local name=members[i]; local entry={name=name,stage=memberStage[name],startedAt=now()}; item.members[i]=entry
  local v=device(name).getStatus(); entry.status=copy(v); entry.positionReadAt=now()
  assert(type(v)=='table' and finite(v.position) and v.position>=0 and v.position<=1 and finite(v.shaftSpeed),'Invalid position/speed '..name)
  item.stationary=item.stationary and v.shaftSpeed==0
  item.shaftMoving=item.shaftMoving or v.shaftSpeed~=0
  local bank=limits[memberStage[name]]; bank.low=math.min(bank.low,v.position); bank.high=math.max(bank.high,v.position); bank.moving=bank.moving or v.shaftSpeed~=0
 end
 item.banks={}; item.spreadDegrees=0; item.aligned=true; item.gearRunning=false
 for _,key in ipairs(groups) do
  local bank=limits[key]
  local running=device(s['gear'..key]).isRunning()
  assert(type(running)=='boolean','Invalid gearbox status '..key)
  local spread=(bank.high-bank.low)*s.travelDegrees
  item.banks[key]={spreadDegrees=spread,aligned=bank.high==bank.low,gearRunning=running,shaftMoving=bank.moving}
  item.spreadDegrees=math.max(item.spreadDegrees,spread)
  item.aligned=item.aligned and bank.high==bank.low
  item.gearRunning=item.gearRunning or running
 end
 item.stationary=item.stationary and not item.gearRunning
 if activeMove then
  for _,key in ipairs(groups) do
   local bank=item.banks[key]; local stats=activeMove.banks[key]
   stats.samples=stats.samples+1
   if bank.shaftMoving then stats.shaftMovingSamples=stats.shaftMovingSamples+1 end
   stats.maxObservedSpreadDegrees=math.max(stats.maxObservedSpreadDegrees,bank.spreadDegrees)
  end
  activeMove.samples=activeMove.samples+1
  if item.shaftMoving then activeMove.shaftMovingSamples=activeMove.shaftMovingSamples+1 end
  activeMove.maxObservedSpreadDegrees=math.max(activeMove.maxObservedSpreadDegrees,item.spreadDegrees)
 end
 -- Read all selected positions back-to-back before temperature and other banks.
 for i,name in ipairs(members) do
  local entry=item.members[i]; local t=device(name).getThermalStatus()
  entry.thermal=copy(t); entry.finishedAt=now()
  assert(t and t.available==true and t.unit=='C' and finite(t.temperature),'Temperature unavailable '..name)
  assert(t.temperature<140,'Overtemperature '..name)
 end
 for _,key in ipairs({'A','B','C'}) do
  if not selected[key] then
   assert(device(s['gear'..key]).isRunning()==false,'Another bank drive moved: '..key)
   for _,name in ipairs(s['variacs'..key]) do
    local v=device(name).getStatus()
    assert(v.shaftSpeed==0 and finite(v.position),'Another bank not stationary: '..name)
    if baseline[name]==nil then baseline[name]=v.position end
    assert(v.position==baseline[name],'Another bank position changed: '..name)
   end
  end
 end
 item.finishedAt=now(); isolation()
 return item
end
local function settled(label,aligned,justCommanded)
 local deadline=now()+(s.moveTimeout or 30)*1000; local previous
 repeat
  local current=snapshot(label,justCommanded); justCommanded=false
  local stable=current.stationary and previous and previous.stationary
  if stable then
   for i,v in ipairs(current.members) do stable=stable and v.status.position==previous.members[i].status.position end
  end
  if stable then
   if aligned then
    for _,key in ipairs(groups) do assert(current.banks[key].aligned,'Parallel members misaligned in bank '..key..' after '..label) end
   end
   return current
  end
  previous=current
  assert(now()<deadline,'Movement timeout during '..label)
  sleep(.05)
 until false
end
local function move(label,degrees,direction,aligned)
 isolation()
 for _,key in ipairs(groups) do assert(device(s['gear'..key]).isRunning()==false,'Drive already running '..key) end
 local record={label=label,degrees=degrees,direction=copy(direction),bankStarts={},banks={},startedAt=now(),samples=0,shaftMovingSamples=0,maxObservedSpreadDegrees=0}
 for _,key in ipairs(groups) do record.banks[key]={samples=0,shaftMovingSamples=0,maxObservedSpreadDegrees=0} end
 report.moves[#report.moves+1]=record
 activeMove=record
 print(('Move %d: %s (%g deg)'):format(#report.moves,label,degrees))
 for _,key in ipairs(groups) do
  isolation()
  local modifier=type(direction)=='table' and direction[key] or direction
  record.bankStarts[key]={commandedAt=now(),direction=modifier}
  device(s['gear'..key]).rotate(degrees,modifier)
 end
 local after=settled(label,aligned,true); activeMove=nil; record.after=endpoint(after); record.finishedAt=now()
 save(); return after
end
print('ISOLATED bank '..stage..' movement test. All breakers must stay OPEN.')
print('Selected banks will be homed to minimum and left there. Ctrl+T aborts.')
local ok,why=pcall(function()
 local initial=settled('initial',false); report.initial=copy(initial)
 for _,entry in ipairs(initial.members) do assert(entry.thermal.temperature<=125,'Cool below 125 C before test') end
 save() -- Verify report serialization/storage before the first shaft command.
 -- Direction probe is allowed to start misaligned, but only in isolation.
 local probe=move('direction probe',3,1,false)
 local signs={}
 local function learn(before,after,command)
  local found={}
  for i,entry in ipairs(after.members) do
   local key=entry.stage
   local delta=entry.status.position-before.members[i].status.position
   if math.abs(delta)*s.travelDegrees>.2 then
    local candidate=delta>0 and command or -command
    assert(not found[key] or found[key]==candidate,'Members move in opposite directions: '..key)
    found[key]=candidate
   end
  end
  for key,value in pairs(found) do
   assert(not signs[key] or signs[key]==value,'Inconsistent gearbox direction: '..key)
   signs[key]=value
  end
 end
 learn(initial,probe,1)
 local missing=false; for _,key in ipairs(groups) do missing=missing or not signs[key] end
 if missing then
  local before=probe; probe=move('reverse direction probe',3,-1,false)
  learn(before,probe,-1)
 end
 local down={}
 for _,key in ipairs(groups) do assert(signs[key],'No member moved during direction probes: '..key); down[key]=-signs[key] end
 report.increasingDirections=copy(signs); report.increasingDirection=signs[stage]
 local home=move('home minimum',math.ceil(s.travelDegrees)+3,down,true)
 for _,entry in ipairs(home.members) do assert(entry.status.position*s.travelDegrees<=.1,'Member did not home: '..entry.name) end
 report.homed=copy(home)
 local plan={}
 local plannedAngle=0
 local function destination(label,angle)
  angle=math.floor(angle+.5)
  assert(angle>=0 and angle<=s.travelDegrees,'Test destination outside configured travel')
  if angle~=plannedAngle then plan[#plan+1]={label=label,angle=angle}; plannedAngle=angle end
 end
 local function relative(label,delta) destination(label,plannedAngle+delta) end
 for _,fraction in ipairs({.1,.5,.9}) do
  destination('short-test anchor '..fraction,s.travelDegrees*fraction)
  for _,degrees in ipairs({1,2,4}) do
   for _,delta in ipairs({degrees,-degrees,-degrees,degrees}) do relative('short reversal '..fraction,delta) end
  end
 end
 destination('medium-test anchor',s.travelDegrees*.5)
 for _,degrees in ipairs({8,16,32,64}) do
  for _,delta in ipairs({degrees,-degrees,-degrees,degrees}) do relative('medium reversal',delta) end
 end
 for _,fraction in ipairs({1,0,.9,.1,.75,.25,1,.5,0}) do destination('long traverse '..fraction,s.travelDegrees*fraction) end
 destination('mixed-test anchor',s.travelDegrees*.5)
 for repetition=1,2 do
  for _,delta in ipairs({1,16,-2,-64,8,32,-1,64,-16,-32,2,-8}) do relative('mixed sequence '..repetition,delta) end
 end
 destination('return to minimum',0)
 report.plan=copy(plan); report.plannedTestMoves=#plan; report.completedTestMoves=0
 save()
 for index,step in ipairs(plan) do
  local before=settled('before '..step.label,true)
  local angle=before.members[1].status.position*s.travelDegrees
  local delta=math.floor(step.angle-angle+.5)
  assert(delta~=0,'Unexpected duplicate destination')
  local directions={}
  for _,key in ipairs(groups) do directions[key]=(delta>0 and 1 or -1)*signs[key] end
  local after=move(('%d/%d %s -> %d deg'):format(index,#plan,step.label,step.angle),math.abs(delta),directions,true)
  for i,entry in ipairs(after.members) do
   local actual=(entry.status.position-before.members[i].status.position)*s.travelDegrees
   assert(actual*delta>0,'Member failed to move in commanded direction: '..entry.name)
   assert(math.abs(actual-delta)<=math.max(.02,s.positionToleranceDegrees or 1),'Incorrect travel: '..entry.name)
   assert(math.abs(entry.status.position*s.travelDegrees-step.angle)<=math.max(.02,s.positionToleranceDegrees or 1),'Incorrect endpoint: '..entry.name)
  end
  report.completedTestMoves=index
  isolation(); save()
 end
 report.coverage={movesWithShaftSamples=0,movesWithoutShaftSamples=0,banks={}}
 for _,key in ipairs(groups) do report.coverage.banks[key]={movesWithShaftSamples=0,movesWithoutShaftSamples=0} end
 for _,record in ipairs(report.moves) do
  local key=record.shaftMovingSamples>0 and 'movesWithShaftSamples' or 'movesWithoutShaftSamples'
  report.coverage[key]=report.coverage[key]+1
  for bank,stats in pairs(record.banks) do
   local field=stats.shaftMovingSamples>0 and 'movesWithShaftSamples' or 'movesWithoutShaftSamples'
   report.coverage.banks[bank][field]=report.coverage.banks[bank][field]+1
  end
 end
 report.final=copy(settled('final minimum',true))
 for _,entry in ipairs(report.final.members) do assert(entry.status.position*s.travelDegrees<=.1,'Final position not minimum') end
 report.completed=true
end)
-- Abort/termination never starts another movement. An issued native sequence
-- may still finish, with all contacts commanded open before any report I/O.
local opened,openError=openAll()
report.openVerified=opened; report.openError=not opened and openError or nil
report.completed=ok and opened; report.error=not ok and tostring(why) or not opened and openError or nil
report.finishedAt=now()
local saved,saveError=pcall(save)
if not saved then
 print(VERSION..': could not save '..destination..': '..tostring(saveError))
 if report.error then print('Original abort: '..report.error) end
 return
end
print(report.completed and ('PASS: homed and completed %d isolated test movements.'):format(report.completedTestMoves or 0) or 'ABORTED: '..tostring(report.error))
print('Report: '..destination)
print('Leave in maintenance. No energized behavior was tested.')
