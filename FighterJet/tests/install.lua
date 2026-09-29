local realPrint=print
local hash=dofile('Powerplant/distributed/sha256.lua')
local installer=assert(loadfile('FighterJet/install.lua'))('__test')
local names={'flight.lua','flight_core.lua','hardware.lua','jet_config.lua','jet_link.lua','jet_store.lua',
    'jet_paths.lua','hud.lua','hud_core.lua','hud_data.lua','cockpit_ui.lua','startup.lua','startup_mode.lua','install.lua'}
local bodies={}
for _,name in ipairs(names) do local f=assert(io.open('FighterJet/'..name)); bodies[name]=f:read('*a'); f:close() end
local json={}; local jsonCount=0
textutils={serializeJSON=function(v) jsonCount=jsonCount+1; local key='JSON'..jsonCount; json[key]=v; return key end,
    unserializeJSON=function(raw) return json[raw] end}
local data,dirs={},{}
local moves,requests=0,0
local failWrite,failDownload,corrupt,freeSpace
local version='fighter-0.1.0'
local function normal(p)
    local parts={}
    for part in p:gmatch('[^/]+') do
        if part=='..' then table.remove(parts) elseif part~='.' then parts[#parts+1]=part end
    end
    return '/'..table.concat(parts,'/')
end
local function mkdir(p)
    p=normal(p); dirs[p]=true
    local parent=p:match('^(.*)/[^/]+$')
    if parent and parent~='' then mkdir(parent) end
end
fs={combine=function(a,b) return normal(a..'/'..b) end,
    exists=function(p) p=normal(p); return data[p]~=nil or dirs[p]~=nil end,
    makeDir=mkdir,getFreeSpace=function() return freeSpace or 1000000 end,
    open=function(p,mode)
        p=normal(p)
        if mode=='r' then if data[p]==nil then return nil end; return {readAll=function() return data[p] end,close=function() end} end
        if p==failWrite then return nil end
        data[p]=''
        return {write=function(s) data[p]=data[p]..s end,close=function() end}
    end,
    copy=function(a,b) assert(data[normal(a)]); data[normal(b)]=data[normal(a)] end,
    move=function(a,b) moves=moves+1; a,b=normal(a),normal(b); data[b]=assert(data[a]); data[a]=nil end,
    delete=function(p)
        p=normal(p)
        for path in pairs(data) do if path==p or path:sub(1,#p+1)==p..'/' then data[path]=nil end end
        for path in pairs(dirs) do if path==p or path:sub(1,#p+1)==p..'/' then dirs[path]=nil end end
    end,
    list=function(p)
        p=normal(p); local found={}; local result={}
        for _,set in ipairs({data,dirs}) do
            for path in pairs(set) do
                if path:sub(1,#p+1)==p..'/' then local part=path:sub(#p+2):match('^[^/]+'); if part then found[part]=true end end
            end
        end
        for part in pairs(found) do result[#result+1]=part end
        return result
    end}
os.getComputerID=function() return 5 end
os.epoch=function() return 123 end
print=function() end
local function get(url)
    requests=requests+1
    if url:find('release.json',1,true) then
        local m={schema=1,version=version,ref=version,files={}}
        for name,body in pairs(bodies) do m.files[name]={size=#body,sha256=hash(body)} end
        return textutils.serializeJSON(m)
    end
    assert(url:find('/'..version..'/FighterJet/',1,true),'Downloads must be pinned to one version')
    local name=url:match('[^/]+$')
    if name==failDownload then error('network interrupted') end
    return name==corrupt and 'return 42' or assert(bodies[name])
end
mkdir('/')
data['/startup.lua']='old startup'
data['/jet_config.lua']='return { custom = true }'
data['/startup_mode.lua']='return "live"'
data['/jet_state.a']='saved home'
-- Interrupted first install does not touch prior startup or select partial code.
failDownload='hud.lua'
assert(not pcall(installer.run,'install','/fighter',get))
assert(not installer.current('/fighter') and data['/startup.lua']=='old startup')
failDownload=nil
installer.run('install','/fighter',get)
assert(installer.current('/fighter').version==version)
assert(data['/startup.before-fighter.lua']=='old startup')
assert(data['/fighter/jet_config.lua']==data['/jet_config.lua'])
assert(data['/fighter/startup_mode.lua']=='return "live"' and data['/fighter/jet_state.a']=='saved home')
assert(not data['/fighter/run.lua']:find('http',1,true),'Launcher must not check for updates')
local startup=data['/startup.lua']; local beforeMoves=moves
installer.run('install','/fighter',get)
assert(moves==beforeMoves and data['/startup.lua']==startup,'Reinstall should not proliferate backups')
-- Same-version apply must repair a legacy launcher which drops arguments.
data['/fighter/run.lua']='old launcher without argument forwarding'
installer.run('check','/fighter',get)
assert(data['/fighter/run.lua']=='old launcher without argument forwarding')
installer.run('apply','/fighter',get)
assert(data['/fighter/run.lua']==installer.launcher('/fighter',false))
-- Check does not write/apply; damaged downloads never replace active release.
version='fighter-0.2.0'
installer.run('check','/fighter',get)
assert(installer.current('/fighter').version=='fighter-0.1.0')
corrupt='flight_core.lua'
assert(not pcall(installer.run,'apply','/fighter',get))
assert(installer.current('/fighter').version=='fighter-0.1.0')
corrupt=nil; failWrite='/fighter/active.a'
assert(not pcall(installer.run,'apply','/fighter',get))
assert(installer.current('/fighter').version=='fighter-0.1.0')
failWrite=nil
installer.run('apply','/fighter',get)
assert(installer.current('/fighter').version==version)
assert(data['/fighter/jet_config.lua']=='return { custom = true }' and data['/fighter/jet_state.a']=='saved home')
assert(data['/startup.lua']==startup,'Update changed root startup')
local requestCount=requests
installer.run('rollback','/fighter',get)
assert(requests==requestCount and installer.current('/fighter').version=='fighter-0.1.0','Rollback must work offline')
installer.run('rollback','/fighter',get)
assert(installer.current('/fighter').version==version)
-- Release retention is bounded, including leftovers from failed downloads.
version='fighter-0.3.0'
installer.run('apply','/fighter',get)
assert(not fs.exists('/fighter/releases/fighter-0.1.0'))
assert(fs.exists('/fighter/releases/fighter-0.2.0') and fs.exists('/fighter/releases/fighter-0.3.0'))
-- Corrupt latest pointer falls back to the other complete release.
local current=installer.current('/fighter')
local pointer='/fighter/active.'..(current.generation%2==0 and 'a' or 'b')
data[pointer]='partial JSON'
assert(installer.current('/fighter').version=='fighter-0.2.0')
local launched
shell={run=function(...) launched={...} end}
assert(load(data['/fighter/run.lua']))('thruster')
assert(launched[1]=='/fighter/releases/fighter-0.2.0/startup.lua' and launched[2]=='thruster')
assert(load(data['/fighter/update.lua']))('check')
assert(launched[1]=='/fighter/releases/fighter-0.2.0/install.lua' and launched[2]=='check')
freeSpace=100
assert(not pcall(installer.run,'apply','/fighter',get),'Low disk should reject before replacing release')
mkdir('/unrelated'); assert(not pcall(installer.run,'install','/unrelated',get))
local paths=dofile('FighterJet/jet_paths.lua')
assert(paths.root('/fighter/releases/fighter-0.2.0')=='/fighter')
assert(paths.root('/standalone')=='/standalone')
-- Remap existing persistent settings without actuator calls or config rewrites.
textutils.serialize=textutils.serializeJSON
textutils.unserialize=textutils.unserializeJSON
peripheral={isPresent=function(n) return n~='thruster_99' end,
    getMethods=function() return {'getThrottle','setThrottle'} end,
    call=function() error('Remap must not call device methods') end}
local oldLoad=loadfile
local disabled=false
_G.loadfile=function(path,...)
    if path=='/fighter/jet_config.lua' then return function()
        local vector={enabled=true,authority=0.6,yawSign=-1}
        if disabled then vector=false end
        return {custom='preserve',flight={pitchKp=0.123},thrusters={'thruster_8'},vectoring=vector}
    end end
    if path=='/fighter/hardware.lua' then return function() return {wings={unchanged=true}} end end
    if path:match('/jet_store.lua$') then return oldLoad('FighterJet/jet_store.lua') end
    return oldLoad(path,...)
end
local directory='/fighter/releases/fighter-0.2.0'
local rawConfig=data['/fighter/jet_config.lua']
paths.remap(directory,'12','13','15','14')
local mapped=paths.module(directory,'jet_config')
assert(table.concat(mapped.thrusters,',')=='thruster_12,thruster_13,thruster_14,thruster_15')
assert(mapped.vectoring.bottom=='thruster_12' and mapped.vectoring.top=='thruster_13')
assert(mapped.vectoring.left=='thruster_15' and mapped.vectoring.right=='thruster_14')
assert(mapped.vectoring.authority==0.6 and mapped.vectoring.yawSign==-1 and mapped.flight.pitchKp==0.123)
assert(data['/fighter/jet_config.lua']==rawConfig,'Remap overwrote user configuration')
disabled=true
assert(paths.module(directory,'jet_config').vectoring==false,'Remap enabled disabled assistance')
disabled=false
local hw=paths.module(directory,'hardware')
assert(hw.wings.unchanged and hw.thrusterPositions.left=='thruster_15')
assert(not pcall(paths.remap,directory,'12','12','15','14'),'Duplicate ID accepted')
assert(not pcall(paths.remap,directory,'12','13','15','99'),'Missing thruster accepted')
-- Interrupted alternate-slot write must leave the existing mapping usable.
data['/fighter/thruster_map.a']='partial'
assert(paths.module(directory,'jet_config').vectoring.bottom=='thruster_12')
_G.loadfile=oldLoad
print=realPrint
print('Installer: interrupted download/write, checksums, preservation, manual update, offline rollback, retention and launchers passed')
