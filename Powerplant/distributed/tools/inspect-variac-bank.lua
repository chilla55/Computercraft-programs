-- Read-only maintenance inspection. Never closes breakers or moves shafts.
-- This is NOT an atomic bank snapshot or an energized movement test.
local stage=(... or 'C'):upper()
assert(stage=='A' or stage=='B' or stage=='C','Usage: inspect-variac-bank [A|B|C]')
local path='/config/distributed-node.json'
local file=assert(fs.open(path,'r'),'Missing '..path)
local node=textutils.unserializeJSON(file.readAll()); file.close()
assert(type(node)=='table' and node.role=='master','Run this on the configured master')
local s=assert(node.config and node.config.settings,'Missing transformer settings')
local function now() return os.epoch('utc') end
local report={schema=1,kind='read_only_bank_inspection',stage=stage,startedAt=now(),
  atomic=false,movementTest=false,contacts={},drives={},members={},
  limitation='Sequential API readings. No internal coupling/current API assumed. Cannot establish alignment during movement.'}
local function read(name,method)
  local started=now()
  local ok,value=pcall(function()
    local p=assert(peripheral.wrap(name),'Missing peripheral '..name)
    assert(type(p[method])=='function','Missing method '..method)
    return p[method]()
  end)
  local result={ok=ok,startedAt=started,finishedAt=now()}
  if ok then result.value=value else result.error=tostring(value) end
  return result
end
local names={}
for _,name in ipairs(s.inputBreakers) do names[#names+1]=name end
names[#names+1]=s.plusBreaker; names[#names+1]=s.minusBreaker
local function interlocks()
  for _,name in ipairs(names) do
    local v=read(name,'isClosed'); report.contacts[name]=v
    assert(v.ok and v.value==false,'Maintenance required: cannot verify open breaker '..name)
  end
  for _,key in ipairs({'A','B','C'}) do
    local name=s['gear'..key]; local v=read(name,'isRunning'); report.drives[name]=v
    assert(v.ok and v.value==false,'Cannot verify idle gearbox '..name)
  end
end
local ok,why=pcall(function()
  interlocks()
  for _,name in ipairs(assert(s['variacs'..stage],'Missing bank mapping')) do
    local member={name=name,samples={}}; report.members[#report.members+1]=member
    local methodsOk,methods=pcall(peripheral.getMethods,name)
    member.methods=methodsOk and methods or nil
    member.methodsError=not methodsOk and tostring(methods) or nil
  end
  for sample=1,3 do
    interlocks()
    for _,member in ipairs(report.members) do
      member.samples[#member.samples+1]={status=read(member.name,'getStatus'),thermal=read(member.name,'getThermalStatus')}
    end
    interlocks()
    if sample<3 then sleep(.1) end
  end
end)
report.completed=ok; report.error=not ok and tostring(why) or nil; report.finishedAt=now()
local destination='/config/variac-bank-inspection.json'
local out=assert(fs.open(destination,'w')); out.write(textutils.serializeJSON(report)); out.close()
print('Read-only bank '..stage..' inspection: '..(ok and 'captured' or 'aborted'))
print('No movement or breaker commands were issued.')
print('Sequential readings; NOT the atomic addon diagnostic.')
print('Report: '..destination)
if not ok then print(tostring(why)) end
