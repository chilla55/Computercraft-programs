local root='Powerplant/distributed/'
local U=dofile(root..'common.lua'); local hash=dofile(root..'sha256.lua'); local Update=dofile(root..'updater.lua')
local count=0
local function check(v,why) assert(v,why); count=count+1 end
check(hash('')=='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855','empty SHA')
check(hash('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','abc SHA')
check(hash(string.rep('a',1000))=='41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3','multi-block SHA')
local manifest={schema=1,version='distributed-1.0.1',ref='distributed-1.0.1',files={}}
local names={'app','common','runtime','protection','regulation','planner','ui','interface','updater','sha256','thermal_protection','transformer'}
local body='return '..string.format('%q',string.rep('x',9000))
for _,name in ipairs(names) do manifest.files[name..'.lua']={size=#body,sha256=hash(body)} end
local written={}; local receiver=Update.receiver(manifest,hash,function(name,data) written[name]=data end)
check(not receiver.complete(),'empty transfer complete')
check(not pcall(receiver.finish,'app.lua'),'partial file accepted')
check(not pcall(receiver.chunk,'../startup.lua',1,body),'path traversal')
check(not pcall(receiver.chunk,'app.lua',0,'x'),'zero index')
for _,name in ipairs(names) do
  name=name..'.lua'
  for i=math.ceil(#body/4096),1,-1 do local part=body:sub((i-1)*4096+1,i*4096); receiver.chunk(name,i,part); receiver.chunk(name,i,part) end
  check(receiver.finish(name) and written[name]==body,'reassembled file wrong')
end
check(receiver.complete(),'full release incomplete')
check(not pcall(receiver.chunk,'app.lua',1,string.rep('z',4096)),'conflicting retransmission')
local bad=U.copy(manifest); bad.files['app.lua'].sha256=string.rep('0',64)
local broken=Update.receiver(bad,hash,function() error('must not write corrupt bytes') end)
for i=1,math.ceil(#body/4096) do broken.chunk('app.lua',i,body:sub((i-1)*4096+1,i*4096)) end
check(not pcall(broken.finish,'app.lua'),'hash mismatch accepted')
local cfg={revision=1,ids={master=1,regulation=2,protection=3}}; local peers={}
local m={schema=1,revision=1,release=U.release,role='regulation',session='boot1',seq=1,sentAt=1000,kind='hello'}
check(U.accept(cfg,peers,2,m,1000),'hello rejected')
check(not U.accept(cfg,peers,2,m,1000),'replay accepted')
m.seq=2; m.kind='heartbeat'; m.data={cycle='one'}
check(U.accept(cfg,peers,2,m,1000),'heartbeat rejected')
check(not U.accept(cfg,peers,3,m,1000),'wrong sender accepted')
m.seq=3; m.sentAt=0; check(not U.accept(cfg,peers,2,m,3000),'stale message accepted')
m.sentAt=3000; m.session='boot2'; check(not U.accept(cfg,peers,2,m,3000),'unknown boot command accepted')
m.kind='hello'; check(U.accept(cfg,peers,2,m,3000),'new boot hello rejected')
check(U.canonical({a=1,b={2,3}})==U.canonical({b={2,3},a=1}),'unstable configuration digest')
print(('PASS: %d distributed core/update checks'):format(count))
