local files={}; local n=0
local function check(v,m) assert(v,m); n=n+1 end
local function serialize(v)
 if type(v)=='string' then return string.format('%q',v) end
 if type(v)~='table' then return tostring(v) end
 local rows={'{'}; for k,x in pairs(v) do rows[#rows+1]='['..serialize(k)..']='..serialize(x)..',' end
 rows[#rows+1]='}'; return table.concat(rows)
end
local env=setmetatable({fs={exists=function(p) return files[p]~=nil end,makeDir=function(p) files[p]=true end,
 getDir=function(p) return p:match('^(.*)/') or '' end,
 delete=function(p) files[p]=nil end,move=function(a,b) files[b]=assert(files[a]); files[a]=nil end,
 open=function(p,mode) if mode=='r' and not files[p] then return nil end
 return {readAll=function() return files[p] end,write=function(value) files[p]=value end,close=function() end} end},
 textutils={serializeJSON=serialize,unserializeJSON=function(s) local f=load('return '..s,'json','t',{}); return f and f() end}}, {__index=_G})
local U=assert(loadfile('Powerplant/distributed/common.lua','t',env))()
U.write('distributed-node.json',{revision=1})
check(files['/config/distributed-node.json'] and not files['distributed-node.json'],'config not saved in /config')
files['distributed-node.json']=serialize({revision=0})
check(U.read('distributed-node.json').revision==1,'legacy file overrode current config')
files['distributed-state.json']=serialize({runRequested=false})
files['distributed-state.json.tmp']=serialize({runRequested=true})
check(U.read('distributed-state.json').runRequested,'legacy recovery file ignored')
check(files['/config/distributed-state.json'] and files['distributed-state.json.tmp'],'migration failed or destroyed backup')
files['/config/distributed-state.json.tmp']=serialize({runRequested=false})
check(not U.read('distributed-state.json').runRequested,'new recovery checkpoint ignored')
files['/config/distributed-node.json']='broken json'
check(not pcall(U.read,'distributed-node.json'),'corrupt new config silently fell back to stale root file')
U.write('install/active-release.json',{version='test'})
check(files['install/active-release.json'] and not files['/config/install/active-release.json'],'release pointer incorrectly relocated')
local settings={target=2640,stepUp=2.5,maxInputVolts=2800}
local path='/config/distributed-state.json'
local running={events={{id='old',reason='prior incident'}},target=2600,runRequested=true,latched=false}
files={}
check(U.readState(settings)==nil,'absent state invented recovery')
U.write('distributed-state.json',running)
check(U.readState(settings).runRequested,'valid saved running intent lost')
U.write('distributed-state.json',{events={},target=2640,runRequested=false,latched=true})
check(files[path..'.bak']~=nil,'last valid state not backed up')
files[path]='broken'
local before=files[path]
check(not pcall(U.readState,settings) and files[path]==before,'corrupt state reset without consent')
local called=false
local recovered=U.readState(settings,function(file,backup) called=file==path and backup==path..'.bak'; return 'restore' end)
check(called and recovered.target==2600 and #recovered.events==1,'confirmed backup not restored')
check(recovered.latched and not recovered.runRequested and not recovered.realignRequested,'backup restarted transformer automatically')
check(files[path..'.corrupt']=='broken','damaged file not preserved')
files={}; files[path]='  \n  '; files[path..'.bak']=serialize(running)
recovered=U.readState(settings,function() error('empty file must not prompt') end)
check(recovered.target==2640 and recovered.latched and #recovered.events==0,'empty file did not create fresh log')
files={}; files[path]=serialize(running); files[path..'.tmp']='broken'
check(not pcall(U.readState,settings,function() return false end) and files[path..'.tmp']=='broken','cancel changed corrupt temporary file')
recovered=U.readState(settings,function() return 'restore' end)
check(recovered.target==2600 and not recovered.runRequested,'confirmed base recovery failed')
files={}; files[path]=serialize(running); files[path..'.tmp']=serialize({events={},target=2500,runRequested=true,latched=false})
check(U.readState(settings).target==2500 and U.readState(settings).runRequested,'valid newest checkpoint not used')
for _,bad in ipairs({{events='bad'}, {events={{reason='missing id'}}}, {events={},target=999999}, {events={},runRequested='true'}, false}) do
 files={}; files[path]=serialize(bad)
 check(not pcall(U.readState,settings),'invalid nonempty state silently reset')
 recovered=U.readState(settings,function() return 'reset' end)
 check(recovered.target==2640 and not recovered.runRequested,'confirmed reset did not create stopped defaults')
end
print(('PASS: %d config storage checks'):format(n))
