local base='Powerplant/distributed/'
local Update=dofile(base..'updater.lua'); local hash=dofile(base..'sha256.lua')
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local files,records={},{}
fs={exists=function(p) return files[p]~=nil end,combine=function(a,b) return a..'/'..b end,
 makeDir=function(p) files[p]=true end,delete=function(p) for k in pairs(files) do if k==p or k:sub(1,#p+1)==p..'/' then files[k]=nil end end end,
 open=function(p,mode) if mode=='r' and not files[p] then return nil end; local body='' return {
   write=function(v) body=body..v end,readAll=function() return files[p] end,close=function() if mode=='w' then files[p]=body end end} end}
local isolated,idle=true,true
local R={role='protection',root='install',state={latched=true},config={ids={master=1},settings={}},modules={hash=hash},now=function() return 100 end,
 U={release='distributed-1.0.0',isolated=function() return isolated end,idle=function() return idle end,
 read=function(p) return records[p] end,write=function(p,v) records[p]=v end}}
local api=Update.new(R)
local manifest={schema=1,version='distributed-1.0.1',ref='distributed-1.0.1',files={}}
local body='return {version="test"}'
for _,n in ipairs({'app','common','runtime','protection','regulation','planner','ui','interface','updater','sha256','thermal_protection','transformer'}) do manifest.files[n..'.lua']={size=#body,sha256=hash(body)} end
local function receive(kind,data,sender) return api.receive(sender or 1,{kind=kind,data=data or {}}) end
check(not pcall(receive,'update_begin',{manifest=manifest},2),'non-master update accepted')
R.state.latched=false; check(not pcall(receive,'update_begin',{manifest=manifest}),'live update accepted'); R.state.latched=true
isolated=false; check(not pcall(receive,'update_begin',{manifest=manifest}),'energized update accepted'); isolated=true
idle=false; check(not pcall(receive,'update_begin',{manifest=manifest}),'moving update accepted'); idle=true
receive('update_begin',{manifest=manifest})
check(not pcall(receive,'update_activate',{version=manifest.version}),'incomplete release activated')
for name in pairs(manifest.files) do receive('update_chunk',{name=name,index=1,body=body}); receive('update_file',{name=name}) end
receive('update_finish')
check(R.state.updateReady==manifest.version and not R.rebootRequested,'staging rebooted worker')
files['install/releases/'..manifest.version..'/common.lua']='corrupted'
check(not pcall(receive,'update_activate',{version=manifest.version}) and not records['install/active-release.json'],'modified staged bytes activated')
files['install/releases/'..manifest.version..'/common.lua']=body
isolated=false; check(not pcall(receive,'update_activate',{version=manifest.version}),'lost isolation ignored at activation'); isolated=true
receive('update_activate',{version=manifest.version})
check(R.rebootRequested and R.rebootAt>R.now(),'activation did not allow acknowledgement before reboot')
check(records['install/active-release.json'].previous=='bundled','rollback pointer missing')
receive('update_activate',{version=manifest.version})
check(records['install/active-release.json'].previous=='bundled','retransmission destroyed rollback pointer')
check(Update.newer('distributed-1.10.0','distributed-1.2.9'),'numeric version ordering')
check(not Update.newer('distributed-1.0.0','distributed-1.0.1'),'automatic downgrade')
print(('PASS: %d staged-update checks'):format(count))
