local root,command,requestedRole=...
local function module(name) return assert(loadfile(fs.combine(root,name..'.lua')))() end
local U=module('common')
local D=module('discovery')
local node=U.read('distributed-node.json')
local function prompt(label,default,parse)
  write(label..' ['..tostring(default or '')..']: '); local value=read()
  if value=='' then return default end
  return parse and assert(parse(value),'Invalid '..label) or value
end
local function configure()
  local role=requestedRole or prompt('Role: master, regulation, protection',node and node.role or 'master')
  assert(role=='master' or role=='regulation' or role=='protection','Unknown role')
  local wired,wireless=D.modems()
  assert(#wired>0,'Connect this computer to the gauges/peripherals using a wired modem')
  print('Wired modems: '..table.concat(wired,', '))
  local current=node and node.modem
  local default=wired[1]; for _,name in ipairs(wired) do if name==current then default=name end end
  local modem=prompt('Local wired modem peripheral',default)
  D.open(modem)
  local cluster=prompt('Transformer cluster name',node and node.config.cluster or 'transformer')
  D.host(cluster,role)
  local uplink,monitor
  if role=='master' then uplink=prompt('Optional ender uplink (- for none)',node and node.uplinkModem or wireless[1] or '-'); if uplink=='-' then uplink=nil end end
  if role=='master' then
    local monitors={}; for _,name in ipairs(peripheral.getNames()) do
      if peripheral.hasType(name,'monitor') then monitors[#monitors+1]=name end
    end
    table.sort(monitors)
    print('Monitors: '..table.concat(monitors,', '))
    monitor=prompt('UI monitor (- for computer screen)',node and node.monitor or monitors[1] or '-')
    if monitor=='-' then monitor=nil else assert(peripheral.hasType(monitor,'monitor'),'Choose a connected monitor') end
  end
  local function discover(other)
    print('Discovering '..other..' for '..cluster..'. Run configure '..other..' on that computer.')
    while true do
      local id=D.find(cluster,other)
      if id then print('Found '..other..' computer '..id); return id end
      sleep(1)
    end
  end
  if role=='master' then
    local legacy=U.read('dual-variac-config.json')
    local settings=node and node.config and node.config.settings or legacy
    assert(settings,'Copy the existing dual-variac-config.json to the master before initial configuration')
    settings=U.copy(settings)
    for _,key in ipairs({'A','B','C'}) do if not settings['variacs'..key] then settings['variacs'..key]={settings['variac'..key]} end end
    settings.inputBreakers=settings.inputBreakers or {}
    settings.entryRatio=settings.entryRatio or 1; settings.sourceGauge=settings.sourceGauge or ''; settings.preStepUpGauge=settings.preStepUpGauge or ''
    settings.sourceCurrentGauge=settings.sourceCurrentGauge or ''; settings.sourcePowerGauge=settings.sourcePowerGauge or ''; settings.sourceCurrentTripAmps=settings.sourceCurrentTripAmps or 0
    settings.thermalMaxAgeSeconds=settings.thermalMaxAgeSeconds or 1; settings.thermalGraceSeconds=settings.thermalGraceSeconds or 5; settings.thermalCoolSeconds=settings.thermalCoolSeconds or 5
    local config={schema=1,cluster=cluster,revision=node and node.config.revision+1 or 1,settings=settings,
      ids={master=os.getComputerID(),regulation=discover('regulation'),protection=discover('protection')}}
    print('Detected peripherals:'); for _,name in ipairs(peripheral.getNames()) do print(' '..name..' ['..tostring(peripheral.getType(name))..']') end
    for _,key in ipairs({'inputGauge','outputGauge','sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge','plusBreaker','minusBreaker','inputBreakers','gearA','variacsA','gearB','variacsB','gearC','variacsC'}) do
      local old=settings[key]; local list=type(old)=='table'
      local value=prompt(key..(list and ' (comma-separated names)' or ''),list and table.concat(old,',') or old)
      if list then local names={}; for name in value:gmatch('[^,%s]+') do names[#names+1]=name end; settings[key]=names else settings[key]=value=='-' and '' or value end
    end
    settings.target=prompt('Nominal output volts',settings.target,tonumber)
    U.validate(config)
    assert(U.isolated(settings) and U.idle(settings),'Open input/output breakers and wait for drives before commissioning')
    node={role=role,modem=modem,uplinkModem=uplink,monitor=monitor,autoUpdate=true,config=config}
  else
    local master=discover('master')
    print('Requesting configuration; master must be running and have this computer ID configured.')
    local config
    while not config do
      rednet.send(master,{kind='config_request',role=role},U.protocol)
      local sender,m=rednet.receive(U.protocol,2)
      if sender==master and type(m)=='table' and m.kind=='config_bundle' then config=U.validate(m.data.config); break end
    end
    assert(config and config.ids[role]==os.getComputerID(),'No matching configuration received')
    assert(config.ids.master==master and config.cluster==cluster,'Unexpected master/cluster identity')
    assert(U.isolated(config.settings) and U.idle(config.settings),'Commission only with contacts open and drives idle')
    node={role=role,modem=modem,autoUpdate=true,config=config}
  end
  U.write('distributed-node.json',node)
  print('Saved '..role..'; run transformer.lua run. The old regulator must remain stopped.')
end
if command=='configure' then configure(); return end
assert(node,'Run transformer.lua configure master|regulation|protection first')
U.validate(node.config); assert(node.config.ids[node.role]==os.getComputerID(),'Configuration belongs to another computer')
if node.role~='master' or command=='trip' then
  local isolated,reason=U.openAll(node.config.settings); assert(isolated,reason)
end
if command=='trip' then print('All configured breakers verified open.'); return end
D.open(node.modem); D.host(node.config.cluster or 'transformer',node.role)
assert(command==nil or command=='run','Use configure, run, trip or rollback')
local modules={common=U,thermal=module('thermal_protection'),planner=module('planner'),hash=module('sha256'),ui=module('ui'),updater=module('updater')}
local R=module('runtime').new(node.config,node,modules,fs.getDir(shell.getRunningProgram()))
local worker
if node.role~='master' then
  local ready,result=pcall(function() return module(node.role).new(R) end)
  if not ready then R.trip('startup_failure',tostring(result)); print(tostring(result)); return end
  worker=result
end
local function control() if worker then worker.run() else while true do sleep(1) end end end
local interface=module('interface')
local ok,why=pcall(function() parallel.waitForAny(control,R.receive,R.heartbeat,R.watchdog,R.updater.run,function() interface.run(R) end) end)
if node.role~='master' then
  if not ok then pcall(R.trip,'runtime_failure',tostring(why)) end
  U.openAll(node.config.settings)
end
R.state.latched=true; pcall(R.persist)
print(ok and 'Stopped; breakers opened.' or tostring(why))
