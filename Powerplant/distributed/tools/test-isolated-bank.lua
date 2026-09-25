-- Standalone master maintenance test using normal peripherals only.
-- Homes ONE bank to minimum and leaves it there. NEVER closes contacts.
local stage=(... or 'C'):upper()
assert(stage=='A' or stage=='B' or stage=='C','Usage: test-isolated-bank [A|B|C]')
local f=assert(fs.open('/config/distributed-node.json','r'),'Missing node configuration')
local node=textutils.unserializeJSON(f.readAll()); f.close()
assert(node and node.role=='master','Run on the master with the UI stopped in maintenance')
local s=assert(node.config and node.config.settings)
local members=assert(s['variacs'..stage]); assert(#members>0,'Empty bank')
local contacts={}; for _,name in ipairs(s.inputBreakers) do contacts[#contacts+1]=name end
contacts[#contacts+1]=s.plusBreaker; contacts[#contacts+1]=s.minusBreaker
local gearName=s['gear'..stage]
local function now() return os.epoch('utc') end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
assert(finite(s.travelDegrees) and s.travelDegrees>=16,'Invalid travel range')
local report={schema=1,kind='isolated_bank_motion',stage=stage,members=members,startedAt=now(),
 atomic=false,moves={},samples={},droppedSamples=0,completed=false,
 limitation='Sequential position samples; cannot prove equal positions within a game tick or reproduce energized circuit behavior.'}
-- CC:Tweaked JSON rejects repeated table identities, even without cycles.
local function copy(value)
 if type(value)~='table' then return value end
 local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
local destination='/config/isolated-bank-test.json'
local function save()
 local encoded=textutils.serializeJSON(report)
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
local function snapshot(label)
 isolation()
 local item={at=now(),label=label,members={},gearRunning=device(gearName).isRunning()}
 assert(type(item.gearRunning)=='boolean','Invalid gearbox status')
 item.stationary=not item.gearRunning
 for _,key in ipairs({'A','B','C'}) do
  if key~=stage then
   assert(device(s['gear'..key]).isRunning()==false,'Another bank drive moved: '..key)
   for _,name in ipairs(s['variacs'..key]) do
    local v=device(name).getStatus()
    assert(v.shaftSpeed==0 and finite(v.position),'Another bank not stationary: '..name)
    if baseline[name]==nil then baseline[name]=v.position end
    assert(v.position==baseline[name],'Another bank position changed: '..name)
   end
  end
 end
 local lo,hi=1,0
 report.samples[#report.samples+1]=item
 if #report.samples>128 then table.remove(report.samples,2); report.droppedSamples=report.droppedSamples+1 end
 for _,name in ipairs(members) do
  local entry={name=name,startedAt=now()}; item.members[#item.members+1]=entry
  local p=device(name); local v=p.getStatus(); entry.status=v
  assert(type(v)=='table' and finite(v.position) and v.position>=0 and v.position<=1 and finite(v.shaftSpeed),'Invalid position/speed '..name)
  item.stationary=item.stationary and v.shaftSpeed==0
  lo=math.min(lo,v.position); hi=math.max(hi,v.position)
  local t=p.getThermalStatus(); entry.thermal=t; entry.finishedAt=now()
  assert(t and t.available==true and t.unit=='C' and finite(t.temperature),'Temperature unavailable '..name)
  assert(t.temperature<140,'Overtemperature '..name)
 end
 item.spreadDegrees=(hi-lo)*s.travelDegrees; item.aligned=hi==lo; item.finishedAt=now()
 isolation()
 return item
end
local function settled(label,aligned)
 local deadline=now()+(s.moveTimeout or 30)*1000; local previous
 repeat
  local current=snapshot(label)
  local stable=current.stationary and previous and previous.stationary
  if stable then
   for i,v in ipairs(current.members) do stable=stable and v.status.position==previous.members[i].status.position end
  end
  if stable then
   assert(not aligned or current.aligned,'Parallel members misaligned after '..label)
   return current
  end
  previous=current
  assert(now()<deadline,'Movement timeout during '..label)
  sleep(.05)
 until false
end
local function move(label,degrees,direction,aligned)
 isolation()
 assert(device(gearName).isRunning()==false,'Drive already running')
 local record={label=label,degrees=degrees,direction=direction,startedAt=now()}
 report.moves[#report.moves+1]=record
 device(gearName).rotate(degrees,direction)
 sleep(.05)
 local after=settled(label,aligned); record.after=copy(after); record.finishedAt=now()
 save(); return after
end
print('ISOLATED bank '..stage..' movement test. All breakers must stay OPEN.')
print('Both members will be homed to minimum and left there. Ctrl+T aborts.')
local ok,why=pcall(function()
 local initial=settled('initial',false); report.initial=copy(initial)
 for _,entry in ipairs(initial.members) do assert(entry.thermal.temperature<=125,'Cool below 125 C before test') end
 -- Direction probe is allowed to start misaligned, but only in isolation.
 local probe=move('direction probe',3,1,false)
 local sign
 for i,entry in ipairs(probe.members) do
  local delta=entry.status.position-initial.members[i].status.position
  if math.abs(delta)*s.travelDegrees>.2 then
   local candidate=delta>0 and 1 or -1
   assert(not sign or sign==candidate,'Members move in opposite directions'); sign=candidate
  end
 end
 if not sign then
  local before=probe; probe=move('reverse direction probe',3,-1,false)
  for i,entry in ipairs(probe.members) do
   local delta=entry.status.position-before.members[i].status.position
   if math.abs(delta)*s.travelDegrees>.2 then
    local candidate=delta>0 and -1 or 1
    assert(not sign or sign==candidate,'Members move in opposite directions'); sign=candidate
   end
  end
 end
 assert(sign,'No member moved during direction probes')
 report.increasingDirection=sign
 local home=move('home minimum',math.ceil(s.travelDegrees)+3,-sign,true)
 for _,entry in ipairs(home.members) do assert(entry.status.position*s.travelDegrees<=.1,'Member did not home: '..entry.name) end
 report.homed=copy(home)
 for _,degrees in ipairs({1,2,8,16}) do
  for repetition=1,2 do
   for _,delta in ipairs({degrees,-degrees}) do
    local before=settled('before step',true)
    local after=move(('test %+.0f deg repeat %d'):format(delta,repetition),math.abs(delta),(delta>0 and sign or -sign),true)
    for i,entry in ipairs(after.members) do
     local actual=(entry.status.position-before.members[i].status.position)*s.travelDegrees
     assert(actual*delta>0,'Member failed to move in commanded direction: '..entry.name)
     assert(math.abs(actual-delta)<=math.max(.02,s.positionToleranceDegrees or 1),'Incorrect travel: '..entry.name)
    end
    isolation()
   end
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
report.finishedAt=now(); save()
print(report.completed and 'PASS: homed and completed 16 isolated test movements.' or 'ABORTED: '..tostring(report.error))
print('Report: '..destination)
print('Leave in maintenance. No energized behavior was tested.')
