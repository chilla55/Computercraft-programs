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
print(('PASS: %d config storage checks'):format(n))
