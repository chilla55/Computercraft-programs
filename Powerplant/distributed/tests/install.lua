local hash=dofile('Powerplant/distributed/sha256.lua')
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local function run(requested,served,directory)
 local urls,files={},{}; local moved=false
 local body='return {}'
 local manifest={schema=1,version=served,ref=served,files={}}
 for _,name in ipairs({'discovery','app','common','runtime','protection','regulation','planner','ui','interface','updater','sha256','thermal_protection','transformer'}) do manifest.files[name..'.lua']={size=#body,sha256=hash(body)} end
 local env=setmetatable({print=function() end,os={epoch=function() return 123456 end},
 textutils={unserializeJSON=function() return manifest end},
 http={get=function(url) urls[#urls+1]=url; return {readAll=function() return body end,close=function() end} end},
 fs={exists=function() return false end,makeDir=function() end,combine=function(a,b) return a..'/'..b end,
 open=function(path) return {write=function(bytes) files[path]=bytes end,close=function() end} end,
 move=function() moved=true end}}, {__index=_G})
 local folder=directory or 'fresh'; if directory==false then folder=nil end
 local ok=pcall(assert(loadfile('Powerplant/distributed/install.lua','t',env)),folder,requested)
 return ok,urls,files,moved
end
local ok,urls,files,moved=run('distributed-1.1.1','distributed-1.1.1')
check(ok and moved,'pinned install failed')
check(urls[1]:find('/distributed-1.1.1/Powerplant/distributed/approved-release.json',1,true),'manifest not pinned')
check(#urls==14,'release incomplete')
check(files['fresh-download/app.lua']=='return {}','file not installed')
local wrong,_,_,activated=run('distributed-1.1.1','distributed-1.1.0')
check(not wrong and not activated,'wrong version installed')
local latest,latestUrls=run(nil,'distributed-1.1.1')
check(latest and latestUrls[1]:find('?check=123456',1,true),'latest manifest can reuse stale URL')
check(not run('../main','distributed-1.1.1'),'invalid release accepted')
local versioned,_,versionFiles=run('distributed-1.1.1','distributed-1.1.1','fresh-1.1.1')
check(versioned and versionFiles['fresh-1.1.1-download/app.lua'],'explicit installation folder changed')
local defaultOk,_,defaultFiles=run('distributed-1.1.1','distributed-1.1.1',false)
check(defaultOk and defaultFiles['transformer-download/app.lua'],'default fallback folder is not transformer')
print(('PASS: %d installer checks'):format(count))
