-- Fighter installer and manual updater. No scheduled checks or automatic restart.
local hash=(function()
-- SHA-256, Lua 5.2/CC bit32. Hashes bytes; not an authentication mechanism.
local b=bit32
local K={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local function word(n) return string.char(b.extract(n,24,8),b.extract(n,16,8),b.extract(n,8,8),b.extract(n,0,8)) end
return function(s)
  local bits=#s*8
  s=s..'\128'..string.rep('\0',(55-#s)%64)..word(math.floor(bits/2^32))..word(bits%2^32)
  local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  for p=1,#s,64 do
    local w={}
    for i=0,15 do local a,c,d,e=s:byte(p+i*4,p+i*4+3); w[i]=a*2^24+c*2^16+d*256+e end
    for i=16,63 do
      local x,y=w[i-15],w[i-2]
      w[i]=(w[i-16]+b.bxor(b.rrotate(x,7),b.rrotate(x,18),b.rshift(x,3))+w[i-7]+b.bxor(b.rrotate(y,17),b.rrotate(y,19),b.rshift(y,10)))%2^32
    end
    local a,c,d,e,f,g,j,k=table.unpack(h)
    for i=0,63 do
      local t1=(k+b.bxor(b.rrotate(f,6),b.rrotate(f,11),b.rrotate(f,25))+b.bxor(b.band(f,g),b.band(b.bnot(f),j))+K[i+1]+w[i])%2^32
      local t2=(b.bxor(b.rrotate(a,2),b.rrotate(a,13),b.rrotate(a,22))+b.bxor(b.band(a,c),b.band(a,d),b.band(c,d)))%2^32
      k,j,g,f,e,d,c,a=j,g,f,(e+t1)%2^32,d,c,a,(t1+t2)%2^32
    end
    local v={a,c,d,e,f,g,j,k}; for i=1,8 do h[i]=(h[i]+v[i])%2^32 end
  end
  local out={}; for i=1,8 do out[i]=string.format('%08x',h[i]) end
  return table.concat(out)
end

end)()
local M={}
local repository='https://raw.githubusercontent.com/chilla55/Computercraft-programs/'
local files={'flight.lua','flight_core.lua','hardware.lua','jet_config.lua','jet_link.lua','jet_store.lua',
    'jet_paths.lua','hud.lua','hud_core.lua','hud_data.lua','cockpit_ui.lua','startup.lua','startup_mode.lua','install.lua'}
local owned={}; for _,name in ipairs(files) do owned[name]=true end
local function tag(v) return type(v)=='string' and v:match('^fighter%-%d+%.%d+%.%d+$') end
local function read(path)
    local f=assert(fs.open(path,'r'),'Cannot read '..path); local body=f.readAll(); f.close(); return body
end
local function write(path,body)
    local f=assert(fs.open(path,'w'),'Cannot write '..path); f.write(body); f.close()
end
local function remove(path) if fs.exists(path) then fs.delete(path) end end
function M.get(url)
    assert(http and http.get,'Enable HTTP in ComputerCraft to install/update')
    local response,err,failed=http.get(url,nil,true)
    if not response then if failed then failed.close() end; error(err or 'Download failed',0) end
    local ok,body=pcall(response.readAll); response.close(); assert(ok,body)
    assert(type(body)=='string' and #body<=262144,'Invalid/oversized download')
    return body
end
function M.validate(m)
    assert(type(m)=='table' and m.schema==1 and tag(m.version) and m.ref==m.version,'Invalid fighter manifest')
    assert(type(m.files)=='table','Missing files')
    local total,count=0,0
    for name,e in pairs(m.files) do
        assert(owned[name] and type(e)=='table','Unexpected release file')
        assert(type(e.size)=='number' and e.size%1==0 and e.size>0 and e.size<=262144,'Invalid file size')
        assert(type(e.sha256)=='string' and #e.sha256==64 and not e.sha256:find('[^0-9a-f]'),'Invalid SHA-256')
        total=total+e.size; count=count+1
    end
    assert(total<=524288 and count==#files,'Invalid release size/count')
    for _,name in ipairs(files) do assert(m.files[name],'Missing '..name) end
    return total
end
function M.newer(a,b)
    local function parts(v) local x,y,z=v:match('^fighter%-(%d+)%.(%d+)%.(%d+)$'); return {tonumber(x),tonumber(y),tonumber(z)} end
    local x,y=parts(a),parts(b)
    for i=1,3 do assert(x[i] and y[i],'Invalid version'); if x[i]~=y[i] then return x[i]>y[i] end end
    return false
end
function M.current(root)
    local best
    for _,slot in ipairs({'a','b'}) do
        local p=fs.combine(root,'active.'..slot)
        if fs.exists(p) then
            local ok,v=pcall(function() return textutils.unserializeJSON(read(p)) end)
            if ok and type(v)=='table' and type(v.generation)=='number' and v.generation%1==0
                and v.generation>0 and v.generation<9007199254740991 and tag(v.version)
                and fs.exists(fs.combine(root,'releases/'..v.version..'/.complete'))
                and (not best or v.generation>best.generation) then best=v end
        end
    end
    return best
end
local function activate(root,version,previous)
    local old=M.current(root)
    local pointer={generation=(old and old.generation or 0)+1,version=version,previous=previous}
    write(fs.combine(root,'active.'..(pointer.generation%2==0 and 'a' or 'b')),textutils.serializeJSON(pointer))
    assert(M.current(root).version==version,'Could not activate release')
end
-- Stable local launcher. It never performs HTTP or checks for updates.
local selector=[=[
local function select(root)
    local best
    for _,slot in ipairs({'a','b'}) do
        local path=fs.combine(root,'active.'..slot)
        if fs.exists(path) then
            local ok,v=pcall(function()
                local f=assert(fs.open(path,'r')); local raw=f.readAll(); f.close()
                return textutils.unserializeJSON(raw)
            end)
            if ok and type(v)=='table' and type(v.generation)=='number' and v.generation%1==0
                and v.generation>0 and v.generation<9007199254740991 and type(v.version)=='string'
                and v.version:match('^fighter%-%d+%.%d+%.%d+$')
                and fs.exists(fs.combine(root,'releases/'..v.version..'/.complete'))
                and (not best or v.generation>best.generation) then best=v end
        end
    end
    return assert(best,'No installed fighter release; rerun installer')
end
]=]
function M.launcher(root,update)
    return selector..'\nlocal root='..string.format('%q',root)..'\nlocal selected=select(root)\n'..
        (update and [[local action=... or 'check'
assert(action=='check' or action=='apply' or action=='rollback','Usage: fighter/update [check|apply|rollback]')
shell.run(fs.combine(root,'releases/'..selected.version..'/install.lua'),action,root)
]] or [[shell.run(fs.combine(root,'releases/'..selected.version..'/startup.lua'),...)
]])
end
local function populate(root,release)
    -- Never overwrite a persistent user file. Import an existing flat installation when present.
    for _,name in ipairs({'jet_config.lua','hardware.lua','startup_mode.lua','jet_state.a','jet_state.b'}) do
        local path=fs.combine(root,name)
        if not fs.exists(path) then
            local legacy='/'..name
            if fs.exists(legacy) then fs.copy(legacy,path)
            elseif fs.exists(fs.combine(release,name)) then fs.copy(fs.combine(release,name),path) end
        end
    end
end
local function installStartup(root)
        local startup='-- Fighter managed launcher\nshell.run('..string.format('%q',fs.combine(root,'run.lua'))..')\n'
        local path='/startup.lua'
        if fs.exists(path) and read(path)~=startup then
            local backup='/startup.before-fighter.lua'; local n=0
            while fs.exists(backup) do n=n+1; backup='/startup.before-fighter-'..n..'.lua' end
            fs.move(path,backup); print('Previous startup saved: '..backup)
        end
        write(path,startup)
end
function M.run(action,root,get)
    get=get or M.get
    root=root or '/fighter'
    assert(type(root)=='string' and root:match('^/[%w_-]+$'),'Use an absolute single directory, e.g. /fighter')
    assert(action=='install' or action=='check' or action=='apply' or action=='rollback','Invalid installer action')
    assert(os.getComputerID()==5 or os.getComputerID()==6,'Fighter roles are computer IDs 5 and 6')
    local marker=fs.combine(root,'.fighter-managed')
    if fs.exists(root) then assert(fs.exists(marker),'Unmanaged installation directory; choose another directory') end
    local current=M.current(root)
    if action=='install' and current then
        write(fs.combine(root,'run.lua'),M.launcher(root,false))
        installStartup(root)
        print('Already installed: '..current.version..'. Use '..root..'/update check or apply.'); return
    end
    if action~='install' then assert(current,'Install the fighter first') end
    if action=='rollback' then
        assert(tag(current.previous),'No previous release')
        local previous=fs.combine(root,'releases/'..current.previous)
        assert(fs.exists(fs.combine(previous,'.complete')),'Previous release missing')
        activate(root,current.previous,current.version)
        print('Selected '..current.previous..'. Restart manually when ready.'); return
    end
    local manifest=assert(textutils.unserializeJSON(get(repository..'main/FighterJet/release.json?check='..os.epoch('utc'))),'Invalid manifest JSON')
    local total=M.validate(manifest)
    if current then
        if not M.newer(manifest.version,current.version) then print('Up to date: '..current.version); return end
        print('Available: '..current.version..' -> '..manifest.version)
        if action=='check' then print('Run '..root..'/update apply to install.'); return end
    end
    -- Drop inactive remnants of failed downloads before checking free space.
    local releases=fs.combine(root,'releases')
    if fs.exists(releases) then
        for _,name in ipairs(fs.list(releases)) do
            if tag(name) and (not current or (name~=current.version and name~=current.previous)) then
                remove(fs.combine(releases,name))
            end
        end
    end
    local free=fs.getFreeSpace(fs.exists(root) and root or '/')
    assert(free=='unlimited' or (type(free)=='number' and free>total+32768),'Not enough space for a complete staged release')
    if not fs.exists(root) then fs.makeDir(root); write(marker,'fighter-managed-v1\n') end
    local release=fs.combine(root,'releases/'..manifest.version)
    -- Only an inactive partial download can be removed here.
    if fs.exists(release) then
        assert(not current or (manifest.version~=current.version and manifest.version~=current.previous),'Release already retained; use rollback')
        remove(release)
    end
    fs.makeDir(release)
    for _,name in ipairs(files) do
        local body=get(repository..manifest.ref..'/FighterJet/'..name)
        local e=manifest.files[name]
        assert(#body==e.size and hash(body)==e.sha256,'Download checksum mismatch: '..name)
        assert(load(body,'@'..name,'t',{}),'Invalid Lua file: '..name)
        write(fs.combine(release,name),body)
        -- Validate the stored bytes too, before selecting any of this release.
        assert(hash(read(fs.combine(release,name)))==e.sha256,'Disk verification failed: '..name)
        print('Verified '..name)
    end
    write(fs.combine(release,'.complete'),manifest.version..'\n')
    populate(root,release)
    write(fs.combine(root,'run.lua'),M.launcher(root,false))
    if not fs.exists(fs.combine(root,'update.lua')) then write(fs.combine(root,'update.lua'),M.launcher(root,true)) end
    activate(root,manifest.version,current and current.version or nil)
    if action=='install' then installStartup(root) end
    -- Keep selected and previous releases. Remove only versioned directories owned by this installation.
    local keep=M.current(root)
    for _,name in ipairs(fs.list(fs.combine(root,'releases'))) do
        if tag(name) and name~=keep.version and name~=keep.previous then remove(fs.combine(root,'releases/'..name)) end
    end
    print('Installed '..manifest.version..' in '..root)
    print('Settings, saved home and startup mode preserved. No reboot performed.')
    print('Run '..root..'/run or restart manually when ready.')
end
if ...=='__test' then return M end
local action,root=...
M.run(action or 'install',root)
