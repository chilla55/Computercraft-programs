local base='Powerplant/distributed/'
local Update=dofile(base..'updater.lua'); local hash=dofile(base..'sha256.lua')
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local files,records={},{}
fs={exists=function(p) return files[p]~=nil end,combine=function(a,b) return a..'/'..b end,
 list=function(p)
  local result,seen={},{}; for k in pairs(files) do
   if k:sub(1,#p+1)==p..'/' then local name=k:sub(#p+2):match('^[^/]+'); if not seen[name] then result[#result+1]=name; seen[name]=true end end
  end; return result
 end,
 makeDir=function(p) files[p]=true; local parent=p:match('^(.*)/'); if parent then files[parent]=true end end,delete=function(p) for k in pairs(files) do if k==p or k:sub(1,#p+1)==p..'/' then files[k]=nil end end end,
 open=function(p,mode) if mode=='r' and not files[p] then return nil end; local body='' return {
   write=function(v) body=body..v end,readAll=function() return files[p] end,close=function() if mode=='w' then files[p]=body end end} end}
local isolated,idle=true,true
local R={role='protection',root='install',state={latched=true},config={ids={master=1},settings={}},modules={hash=hash},now=function() return 100 end,
 U={release='distributed-1.0.0',isolated=function() return isolated end,idle=function() return idle end,
 read=function(p) return records[p] end,write=function(p,v) records[p]=v end}}
local api=Update.new(R)
local manifest={schema=1,version='distributed-1.0.1',ref='distributed-1.0.1',files={}}
local body='return {version="test"}'
for _,n in ipairs({'discovery','app','common','runtime','protection','regulation','planner','ui','interface','updater','sha256','thermal_protection','transformer'}) do manifest.files[n..'.lua']={size=#body,sha256=hash(body)} end
local function receive(kind,data,sender) return api.receive(sender or 1,{kind=kind,data=data or {}}) end
check(not pcall(receive,'update_begin',{manifest=manifest},2),'non-master update accepted')
R.state.latched=false; isolated=false; idle=false
check(pcall(receive,'update_begin',{manifest=manifest}),'live staging refused')
R.state.latched=true; isolated=true; idle=true
receive('update_begin',{manifest=manifest})
check(not pcall(receive,'update_activate',{version=manifest.version,approved=true,approvalId='operator-1'}),'incomplete release activated')
for name in pairs(manifest.files) do receive('update_chunk',{name=name,index=1,body=body}); receive('update_file',{name=name}) end
receive('update_finish')
check(R.state.updateReady==manifest.version and not R.rebootRequested,'staging rebooted worker')
check(not pcall(receive,'update_activate',{version=manifest.version}),'activation without consent accepted')
api=Update.new(R)
check(R.state.updateReady==manifest.version and not R.rebootRequested,'staged restore failed')
files['install/releases/'..manifest.version..'/common.lua']='corrupted'
check(not pcall(receive,'update_activate',{version=manifest.version,approved=true,approvalId='operator-1'}) and not records['install/active-release.json'],'modified staged bytes activated')
files['install/releases/'..manifest.version..'/common.lua']=body
isolated=false; check(not pcall(receive,'update_activate',{version=manifest.version,approved=true,approvalId='operator-1'}),'lost isolation ignored at activation'); isolated=true
receive('update_activate',{version=manifest.version,approved=true,approvalId='operator-1'})
check(R.rebootRequested and R.rebootAt>R.now(),'activation did not allow acknowledgement before reboot')
check(records['install/active-release.json'].previous=='bundled','rollback pointer missing')
receive('update_activate',{version=manifest.version,approved=true,approvalId='operator-1'})
check(records['install/active-release.json'].previous=='bundled','retransmission destroyed rollback pointer')
check(Update.newer('distributed-1.10.0','distributed-1.2.9'),'numeric version ordering')
check(not Update.newer('distributed-1.0.0','distributed-1.0.1'),'automatic downgrade')
-- Master downloads and transfers during operation but needs fresh consent to apply.
R.role='master'; R.root='master-install'; R.state={latched=false}; R.rebootRequested=nil
isolated=false; idle=false
local serial,activated,transferred=0,0,0
R.token=function() serial=serial+1; return tostring(serial) end
os.queueEvent=function() end
R.updatePending={}; R.updateAcks={}
R.updatePeer=function() return {latched=R.state.latched,updateReady=manifest.version},'distributed-1.0.0' end
R.send=function(role,kind,data)
  if kind=='update_activate' then activated=activated+1; assert(data.approved and data.approvalId) else transferred=transferred+1 end
  R.updateAcks[data.id]={ok=true}
end
http={get=function(url) return {readAll=function() return url:find('approved-release.json',1,true) and 'manifest' or body end,close=function() end} end}
textutils={unserializeJSON=function() return manifest end}
api=Update.new(R)
-- Initially neither worker has a staged release.
R.updatePeer=function() return {latched=R.state.latched},'distributed-1.0.0' end
api.check()
check(transferred>0 and activated==0 and not R.rebootRequested,'check activated or failed to pretransfer')
check(not pcall(api.apply),'unapproved master apply accepted')
api.defer(manifest.version)
check(R.state.updateDeferred==manifest.version and not pcall(api.apply),'Later approved update')
api=Update.new(R)
check(R.state.updateDeferred==manifest.version and not pcall(api.apply),'restart restored consent')
check(not pcall(api.approve,'distributed-9.9.9'),'stale displayed version accepted')
api.approve(manifest.version)
check(not pcall(api.apply),'energized activation accepted')
isolated=true; idle=true; R.state.latched=true
check(not pcall(api.apply),'failed approval reused later')
api.approve(manifest.version)
check(not pcall(api.apply),'unstaged worker accepted')
R.updatePeer=function() return {latched=true,updateReady=manifest.version},'distributed-1.0.0' end
api.approve(manifest.version); api.apply()
check(activated==2 and R.rebootRequested,'approved isolated rollout failed')
-- Bound storage to the original fallback, current release, and one pending.
local B={role='protection',root='bounded',state={latched=true},config=R.config,modules=R.modules,now=R.now,
 U={release='distributed-1.0.1',isolated=R.U.isolated,idle=R.U.idle,read=R.U.read,write=R.U.write}}
files['bounded/app.lua']='original fallback'; files['bounded/transformer.lua']='stable launcher'
files['bounded/releases']=true
files['bounded/releases/distributed-1.0.0']=true
files['bounded/releases/distributed-1.0.1']=true
files['bounded/releases/distributed-1.0.1/common.lua']=body
files['bounded/releases/notes']='user file'
records['bounded/active-release.json']={version='distributed-1.0.1',previous='distributed-1.0.0'}
local bounded=Update.new(B)
check(not files['bounded/releases/distributed-1.0.0'] and files['bounded/releases/distributed-1.0.1'],'boot cleanup removed active or retained old release')
check(records['bounded/active-release.json'].previous=='bundled' and files['bounded/app.lua']=='original fallback','fixed fallback lost')
local function stageVersion(version)
 local m={schema=1,version=version,ref=version,files=manifest.files}
 bounded.receive(1,{kind='update_begin',data={manifest=m}})
 for name in pairs(m.files) do
  bounded.receive(1,{kind='update_chunk',data={name=name,index=1,body=body}})
  bounded.receive(1,{kind='update_file',data={name=name}})
 end
 bounded.receive(1,{kind='update_finish',data={}})
end
stageVersion('distributed-1.0.2'); stageVersion('distributed-1.0.3')
check(not files['bounded/releases/distributed-1.0.2'] and files['bounded/releases/distributed-1.0.3'],'superseded pending update retained')
check(files['bounded/releases/distributed-1.0.1/common.lua']==body and files['bounded/releases/notes']=='user file','staging deleted active/unrelated files')
bounded.receive(1,{kind='update_activate',data={version='distributed-1.0.3',approved=true,approvalId='yes'}})
check(files['bounded/releases/distributed-1.0.1'],'activation deleted still-running version')
check(not pcall(stageVersion,'distributed-1.0.4'),'staging allowed during restart')
B.U.release='distributed-1.0.3'; B.rebootRequested=nil; B.state={latched=true}
bounded=Update.new(B)
check(not files['bounded/releases/distributed-1.0.1'] and files['bounded/releases/distributed-1.0.3'],'new boot did not prune superseded running version')
check(files['bounded/app.lua']=='original fallback' and records['bounded/active-release.json'].previous=='bundled','fallback changed after upgrade')
-- Manual checks wake the background task, even with automatic checks disabled.
R.root='manual-install'; R.state={latched=false}; R.node={autoUpdate=false}; R.rebootRequested=nil
R.U.release=manifest.version
local downloads,lastUrl=0
http.get=function(url) downloads=downloads+1; lastUrl=url; return {readAll=function() return 'manifest' end,close=function() end} end
os.startTimer=function() return 1 end
os.pullEvent=function() return coroutine.yield('event') end
api=Update.new(R)
local runner=coroutine.create(api.run)
local ok,wait=coroutine.resume(runner)
check(ok and wait=='event' and downloads==0,'disabled auto-check still fetched a manifest')
check(api.requestCheck() and R.state.updateChecking,'manual check was not queued')
check(not api.requestCheck(),'duplicate manual check queued')
ok,wait=coroutine.resume(runner,'distributed_update_check')
check(ok and wait=='event' and downloads==1 and not R.state.updateChecking,'manual check did not finish in background')
check(lastUrl:find('?check=100',1,true),'manual check reused a stale manifest URL')
check(R.state.updateMessage=='No newer update available.' and not R.rebootRequested,'checking implicitly applied an update')
http.get=function() error('HTTP unavailable') end
check(api.requestCheck(),'second manual check refused')
ok,wait=coroutine.resume(runner,'distributed_update_check')
check(ok and wait=='event' and not R.state.updateChecking and R.state.updateMessage:find('HTTP unavailable',1,true),'failed check stuck busy or lost error')
check(not pcall(bounded.requestCheck),'worker allowed to check GitHub')
print(('PASS: %d staged-update checks'):format(count))
