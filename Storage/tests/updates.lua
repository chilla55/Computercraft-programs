-- In-memory CraftOS filesystem. No Minecraft or HTTP connection required.
local updater = dofile('Storage/install.lua')
local monitor = dofile('Storage/stock_monitor.lua')
local hash = dofile('Powerplant/distributed/sha256.lua')
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local files, dirs, failMove, failWrite = {}, {}, nil, false
fs = {
    combine=function(a,b) return a..'/'..b end,
    getDir=function(p) return p:match('^(.*)/') or '' end,
    exists=function(p) return files[p]~=nil or dirs[p] end,
    isDir=function(p) return dirs[p] or false end,
    getSize=function(p) return #assert(files[p]) end,
    makeDir=function(p) dirs[p]=true end,
    delete=function(p)
        files[p]=nil; dirs[p]=nil
        for k in pairs(files) do if k:sub(1,#p+1)==p..'/' then files[k]=nil end end
    end,
    copy=function(a,b) assert(not files[b]); files[b]=assert(files[a]) end,
    move=function(a,b)
        if failMove and failMove(a,b) then error('Injected move failure') end
        assert(files[a] and not files[b], 'Invalid move '..a..' -> '..b)
        files[b],files[a]=files[a],nil
    end,
    open=function(p,mode)
        if mode=='r' then
            if not files[p] then return nil end
            return {readAll=function() return files[p] end,close=function() end}
        end
        return {write=function(s)
            if failWrite then error('Disk full') end
            files[p]=s
        end,close=function() end}
    end,
}
local function serialize(v)
    if type(v)=='table' then
        local out={'{'}
        for k,value in pairs(v) do out[#out+1]='['..serialize(k)..']='..serialize(value)..',' end
        out[#out+1]='}'; return table.concat(out)
    elseif type(v)=='string' then return string.format('%q',v)
    else return tostring(v) end
end
local function decode(s)
    local fn=load('return '..s,'test-data','t',{})
    if not fn then return nil end
    local ok,v=pcall(fn); if ok then return v end
end
textutils={serialize=serialize,unserialize=decode,unserializeJSON=decode}
os.epoch=function() return 1000000 end
os.queueEvent=function() end
local function body(version, suffix)
    return '-- stock-monitor-version: '..version..'\nreturn '..(suffix or 'true')..'\n'
end
local function manifest(bytes, version)
    return {schema=1,version=version or updater.version(bytes),size=#bytes,sha256=hash(bytes)}
end
local old,new=body('1.0.0'),body('1.1.0')
local downloads=0
local remoteBody,remoteManifest=new,manifest(new)
local function get(url)
    downloads=downloads+1
    if url:find('release.json',1,true) then return serialize(remoteManifest) end
    return remoteBody
end
local path='storage/stock_monitor.lua'
files[path]=old; files[path..'.cfg']='config'; files[path..'.history']='history'
assert(updater.update('storage',get)); eq(files[path],new); eq(files[path..'.bak'],old)
eq(files[path..'.cfg'],'config'); eq(files[path..'.history'],'history')
eq(updater.update('storage',get),false)
remoteBody=old; remoteManifest=manifest(old)
eq(updater.update('storage',get),false); eq(files[path],new)
remoteBody=body('1.2.0'); remoteManifest=manifest(remoteBody)
remoteBody=remoteBody..'tampered'
assert(not pcall(updater.update,'storage',get)); eq(files[path],new)
remoteBody=body('1.2.0','function('); remoteManifest=manifest(remoteBody)
assert(not pcall(updater.update,'storage',get)); eq(files[path],new)
remoteBody=body('1.2.0'); remoteManifest=manifest(remoteBody)
failMove=function(a,b) return a==path..'.download' end
assert(not pcall(updater.update,'storage',get)); eq(files[path],new)
failMove=nil
failWrite=true
assert(not pcall(updater.update,'storage',get)); eq(files[path],new)
failWrite=false
assert(not pcall(updater.update,'storage',function() error('Offline') end)); eq(files[path],new)
assert(updater.update('storage',get)); eq(files[path],remoteBody)
assert(updater.rollback('storage')); eq(files[path],new)
eq(updater.update('storage',get),false) -- rejected release is not reinstalled
files[path..'.bak'],files[path]=files[path],nil
updater.recover(path); eq(files[path],new)
assert(updater.newer('1.10.0','1.9.0')); assert(not updater.newer('1.0.0','1.0.0'))
assert(not pcall(updater.validate,{schema=1,version='1.0.0',size=2,sha256='bad'}))
assert(not pcall(updater.validate,manifest(old,'1.2.0'),old))
-- HTTP errors close error handles, successful responses close as well.
local closed=0
http={get=function() return nil,'offline',{close=function() closed=closed+1 end} end}
assert(not pcall(updater.get,'url')); eq(closed,1)
http.get=function() return {readAll=function() return 'hello' end,close=function() closed=closed+1 end} end
eq(updater.get('url'),'hello'); eq(closed,2)

-- Persistent trends survive a restart and preserve the same five-minute result.
local cfg={vaults={'b','a'},ticker='ticker'}
local history={}
monitor.trend(history,{iron=100},700)
monitor.trend(history,{iron=90},850)
monitor.trend(history,{iron=60},1000)
local hp=path..'.history'
monitor.saveHistory(hp,cfg,history)
local restored=monitor.loadHistory(hp,{vaults={'a','b'},ticker='ticker'},1005)
eq(#restored.samples,3)
eq(monitor.trend(restored,{iron=50},1005).losses[1].loss,50)
eq(#monitor.loadHistory(hp,cfg,1061).samples,0) -- offline too long
assert(#monitor.loadHistory(hp,{vaults={'a'},ticker='ticker'},1005).samples==0)
eq(#monitor.loadHistory(hp,cfg,999).samples,0) -- clock moved backwards
monitor.saveHistory(hp,cfg,history) -- rotates a usable backup
files[hp]='corrupt'
eq(#monitor.loadHistory(hp,cfg,1005).samples,3)
files[hp]=nil -- power loss between rename operations
eq(#monitor.loadHistory(hp,cfg,1005).samples,3)
monitor.saveHistory(hp,cfg,history)
failMove=function(a,b) return a==hp..'.tmp' end
assert(not pcall(monitor.saveHistory,hp,cfg,{samples={}}))
failMove=nil
eq(#monitor.loadHistory(hp,cfg,1005).samples,3)
-- An empty history invalidated by a read failure must not resurrect the backup.
monitor.saveHistory(hp,cfg,{samples={}})
eq(#monitor.loadHistory(hp,cfg,1005).samples,0)

-- Installer creates an isolated launcher and optional startup entry.
shell={resolve=function(p) return p end,getRunningProgram=function() return 'install.lua' end}
files['install.lua']='installer source'
local originalGet=updater.get
updater.get=get
updater.install('fresh',true)
eq(files['fresh/start.lua'],'installer source')
assert(files['/startup/stock_monitor.lua']:find('/fresh/start.lua',1,true))
assert(not pcall(updater.install,'fresh',false))
updater.get=function() error('Offline') end
assert(not pcall(updater.install,'failed',false)); assert(not fs.exists('failed'))
updater.get=originalGet

-- Exercise launcher restart and rollback decisions with cooperative coroutines.
parallel={waitForAny=function(...)
    local threads={}
    for i,fn in ipairs({...}) do threads[i]=coroutine.create(fn) end
    for i,co in ipairs(threads) do
        local ok,why=coroutine.resume(co); assert(ok,why)
        if coroutine.status(co)=='dead' then return i end
    end
    error('Test expected one task to finish')
end}
files[path]=new; files[path..'.cfg']='config'; files['storage/rejected.sha256']=nil
remoteBody=body('1.3.0'); remoteManifest=manifest(remoteBody)
updater.get=get
local runs=0
updater.launch=function(p,args,services)
    eq(p,path); runs=runs+1
    services.configuring=false
    if runs==1 then coroutine.yield() end
end
updater.run('storage',{})
eq(runs,2); eq(files[path],remoteBody) -- updated and relaunched, then Q exits
runs=0
updater.launch=function(p,args,services)
    runs=runs+1; services.configuring=false
    if runs==1 then error('Bad release') end
end
updater.run('storage',{})
eq(runs,2); eq(files[path],new) -- crash rolls back, normal exit stops
-- Manual requests wake the update coroutine before its five-minute timer.
local resumed=false
os.startTimer=function(seconds) eq(seconds,300); return 99 end
os.cancelTimer=function(id) eq(id,99) end
os.pullEvent=function() return coroutine.yield() end
parallel.waitForAny=function(app,check)
    local first,second=coroutine.create(app),coroutine.create(check)
    assert(coroutine.resume(first))
    assert(coroutine.resume(second)) -- initial check then waits for timer
    local before=downloads
    assert(coroutine.resume(first)) -- request an immediate check
    assert(coroutine.resume(second,'stock_monitor_update_check'))
    assert(downloads>before,'Manual request did not check the server')
    assert(coroutine.resume(first)) -- user quits
    resumed=true
end
updater.launch=function(p,args,services)
    services.configuring=false
    coroutine.yield()
    services.requestUpdate()
    coroutine.yield()
end
remoteBody=new; remoteManifest=manifest(new)
updater.run('storage',{})
assert(resumed)
print('Updates: verification, rollback, install, launcher, manual checks, and persistent history passed')

-- Run the real dashboard event loop through manual update and reconfiguration.
colors={black=1,white=2,cyan=3,red=4,orange=5,lime=6,lightGray=7}
local function display()
    return {getSize=function() return 51,19 end,setTextScale=function() end,
        setBackgroundColor=function() end,setTextColor=function() end,
        clear=function() end,setCursorPos=function() end,write=function() end}
end
local terminal=display()
term={current=function() return terminal end}
local peripheralDevices={
    a={size=function() return 1 end,getItemLimit=function() return 64 end,
        list=function() return {{name='iron',count=20}} end},
    ticker={stock=function() return {{name='iron',count=20}} end},
    display=display(),
}
peripheral={wrap=function(name) return peripheralDevices[name] end,
    getNames=function() return {'a','ticker','display'} end,
    hasType=function(name,kind) return name=='display' and kind=='monitor' end}
files[path..'.cfg']=serialize({vaults={'a'},ticker='ticker',monitor='display',interval=5})
local timerCount,manualCount=0,0
os.startTimer=function(seconds) eq(seconds,5); timerCount=timerCount+1; return timerCount end
os.cancelTimer=function() end
local events={{'char','u'},{'char','c'},{'timer',2},{'char','q'}}
os.pullEvent=function() local event=table.remove(events,1); assert(event); return table.unpack(event) end
read=function() return '1' end
write=function() end
local services={program=path,requestUpdate=function() manualCount=manualCount+1 end}
monitor.main({},services)
eq(manualCount,1); eq(timerCount,3); eq(services.configuring,false)
assert(decode(files[path..'.cfg']).monitor=='display')
assert(decode(files[path..'.history']).schema==1)
print('Dashboard configuration, manual update controls, refresh restart, and history saving passed')

-- Startup is installed by default; explicit opt-out and old opt-in both work.
local realInstall=updater.install
local selectedRoot,selectedStartup
updater.install=function(root,startup) selectedRoot,selectedStartup=root,startup end
updater.main({}); eq(selectedRoot,'storage'); eq(selectedStartup,true)
updater.main({'custom'}); eq(selectedRoot,'custom'); eq(selectedStartup,true)
updater.main({'custom','--no-startup'}); eq(selectedStartup,false)
updater.main({'custom','--startup'}); eq(selectedStartup,true)
assert(not pcall(updater.main,{'custom','--unknown'}))
updater.install=realInstall
print('Installer startup defaults and opt-out checks passed')
