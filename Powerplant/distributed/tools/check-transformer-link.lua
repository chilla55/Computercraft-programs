-- Run on the master after quitting its UI; leave both worker programs running.
-- Passive Rednet inspection. No commands, config writes, or breaker operations.
local root=(... or 'transformer')
local function read(path)
 local f=assert(fs.open(path,'r'),'Missing '..path)
 local value=textutils.unserializeJSON(f.readAll()); f.close()
 return assert(type(value)=='table' and value,'Invalid JSON: '..path)
end
local node=read('/config/distributed-node.json')
assert(node.role=='master','Run on the master')
local folder=root
local pointer=fs.combine(root,'active-release.json')
if fs.exists(pointer) then
 local active=read(pointer)
 if active.version and active.version~='bundled' then
  assert(active.version:match('^distributed%-%d+%.%d+%.%d+$'),'Invalid release pointer')
  folder=fs.combine(root,'releases/'..active.version)
 end
end
local U=assert(loadfile(fs.combine(folder,'common.lua'),'t',_ENV))()
local hash=assert(loadfile(fs.combine(folder,'sha256.lua'),'t',_ENV))()
local config=node.config
local digest=hash(U.canonical(config))
local modem=assert(peripheral.wrap(node.modem),'Missing configured modem '..tostring(node.modem))
assert(modem.isWireless()==false,'Configured local modem is not wired')
local wasOpen=rednet.isOpen(node.modem)
rednet.open(node.modem)
local report={schema=1,kind='passive_link_check',startedAt=os.epoch('utc'),
 computer=os.getComputerID(),configuredMaster=config.ids.master,release=U.release,
 cluster=config.cluster,revision=config.revision,digest=digest,modem=node.modem,expected=config.ids,peers={}}
print('Listening for 12 seconds. Keep both worker programs running.')
print('Master '..report.computer..', '..U.release..', config revision '..config.revision)
local ok,why=pcall(function()
 local finish=os.epoch('utc')+12000
 while os.epoch('utc')<finish do
  local sender,m=rednet.receive(U.protocol,.5)
  if type(m)=='table' and (m.kind=='hello' or m.kind=='heartbeat') then
   local key=tostring(sender)..':'..tostring(m.role)
   local peer=report.peers[key] or {computer=sender,role=m.role,messages=0}
   report.peers[key]=peer; peer.messages=peer.messages+1
   peer.release=m.release; peer.revision=m.revision; peer.digest=m.digest
   peer.clockDifferenceMs=type(m.sentAt)=='number' and os.epoch('utc')-m.sentAt or nil
   peer.idMatches=config.ids[m.role]==sender
   peer.releaseMatches=m.release==U.release; peer.revisionMatches=m.revision==config.revision
   peer.configMatches=m.digest==digest
   if m.kind=='heartbeat' and type(m.data)=='table' then
    peer.phase=m.data.phase; peer.fault=m.data.fault; peer.message=m.data.message
    peer.latched=m.data.latched
   end
  end
 end
end)
if not wasOpen then rednet.close(node.modem) end
report.finishedAt=os.epoch('utc'); report.error=not ok and tostring(why) or nil
for _,role in ipairs({'regulation','protection'}) do
 local found=false
 for _,peer in pairs(report.peers) do
  if peer.role==role then
   found=true
   print(role..' ID '..peer.computer..': ID '..tostring(peer.idMatches)..', version '..tostring(peer.releaseMatches)..', revision '..tostring(peer.revisionMatches)..', config '..tostring(peer.configMatches))
   if peer.message then print(peer.message) end
  end
 end
 if not found then print(role..': no heartbeat received') end
end
local destination='/config/transformer-link-check.json'
local encoded=textutils.serializeJSON(report)
local out=assert(fs.open(destination,'w')); out.write(encoded); out.close()
print('Report: '..destination)
print('Restart master: '..fs.combine(root,'transformer.lua')..' run')
