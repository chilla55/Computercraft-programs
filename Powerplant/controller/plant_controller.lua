-- ComputerCraft plant supervisor. Run `plant_controller.lua configure` first.
local args={...}
local directory=fs.getDir(shell.getRunningProgram())
local core=assert(loadfile(fs.combine(directory,'controller_core.lua')))()
local UI=assert(loadfile(fs.combine(directory,'controller_ui.lua')))()
local PATH='plant-controller-config.json'
local C={version=2,buses={},monitor='',modem='',voltageGauge='',currentGauge='',nominalVoltage=2640,
  gridMinVoltage=2376,gridMaxVoltage=2904,currentLimitAmps=0,sampleMaxAgeMs=1000,nodeTimeoutMs=2000,
  upstreamId=-1,transformers={},generators={},transmission={inputGauge='',outputGauge='',ratio=0}}
if fs.exists(PATH) then
  local f=assert(fs.open(PATH,'r')); local saved=textutils.unserializeJSON(f.readAll()); f.close()
  assert(type(saved)=='table' and (saved.version==1 or saved.version==2),'Invalid plant controller configuration')
  for key in pairs(C) do if saved[key]~=nil then C[key]=saved[key] end end
end
C.version=2
local function methods(name)
  local set={}; for _,method in ipairs(peripheral.getMethods(name) or {}) do set[method]=true end; return set
end
local function choose(label,key,accept,optional)
  print('\n'..label)
  local names=peripheral.getNames(); table.sort(names); local candidates={}
  for _,name in ipairs(names) do if accept(methods(name),name) then candidates[#candidates+1]=name; print(#candidates..': '..name) end end
  while true do
    write('Name/number ['..C[key]..']'..(optional and ' (- clears)' or '')..': ')
    local answer=read(); local chosen=answer=='' and C[key] or answer=='-' and '' or candidates[tonumber(answer)] or answer
    if optional and chosen=='' then C[key]=''; return end
    for _,name in ipairs(candidates) do if name==chosen then C[key]=chosen; return end end
    print('Select an available peripheral.')
    assert(#candidates>0 or optional,'No compatible peripherals; connect devices and configure again')
  end
end
local function numeric(label,key)
  while true do write(label..' ['..C[key]..']: '); local v=read(); local n=v=='' and C[key] or tonumber(v)
    if core.finite(n) then C[key]=n; return end; print('Enter a finite number.') end
end
local function nodes(label,key)
  print(label..' (computer IDs, comma separated; - clears)')
  local previous={}; for _,n in ipairs(C[key]) do previous[#previous+1]=tostring(n.id) end
  write('['..table.concat(previous,',')..']: '); local answer=read()
  if answer=='' then return end
  C[key]={}; if answer=='-' then return end
  for part in answer:gmatch('[^,]+') do
    local id=assert(tonumber(part),'Invalid computer ID')
    write('Label for #'..id..': '); local name=read()
    C[key][#C[key]+1]={id=id,name=name~='' and name or (key=='transformers' and 'Transformer ' or 'Generator ')..id}
  end
end
if args[1]=='configure' then
  print('Main plant controller #'..os.getComputerID())
  choose('Touch monitor','monitor',function(m) return m.setTextScale and m.getSize and m.write end)
  choose('Ender modem for computer-to-computer rednet','modem',function(m,name)
    local ok,wireless=pcall(function() return peripheral.wrap(name).isWireless() end)
    return m.transmit and m.open and m.isOpen and ok and wireless==true
  end)
  choose('GRID-SIDE voltage gauge (live with transformers disconnected)','voltageGauge',function(m) return m.voltage end)
  choose('Optional GRID current gauge','currentGauge',function(m) return m.current or m.getValue end,true)
  numeric('Nominal grid voltage','nominalVoltage'); numeric('Minimum healthy voltage','gridMinVoltage'); numeric('Maximum healthy voltage','gridMaxVoltage')
  numeric('Absolute grid current limit A (0 = display only)','currentLimitAmps')
  nodes('Managed transformers','transformers'); nodes('Optional future generator telemetry senders','generators')
  -- Output buses have their own measured voltages and operating limits.
  write('Additional output bus IDs, comma separated (- clears, blank keeps): ')
  local busAnswer=read()
  if busAnswer~='' then
    C.buses={}
    if busAnswer~='-' then for id in busAnswer:gmatch('[^,]+') do
      id=id:match('^%s*(.-)%s*$')
      local root=C
      C={id=id,name=id,voltageGauge='',currentGauge='',nominalVoltage=2640,gridMinVoltage=2376,gridMaxVoltage=2904,currentLimitAmps=0}
      choose('Bus '..id..' OUTPUT voltage gauge','voltageGauge',function(m) return m.voltage end)
      choose('Optional bus current gauge','currentGauge',function(m) return m.current or m.getValue end,true)
      numeric('Bus nominal voltage','nominalVoltage'); numeric('Bus minimum healthy voltage','gridMinVoltage'); numeric('Bus maximum healthy voltage','gridMaxVoltage')
      numeric('Bus current limit (0 = monitor only)','currentLimitAmps')
      root.buses[#root.buses+1]=C; C=root
    end end
  end
  for _,n in ipairs(C.transformers) do
    write(n.name..' role generator/consumer/transmission ['..(n.role or 'generator')..']: ')
    local role=read(); n.role=role~='' and role or n.role or 'generator'
    write('Output bus ID ['..(n.bus or 'local')..']: '); local bus=read(); n.bus=bus~='' and bus or n.bus or 'local'
    write('Connection mode parallel/supply ['..(n.connectionMode or 'parallel')..']: ')
    local mode=read(); n.connectionMode=mode~='' and mode or n.connectionMode or 'parallel'
    write('Dead circuit threshold volts ['..(n.deadBusVolts or 5)..']: ')
    local dead=read(); n.deadBusVolts=dead~='' and assert(tonumber(dead),'Invalid voltage') or n.deadBusVolts or 5
    write('Associated generator ID (-1 = none) ['..(n.generatorId or -1)..']: ')
    local generator=read(); n.generatorId=generator~='' and assert(tonumber(generator),'Invalid generator ID') or n.generatorId or -1
  end
  numeric('Upstream network controller ID (-1 = disabled)','upstreamId')
  -- Separate diagnostic ports: these never replace the local grid reference.
  local root=C; C=root.transmission
  choose('Optional future transmission INPUT voltage gauge','inputGauge',function(m) return m.voltage end,true)
  choose('Optional future transmission OUTPUT voltage gauge','outputGauge',function(m) return m.voltage end,true)
  numeric('Transmission output/input multiplier (0 = unknown)','ratio')
  C=root
  core.validate(C)
  for _,list in ipairs({C.transformers,C.generators}) do for _,n in ipairs(list) do assert(n.id~=os.getComputerID(),'A remote node cannot be this computer') end end
  assert(C.upstreamId~=os.getComputerID(),'Upstream cannot be this computer')
  local f=assert(fs.open(PATH,'w')); f.write(textutils.serializeJSON(C)); f.close()
  print('Saved. Set every regulator masterId to '..os.getComputerID()..'. Start with plant_controller.lua run.'); return
end
assert(args[1]==nil or args[1]=='run','Use configure or run')
core.validate(C)
local monitor=peripheral.wrap(C.monitor)
if monitor then pcall(monitor.setTextScale,.5) end
-- Only this dedicated ender link carries rednet; wired peripherals remain accessible.
rednet.close()
local link={available=false,reason='Waiting for ender modem'}
local function openLink()
  local ok,reason=pcall(function()
    local modem=assert(peripheral.wrap(C.modem),'Ender modem unavailable')
    assert(type(modem.isWireless)=='function' and modem.isWireless()==true,'Computer link requires an ender/wireless modem, not a wired modem')
    if not rednet.isOpen(C.modem) then rednet.open(C.modem) end
  end)
  link.available=ok; link.reason=not ok and tostring(reason) or nil
  return ok
end
local function send(id,message,protocol)
  if not openLink() then return false end
  local ok,result=pcall(rednet.send,id,message,protocol)
  if not ok then link.available=false; link.reason=tostring(result) end
  return ok and result~=false
end
openLink()
local function now() return os.epoch('utc') end
local session=tostring(os.getComputerID())..':'..now()..':'..math.random(1,2147483647)
local plant=core.new(C,os.getComputerID(),session,function(id,m,protocol) return send(id,m,protocol) end)
local ui=UI.new(monitor); local running=true
local function readGauge(name,method)
  if name=='' then return nil end
  local ok,value=pcall(function()
    local device=assert(peripheral.wrap(name),'Gauge detached')
    local fn=device[method] or (method=='current' and device.getValue)
    assert(type(fn)=='function','Missing gauge method'); return fn()
  end)
  return ok and core.finite(value) and value or nil
end
local function action(kind,id)
  if kind=='select' then ui.selected=id
  elseif kind=='tab' then ui.page=ui.page=='transformers' and 'generators' or 'transformers'; ui.selected=1
  elseif kind=='next' or kind=='previous' then
    local count=ui.page=='transformers' and #C.transformers or #C.generators
    ui.selected=math.max(1,math.min(count,ui.selected+(kind=='next' and 1 or -1)))
  elseif kind=='stop' then plant.stop(now()); ui.notice='Disable requested for all; verify breaker feedback'
  elseif kind then local ok,reason=plant.action(id,kind,now()); ui.notice=ok and (kind..' requested') or tostring(reason) end
end
local function measureBus(b)
  while running do
    local volts=readGauge(b.voltageGauge,'voltage'); local sampled=now()
    local amps=readGauge(b.currentGauge,'current')
    -- Reject a scan delayed enough that the voltage timestamp is no longer fresh.
    if now()-sampled>C.sampleMaxAgeMs then volts=nil; amps=nil end
    plant.measureBus(b.id,volts,amps,sampled)
    sleep(.25)
  end
end
local function transmissionMeasurements()
  while running do
    local input=readGauge(C.transmission.inputGauge,'voltage'); local sampled=now()
    local output=readGauge(C.transmission.outputGauge,'voltage')
    if now()-sampled>C.sampleMaxAgeMs then input=nil; output=nil end
    plant.measureTransmission(input,output,sampled); sleep(.5)
  end
end
local function dispatch()
  while running do plant.tick(now()); sleep(.5) end
end
local function receive()
  while running do
    local ok,sender,m,protocol=pcall(rednet.receive,nil,.25)
    if not ok then
      if tostring(sender):find('Terminated',1,true) then error(sender,0) end
      link.available=false; link.reason=tostring(sender); sleep(.25)
    end
    if ok and sender then plant.receive(sender,m,protocol,now()) end
  end
end
local function display()
  while running do
    local snapshot=plant.snapshot(now()); openLink(); snapshot.network={available=link.available,reason=link.reason,modem=C.modem}
    local drawn=pcall(function()
      local device=assert(peripheral.wrap(C.monitor),'Monitor unavailable')
      device.setTextScale(.5); ui.attach(device); ui.draw(snapshot)
    end)
    if not drawn then ui.notice='Monitor unavailable; local supervision remains active' end
    if C.upstreamId>=0 then send(C.upstreamId,snapshot,core.NETWORK) end
    sleep(.5)
  end
end
local function input()
  while running do
    local e,a,b,c=os.pullEvent()
    if e=='monitor_touch' and a==C.monitor then action(ui.touch(b,c))
    elseif e=='key' then
      if a==keys.q then running=false; return
      elseif a==keys.space then action('stop')
      elseif a==keys.left then action('previous') elseif a==keys.right then action('next')
      elseif a==keys.tab then action('tab') end
    end
  end
end
print('Plant controller running. Q: exit supervision; Space: explicitly disable all.')
local tasks={transmissionMeasurements,dispatch,receive,display,input}
for _,bus in ipairs(core.buses(C)) do
  local b=bus; tasks[#tasks+1]=function() measureBus(b) end
end
local ok,err=pcall(function() parallel.waitForAny(table.unpack(tasks)) end)
running=false; plant.release(now())
pcall(function() ui.notice='Supervisor stopped; autonomous regulators continue locally'; ui.draw(plant.snapshot(now())) end)
if not ok then printError(tostring(err)) end
print('Stopped supervision. Autonomous regulators continue locally; explicit disables remain in effect.')
print('Generator shafts/clutches are not controlled by this program.')
