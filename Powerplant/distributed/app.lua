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
local function installStartup()
  local existing={}
  for _,path in ipairs({'/startup','/startup.lua'}) do
    if fs.exists(path) then existing[#existing+1]=path end
  end
  if #existing>0 then
    print('Existing startup: '..table.concat(existing,', '))
    print('Autostart needs to replace this. The original files will be backed up, not run alongside this controller.')
    local answer=prompt('Back up existing startup and enable transformer autostart? yes/no','yes')
    if answer:lower()~='yes' then print('Startup left unchanged. Start this role manually.'); return end
  end
  local program=shell.getRunningProgram()
  local working=shell.dir()
  -- Use the stable launcher, so approved updates still take effect after boot.
  local body='-- Distributed transformer autostart\n'..
    'shell.setDir('..string.format('%q',working)..')\n'..
    'shell.run('..string.format('%q','/'..program:gsub('^/',''))..', "run")\n'
  local f=assert(fs.open('/transformer-startup.tmp','w')); f.write(body); f.close()
  if #existing>0 then
    local index=1
    while fs.exists('/transformer-startup-backup-'..index) do index=index+1 end
    local backup='/transformer-startup-backup-'..index; fs.makeDir(backup)
    for _,path in ipairs(existing) do fs.move(path,fs.combine(backup,fs.getName(path))) end
    print('Previous startup saved in '..backup)
  end
  fs.move('/transformer-startup.tmp','/startup.lua')
  if settings then settings.set('shell.allow_startup',true); settings.save() end
  print('Autostart enabled: '..node.role..'. Previously running workers restart through the normal safety checks.')
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
    local saved=node and node.config and node.config.settings or legacy
    local settings={target=2640,stepUp=2.5,entryRatio=1,
      inputGauge='',outputGauge='',sourceGauge='',preStepUpGauge='',
      sourceCurrentGauge='',sourcePowerGauge='',sourceCurrentTripAmps=0,
      inputBreakers={},plusBreaker='',minusBreaker='',
      gearA='',gearB='',gearC='',variacsA={},variacsB={},variacsC={},
      travelDegrees=315,accuracyVolts=0.1,fallbackVolts=1,moveTimeout=30,chargeTimeout=60,
      positionToleranceDegrees=1,maxInputVolts=2800,outputTripPercent=10,
      thermalMaxAgeSeconds=1,thermalGraceSeconds=5,thermalCoolSeconds=5,
      rampVoltsPerSecond=1,maxRampStepVolts=1,pollSeconds=0.1,settleSeconds=0.2}
    for key,value in pairs(saved or {}) do settings[key]=U.copy(value) end
    print(saved and 'Using saved settings as defaults.' or 'New installation: assign components and review operating settings.')
    for _,key in ipairs({'A','B','C'}) do if #settings['variacs'..key]==0 and settings['variac'..key] then settings['variacs'..key]={settings['variac'..key]} end end
    settings.inputBreakers=settings.inputBreakers or {}
    settings.entryRatio=settings.entryRatio or 1; settings.sourceGauge=settings.sourceGauge or ''; settings.preStepUpGauge=settings.preStepUpGauge or ''
    settings.sourceCurrentGauge=settings.sourceCurrentGauge or ''; settings.sourcePowerGauge=settings.sourcePowerGauge or ''; settings.sourceCurrentTripAmps=settings.sourceCurrentTripAmps or 0
    settings.thermalMaxAgeSeconds=settings.thermalMaxAgeSeconds or 1; settings.thermalGraceSeconds=settings.thermalGraceSeconds or 5; settings.thermalCoolSeconds=settings.thermalCoolSeconds or 5
    local config={schema=1,cluster=cluster,revision=node and node.config.revision+1 or 1,settings=settings,
      ids={master=os.getComputerID(),regulation=discover('regulation'),protection=discover('protection')}}
    print('Power flow (generator to load):')
    print('Source -> entry transformer -> stages A/B/C')
    print('       -> exit transformer -> output breakers -> load')
    print('Use the exact peripheral names listed below.')
    print('Enter keeps the default; - clears an optional gauge.')
    print('Detected peripherals:'); for _,name in ipairs(peripheral.getNames()) do print(' '..name..' ['..tostring(peripheral.getType(name))..']') end
    for _,key in ipairs({'inputGauge','outputGauge','sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge','plusBreaker','minusBreaker','inputBreakers','gearA','variacsA','gearB','variacsB','gearC','variacsC'}) do
      local old=settings[key]; local list=type(old)=='table'
      local field=assert(U.fields[key],'Missing setup description')
      print(''); print(field.help)
      local value=prompt(field.label,list and table.concat(old,',') or old)
      if list then local names={}; for name in value:gmatch('[^,%s]+') do names[#names+1]=name end; settings[key]=names else settings[key]=value=='-' and '' or value end
    end
    print('Operating settings (Enter keeps the shown value):')
    for _,key in ipairs(U.editable) do
      if type(settings[key])=='number' then
        local field=assert(U.fields[key],'Missing setup description')
        print(''); print(field.help)
        settings[key]=prompt(field.label,settings[key],tonumber)
      end
    end
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
  installStartup()
  print('Saved '..role..'; run transformer.lua run. The old regulator must remain stopped.')
end
if command=='configure' then configure(); return end
assert(node,'Run transformer.lua configure master|regulation|protection first')
U.validate(node.config); assert(node.config.ids[node.role]==os.getComputerID(),'Configuration belongs to another computer')
if node.role~='master' or command=='trip' then
  local isolated,reason=U.openAll(node.config.settings); assert(isolated,reason)
end
if command=='trip' then
  local saved=U.read('distributed-state.json')
  if saved then saved.runRequested=false; saved.latched=true; U.write('distributed-state.json',saved) end
  print('All configured breakers verified open; automatic restart disabled.'); return
end
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
