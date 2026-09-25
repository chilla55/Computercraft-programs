local M={}
function M.run(R)
  local U,s=R.U,R.config.settings
  local output,screen,width,height,dirty
  dirty=true
  local function selectOutput()
    local target=term
    if R.role=='master' and R.node.monitor then
      local candidate=peripheral.wrap(R.node.monitor)
      if candidate and candidate.setTextScale then target=candidate end
    end
    -- Peripheral wrappers are recreated by wrap; compare the selected name.
    local name=target==term and 'terminal' or R.node.monitor
    if name~=output then
      output=name
      if target~=term then target.setTextScale(0.5) end
      width,height=target.getSize()
      local proxy=setmetatable({getSize=function() return width,height end},{__index=target})
      screen=R.modules.ui.new(proxy,colors)
    else width,height=target.getSize() end
  end
  local cache={phase=R.role,config=s,maintenance={},stages={},inputBreakers={},breakers={},voltages={},sourceMeters={},events=R.events}
  for _,k in ipairs({'input','output','source','preStepUp'}) do cache.voltages[k]={} end
  cache.sourceMeters.current={}; cache.sourceMeters.power={}
  local function faultStatus()
    local protection=R.role=='protection' and R.state or R.fresh('protection')
    local regulation=R.role=='regulation' and R.state or R.fresh('regulation')
    local pending
    local peers={protection=protection,regulation=regulation}
    for _,role in ipairs({'protection','regulation'}) do
      local peer=peers[role]
      if peer and peer.latched and peer.fault then
        if not peer.tripPending then return peer.fault,false end
        pending=peer.fault
      end
    end
    if pending then return pending,true end
    if R.state.latched and R.state.fault and
      (not protection or not regulation or (R.faultAt and R.now()-R.faultAt<2000)) then
      return R.state.fault,R.state.tripPending
    end
  end
  local function snapshot()
    local data={phase=R.role,config={},maintenance={},stages={},inputBreakers={},breakers={},voltages={},sourceMeters={},events=R.events,
      entryRatio=s.entryRatio,stepUp=s.stepUp,sparkGapVolts=7500}
    for _,key in ipairs(U.editable) do data.config[key]=U.copy(s[key]) end
    local protection=R.role=='protection' and R.state or R.fresh('protection')
    local regulation=R.role=='regulation' and R.state or R.fresh('regulation')
    data.phase=R.role..' / '..(protection and protection.phase or 'protection offline')
    data.nominalTarget=protection and protection.target or s.target
    data.target=regulation and regulation.activeTarget or data.nominalTarget; data.config.target=data.nominalTarget
    data.maintenance.active=protection and protection.latched and regulation and regulation.latched or false
    data.fault=(protection and protection.latched and protection.fault) or (regulation and regulation.latched and regulation.fault)
    data.maintenance.reason=data.fault
    local ok,isolated=pcall(U.isolated,s); data.maintenance.verified=ok and isolated
    local good,idle=pcall(U.idle,s); data.maintenance.drivesIdle=good and idle
    for i,key in ipairs({'input','output','source','preStepUp'}) do
      local name=({s.inputGauge,s.outputGauge,s.sourceGauge,s.preStepUpGauge})[i]
      local sample={peripheral=name,available=false}; data.voltages[key]=sample
      if name~='' then local read,v=pcall(U.voltage,name); if read then sample.available=true; sample.volts=v; data[key..'Voltage']=v end end
    end
    for _,key in ipairs({'current','power'}) do
      local name=key=='current' and s.sourceCurrentGauge or s.sourcePowerGauge
      local sample={peripheral=name,available=false}; data.sourceMeters[key]=sample
      if name~='' then
        local read,v=pcall(function() local p=U.device(name); return (p[key] or p.getValue)() end)
        if read and U.finite(v) then sample.available=true; sample[key=='current' and 'amps' or 'watts']=v end
      end
    end
    local temps={}; if protection then for _,v in ipairs(protection.temperatures or {}) do if R.now()-v.sampledAt<=s.thermalMaxAgeSeconds*1000 then temps[v.name]=v.temperature end end end
    for i,key in ipairs({'A','B','C'}) do
      local bank={gear=s['gear'..key],members={}}; data.stages[i]=bank
      for _,name in ipairs(s['variacs'..key]) do
        local read,v=pcall(function() return U.device(name).getStatus() end)
        bank.members[#bank.members+1]={name=name,position=read and v.position or nil,temperature=temps[name]}
      end
    end
    for _,name in ipairs(s.inputBreakers) do local read,v=pcall(function() return U.device(name).getStatus() end); data.inputBreakers[#data.inputBreakers+1]={name=name,available=read,status=read and v or nil} end
    for i,name in ipairs({s.plusBreaker,s.minusBreaker}) do local read,v=pcall(function() return U.device(name).getStatus() end); if read then data.breakers[i]=v end end
    return data
  end
  local function action(a)
    if a.kind=='emergency' or a.kind=='maintenance' or a.kind=='stop' then
      R.trip(a.kind=='emergency' and 'emergency_stop' or 'operator_stop','Operator requested '..a.kind)
      if a.kind=='stop' then error('STOP',0) end
    elseif a.kind=='update_check' then
      R.updater.requestCheck()
    elseif a.kind=='update_apply' then
      R.updater.approve(a.version)
    elseif a.kind=='update_later' then
      R.updater.defer(a.version)
    elseif a.kind=='resume' then
      if R.role=='master' then R.send('protection','start',{})
      elseif R.role=='protection' then R.commands[#R.commands+1]={kind='start',data={}}
      else error('Request start from the master or protection screen') end
    elseif a.kind=='setting' then
      assert(R.role=='master','Configuration belongs to the UI master')
      local old=s[a.key]; assert(old~=nil,'Unknown setting'); local v=a.value
      if type(old)=='number' then v=tonumber(v); assert(U.finite(v),'Enter a number')
      elseif type(old)=='boolean' then assert(v=='true' or v=='false','Enter true/false'); v=v=='true'
      elseif type(old)=='table' then local list={}; for x in v:gmatch('[^,%s]+') do list[#list+1]=x end; v=list end
      if a.key=='target' then R.send('protection','target',{target=v}); return end
      assert(cache.maintenance.active and U.isolated(s) and U.idle(s),'Configuration requires stopped workers and isolation')
      local nextConfig=U.copy(R.config); nextConfig.settings[a.key]=v; nextConfig.revision=nextConfig.revision+1
      U.validate(nextConfig); assert(U.isolated(nextConfig.settings) and U.idle(nextConfig.settings),'New mappings must be isolated')
      R.node.config=nextConfig; U.write('distributed-node.json',R.node); R.rebootRequested=true
    end
  end
  local function input()
    while true do
      local e={os.pullEvent()}
      if e[1]=='monitor_touch' and e[2]==output then e={'mouse_click',1,e[3],e[4]}
      elseif e[1]=='mouse_click' and output~='terminal' then e={} end
      if screen then
        local a=screen.event(table.unpack(e))
        if a then local ok,why=pcall(action,a); if not ok then if why=='STOP' then error(why,0) end; R.state.message=tostring(why) end end
      end
      if e[1]~='timer' then dirty=true end
    end
  end
  local function render()
    local lastEdit
    while true do
      if dirty or (screen and screen.animating()) then
        dirty=false
        local ok,why=pcall(function()
          selectOutput()
          cache.message=R.state.message or R.state.updateMessage or ''; cache.events=R.events
          cache.fault,cache.tripPending=faultStatus()
          cache.updateReady=R.state.updateReady; cache.updateDeferred=R.state.updateDeferred
          cache.updateApplying=R.state.updateApplying; cache.updateCanApprove=R.role=='master'
          cache.updateChecking=R.state.updateChecking; cache.updateMessage=R.state.updateMessage
          cache.runningVersion=U.release; cache.availableUpdate=R.state.availableUpdate
          cache.autoUpdate=R.node.autoUpdate~=false
          cache.updateWorkers={}
          for _,role in ipairs({'regulation','protection'}) do
            local peer,version=R.updatePeer(role)
            if role==R.role then peer,version=R.state,U.release end
            cache.updateWorkers[role]={online=peer~=nil,version=version,ready=peer and peer.updateReady}
          end
          screen.draw(cache)
          if output~='terminal' then
            local edit=screen.editing()
            local text=edit and (edit.key..': '..edit.text..'\nEnter: save / Escape: cancel') or 'Transformer UI on '..output..'\nTouch monitor; type values here. E: emergency stop.'
            if text~=lastEdit then term.clear(); term.setCursorPos(1,1); print(text); lastEdit=text end
          end
        end)
        if not ok then R.state.message='Display: '..tostring(why); dirty=true; output=nil end
      end
      sleep(0.1)
    end
  end
  local function sample()
    while true do
      local ok,v=pcall(snapshot); if ok then cache=v else R.state.message=tostring(v) end
      os.queueEvent('distributed_ui'); sleep(1)
    end
  end
  parallel.waitForAny(input,sample,render)
end
return M
