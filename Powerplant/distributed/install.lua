-- Initial HTTPS installer. Run from the computer root; no disk drive required.
local directory=... or 'transformer'
assert(type(directory)=='string' and directory:match('^[%w_-]+$'),'Use a simple installation directory name')
assert(not fs.exists(directory),'Installation already exists; use the running updater instead')
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
local repository='https://raw.githubusercontent.com/chilla55/Computercraft-programs/'
local function get(url)
  assert(http,'HTTP is disabled on this server')
  local f,reason=http.get(url,nil,true); assert(f,reason)
  local data=f.readAll(); f.close(); return data
end
local manifest=assert(textutils.unserializeJSON(get(repository..'main/Powerplant/distributed/release.json')),'Invalid manifest')
assert(manifest.schema==1 and type(manifest.version)=='string' and manifest.version:match('^distributed%-%d+%.%d+%.%d+$') and manifest.ref==manifest.version,'Invalid release tag')
local names={'app','common','runtime','protection','regulation','planner','ui','interface','updater','sha256','thermal_protection','transformer'}
local staging=directory..'-download'
if fs.exists(staging) then fs.delete(staging) end
fs.makeDir(staging)
for _,name in ipairs(names) do
  name=name..'.lua'
  local entry=assert(manifest.files[name],'Missing '..name)
  assert(type(entry.size)=='number' and entry.size>0 and entry.size<=1048576,'Invalid size')
  local bytes=get(repository..manifest.ref..'/Powerplant/distributed/'..name)
  assert(#bytes==entry.size and hash(bytes)==entry.sha256,'Hash/size mismatch: '..name)
  assert(load(bytes,'@'..name,'t',{}),'Invalid Lua: '..name)
  local f=assert(fs.open(fs.combine(staging,name),'w')); f.write(bytes); f.close()
  print('Verified '..name)
end
fs.move(staging,directory)
print('Installed '..manifest.version..' in '..directory)
print('Commission with breakers open and old regulator stopped:')
print(directory..'/transformer.lua configure master')
print('Use regulation or protection on the two worker computers.')
