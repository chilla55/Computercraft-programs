-- Verified, bounded file transfer. Active files are never overwritten in place.
local M={chunkSize=4096,maxFile=1024*1024,maxTotal=4*1024*1024}
local allowed={['discovery.lua']=true,['interface.lua']=true,['app.lua']=true,['common.lua']=true,['runtime.lua']=true,['protection.lua']=true,['regulation.lua']=true,['planner.lua']=true,['ui.lua']=true,['updater.lua']=true,['sha256.lua']=true,['thermal_protection.lua']=true,['transformer.lua']=true}
local repository='https://raw.githubusercontent.com/chilla55/Computercraft-programs/'
function M.newer(a,b)
  local function parts(v) local x,y,z=v:match('^distributed%-(%d+)%.(%d+)%.(%d+)$'); return {tonumber(x),tonumber(y),tonumber(z)} end
  local x,y=parts(a),parts(b)
  for i=1,3 do assert(x[i] and y[i],'Invalid version'); if x[i]~=y[i] then return x[i]>y[i] end end
  return false
end
function M.validate(manifest)
  assert(type(manifest)=='table' and manifest.schema==1,'Invalid update manifest')
  assert(type(manifest.version)=='string' and manifest.version:match('^distributed%-%d+%.%d+%.%d+$'),'Invalid release tag')
  assert(manifest.ref==manifest.version,'Updates must use a versioned release tag')
  assert(type(manifest.files)=='table','Missing release files')
  local total,count=0,0
  for name,entry in pairs(manifest.files) do
    assert(allowed[name] and type(entry)=='table','Unapproved update path')
    assert(type(entry.size)=='number' and entry.size>=1 and entry.size%1==0 and entry.size<=M.maxFile,'Invalid file size')
    assert(type(entry.sha256)=='string' and #entry.sha256==64 and not entry.sha256:find('[^0-9a-f]'),'Invalid SHA-256')
    total=total+entry.size; count=count+1
  end
  for name in pairs(allowed) do assert(manifest.files[name],'Incomplete release: '..name) end
  assert(total<=M.maxTotal and count==13,'Oversized release'); return manifest
end
function M.receiver(manifest,hash,writeFile)
  M.validate(manifest)
  local received,finished={},{}
  local api={}
  function api.chunk(name,index,body)
    local f=assert(manifest.files[name],'Unknown transfer file')
    assert(type(index)=='number' and index%1==0 and index>=1 and index<=math.ceil(f.size/M.chunkSize),'Invalid chunk number')
    assert(type(body)=='string' and #body==math.min(M.chunkSize,f.size-(index-1)*M.chunkSize),'Invalid chunk length')
    local chunks=received[name] or {}; received[name]=chunks
    assert(not chunks[index] or chunks[index]==body,'Conflicting duplicate chunk')
    chunks[index]=body
    return true
  end
  function api.finish(name)
    local f=assert(manifest.files[name],'Unknown transfer file'); local chunks=received[name] or {}
    for i=1,math.ceil(f.size/M.chunkSize) do assert(chunks[i],'Missing chunk '..i) end
    local body=table.concat(chunks)
    assert(#body==f.size and hash(body)==f.sha256,'Release digest mismatch: '..name)
    assert(load(body,'@'..name,'t',{}),'Invalid Lua syntax: '..name)
    writeFile(name,body); finished[name]=true; return true
  end
  function api.complete() for name in pairs(manifest.files) do if not finished[name] then return false end end; return true end
  return api
end
function M.new(R)
  local U=R.U; local pending,manifest,staging,approval
  local savedPath=fs.combine(R.root,'staged-update.json')
  local function isolated()
    assert(R.state.latched and U.isolated(R.config.settings) and U.idle(R.config.settings),'Applying an update requires maintenance isolation')
  end
  local function begin(m)
    manifest=M.validate(m); staging=fs.combine(R.root,'releases/'..manifest.version)
    -- Never replace the active release, even if its tag was republished.
    assert(M.newer(manifest.version,U.release),'Refusing same-version replacement or automatic downgrade')
    if fs.exists(staging) then fs.delete(staging) end; fs.makeDir(staging)
    pending=M.receiver(manifest,R.modules.hash,function(name,body)
      local f=assert(fs.open(fs.combine(staging,name),'w')); f.write(body); f.close()
    end)
    R.state.updateReady=nil; R.state.updateDeferred=nil; approval=nil
  end
  local function verifyFiles()
    assert(manifest and pending and pending.complete(),'Incomplete staged update')
    for name,entry in pairs(manifest.files) do
      local f=assert(fs.open(fs.combine(staging,name),'r')); local bytes=f.readAll(); f.close()
      assert(#bytes==entry.size and R.modules.hash(bytes)==entry.sha256,'Staged release changed: '..name)
      assert(load(bytes,'@'..name,'t',{}),'Invalid staged Lua: '..name)
    end
  end
  local function markReady()
    verifyFiles()
    U.write(savedPath,{manifest=manifest,deferred=R.state.updateDeferred==manifest.version})
    R.state.updateReady=manifest.version
  end
  -- Staging survives restart; approval never does. Check bytes again before
  -- offering restored files and again immediately before activation.
  local restored,restoreError=pcall(function()
    local saved=U.read(savedPath)
    if not saved then return end
    local m=M.validate(saved.manifest)
    if not M.newer(m.version,U.release) then return end
    manifest=m; staging=fs.combine(R.root,'releases/'..m.version)
    pending={complete=function() return true end}
    verifyFiles(); R.state.updateReady=m.version
    if saved.deferred then R.state.updateDeferred=m.version end
  end)
  if not restored then pending=nil; manifest=nil; R.state.updateMessage='Staged update needs download again: '..tostring(restoreError) end
  local function activate(version)
    isolated(); assert(manifest and version==manifest.version and pending and pending.complete(),'Incomplete staged update')
    verifyFiles()
    local current=U.read(fs.combine(R.root,'active-release.json'))
    if not current or current.version~=version then
      U.write(fs.combine(R.root,'active-release.json'),{version=version,previous=current and current.version or 'bundled',pending=true})
    end
    R.rebootAt=R.now()+1000; R.rebootRequested=true
  end
  local api={}
  function api.receive(sender,m)
    assert(sender==R.config.ids.master,'Only configured UI master may distribute updates')
    if m.kind=='update_begin' then begin(m.data.manifest)
    elseif m.kind=='update_chunk' then assert(pending,'No transfer'); pending.chunk(m.data.name,m.data.index,m.data.body)
    elseif m.kind=='update_file' then assert(pending,'No transfer'); pending.finish(m.data.name)
    elseif m.kind=='update_finish' then assert(pending and pending.complete(),'Release incomplete'); markReady()
    elseif m.kind=='update_activate' then
      assert(m.data.approved==true and type(m.data.approvalId)=='string' and #m.data.approvalId>0,'Explicit master approval required')
      activate(m.data.version)
    else error('Unknown update command') end
  end
  local function get(url)
    assert(http,'HTTP is disabled')
    local f,why=http.get(url,nil,true); assert(f,why)
    local body=f.readAll(); f.close(); assert(type(body)=='string' and #body<=M.maxTotal,'Oversized HTTP response'); return body
  end
  local function request(role,kind,data)
    local id=R.token(); data.id=id; R.updatePending[id]=role
    for attempt=1,5 do
      R.send(role,kind,data)
      local finish=R.now()+2000
      repeat
        local ack=R.updateAcks[id]
        if ack then R.updateAcks[id]=nil; R.updatePending[id]=nil; assert(ack.ok,ack.reason); return end
        if kind=='update_activate' then isolated() end
        sleep(.05)
      until R.now()>=finish
    end
    R.updatePending[id]=nil; error('Update acknowledgement timed out: '..role)
  end
  function api.check()
    assert(R.role=='master','Only the UI master checks for updates')
    local release=M.validate(textutils.unserializeJSON(get(repository..'main/Powerplant/distributed/approved-release.json')))
    R.state.availableUpdate=release.version
    if not M.newer(release.version,U.release) then return end
    local reusable=manifest and manifest.version==release.version and pending and pending.complete()
    if reusable then
      for name,entry in pairs(release.files) do
        assert(manifest.files[name].sha256==entry.sha256 and manifest.files[name].size==entry.size,'Published release tag changed')
      end
      verifyFiles()
    else
      begin(release)
      for name,entry in pairs(release.files) do
        local body=get(repository..release.ref..'/Powerplant/distributed/'..name)
        assert(#body==entry.size and R.modules.hash(body)==entry.sha256,'GitHub file digest mismatch: '..name)
        for index=1,math.ceil(#body/M.chunkSize) do pending.chunk(name,index,body:sub((index-1)*M.chunkSize+1,index*M.chunkSize)) end
        pending.finish(name)
      end
    end
    -- Transfer while the current programs keep running. Only inactive staging
    -- files are written; no isolation, close request or reboot is performed.
    for _,role in ipairs({'regulation','protection'}) do
      local peer,version=R.updatePeer(role); assert(peer,'Worker unavailable for staging: '..role)
      if version~=release.version and peer.updateReady~=release.version then
        request(role,'update_begin',{manifest=release})
        for name in pairs(release.files) do
          local f=assert(fs.open(fs.combine(staging,name),'r')); local body=f.readAll(); f.close()
          for index=1,math.ceil(#body/M.chunkSize) do
            request(role,'update_chunk',{name=name,index=index,body=body:sub((index-1)*M.chunkSize+1,index*M.chunkSize)})
          end
          request(role,'update_file',{name=name})
        end
        request(role,'update_finish',{})
      end
    end
    markReady()
    R.state.updateMessage=release.version..' staged on all computers; approval required.'
  end
  function api.approve(version)
    assert(not R.state.updateApplying,'Update activation already in progress')
    assert(R.role=='master','Only the UI master can accept an upgrade')
    assert(manifest and R.state.updateReady==version and manifest.version==version,'Displayed update is no longer ready')
    approval={version=version,id=R.token()}
    R.state.updateDeferred=nil
    R.state.updateMessage='Apply requested; checking isolation and staged workers.'
    os.queueEvent('distributed_update_apply')
  end
  function api.defer(version)
    assert(not R.state.updateApplying,'Update activation already in progress')
    assert(R.role=='master' and manifest and manifest.version==version,'No matching staged update')
    approval=nil; R.state.updateDeferred=version; markReady()
    R.state.updateMessage='Upgrade postponed; current version remains active.'
  end
  function api.apply()
    assert(R.role=='master' and approval,'User approval required')
    local accepted=approval; approval=nil -- one attempt; no delayed surprise reboot
    assert(manifest and accepted.version==manifest.version and R.state.updateReady==manifest.version,'Approved version changed')
    isolated(); verifyFiles()
    for _,role in ipairs({'regulation','protection'}) do
      local peer,version=R.updatePeer(role)
      assert(peer and peer.latched,'Stop both workers before applying the update')
      assert(version==manifest.version or peer.updateReady==manifest.version,'Worker has not verified this release: '..role)
    end
    for _,role in ipairs({'regulation','protection'}) do
      request(role,'update_activate',{version=manifest.version,approved=true,approvalId=accepted.id})
    end
    activate(manifest.version)
  end
  function api.run()
    if R.role~='master' then while true do sleep(300) end end
    local nextCheck=0
    while true do
      if approval then
        R.state.updateApplying=true
        local ok,why=pcall(api.apply)
        if not ok then R.state.updateApplying=nil end
        if not ok then R.state.updateMessage='Not applied: '..tostring(why)..'. Press Apply to retry.' end
      elseif R.node.autoUpdate~=false and R.now()>=nextCheck then
        nextCheck=R.now()+300000
        local ok,why=pcall(api.check)
        if not ok then R.state.updateMessage=tostring(why)
        elseif not R.state.updateReady then R.state.updateMessage='No newer update available.' end
      end
      local timer=os.startTimer(1)
      repeat local event,id=os.pullEvent() until event=='distributed_update_apply' or (event=='timer' and id==timer)
    end
  end
  return api
end
return M
