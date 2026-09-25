local root,command,requestedRole,launchContext=...
-- Older stable launchers may load this chunk into the global environment,
-- where CraftOS does not provide the per-program shell API.
local installRoot=root:match('^(.*)/releases/distributed%-%d+%.%d+%.%d+$') or
  (root:match('^releases/distributed%-%d+%.%d+%.%d+$') and '') or root
local launcher=launchContext and launchContext.launcher or
  (shell and shell.getRunningProgram()) or fs.combine(installRoot,'transformer.lua')
local workingDirectory=launchContext and launchContext.working or (shell and shell.dir()) or ''
local function module(name) return assert(loadfile(fs.combine(root,name..'.lua'),'t',_ENV))() end
local U=module('common')
local D=module('discovery')
local node=U.read('distributed-node.json')
local function prompt(label,default,parse)
  while true do
    write(label..' ['..tostring(default or '')..']: ')
    local value=read():match('^%s*(.-)%s*$')
    if not parse then return value=='' and default or value end
    local candidate=value=='' and tostring(default or '') or value
    if label:find('(%)',1,true) then candidate=candidate:gsub('%%$',''):match('^%s*(.-)%s*$') end
    local parsed=parse(candidate)
    if parsed~=nil and (type(parsed)~='number' or U.finite(parsed)) then return parsed end
    print('Please enter a number. Press Enter to keep the shown default.')
  end
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
  local program=launcher
  local working=workingDirectory
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
  if role=='master' then uplink=prompt('Optional plant uplink modem, wired or ender (- for none)',node and node.uplinkModem or wireless[1] or '-'); if uplink=='-' then uplink=nil end end
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
    print('This transformer needs two worker computers:')
    print('REGULATION: moves the variacs; can open breakers.')
    print('PROTECTION: reads temperatures and is the only role allowed to close breakers.')
    print('Connect both to the same wired modem network.')
    print('On the regulation computer run:')
    print(launcher..' configure regulation')
    print('On the protection computer run:')
    print(launcher..' configure protection')
    print('Select cluster '..cluster..' on both. Computer IDs are discovered automatically.')
    print('Workers wait for configuration until this master finishes setup and starts running.')
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
if command=='startup' then installStartup(); return end
if node.role~='master' or command=='trip' then
  local isolated,reason=U.openAll(node.config.settings); assert(isolated,reason)
end
if command=='trip' then
  local saved=U.read('distributed-state.json')
  if saved then saved.runRequested=false; saved.realignRequested=false; saved.latched=true; U.write('distributed-state.json',saved) end
  print('All configured breakers verified open; automatic restart disabled.'); return
end
D.open(node.modem); D.host(node.config.cluster or 'transformer',node.role)
assert(command==nil or command=='run' or command=='diagnose','Use configure, run, diagnose, trip or rollback')
local modules={common=U,thermal=module('thermal_protection'),planner=module('planner'),hash=module('sha256'),ui=module('ui'),updater=module('updater')}
local R=module('runtime').new(node.config,node,modules,fs.getDir(launcher))
if command=='diagnose' then
  assert(node.role=='master','Launch diagnostics on the master')
  local gauge=requestedRole or node.config.settings.preStepUpGauge
  assert(gauge and gauge~='','Configure Voltage before exit transformer, or run diagnose <gauge peripheral name>')
  U.voltage(gauge) -- Validate the extra read-only measurement before arming.
  local report={schema=1,complete=false,samples={}}
  local function test()
    assert(U.isolated(node.config.settings) and U.idle(node.config.settings),'Enter maintenance before starting this test')
    local deadline=R.now()+10000
    repeat sleep(.1) until (R.fresh('protection') and R.fresh('regulation')) or R.now()>deadline
    assert(R.fresh('protection') and R.fresh('regulation'),'Both updated workers must be running')
    assert(R.fresh('protection').latched and R.fresh('regulation').latched,'Both workers must be in maintenance')
    R.state.diagnosticRequest=R.token()
    sleep(.5) -- Advertise the test lease before protection arms.
    R.send('protection','diagnose',{id=R.state.diagnosticRequest,gauge=gauge})
    print('Testing C only. Outputs remain open. Ctrl+T aborts and opens all breakers.')
    local finish=R.now()+(node.config.settings.chargeTimeout+5*node.config.settings.moveTimeout+60)*1000
    local seen=false; local printed=0
    repeat
      local peer=R.fresh('regulation')
      if peer and peer.diagnosticReport and peer.diagnosticReport.id==R.state.diagnosticRequest then
        seen=true; report=U.copy(peer.diagnosticReport)
        for i=printed+1,#report.samples do
          local v=report.samples[i]
          print(('%s: in %.2f / before exit %.2f / out %.2f V'):format(v.label,v.input,v.preExit,v.output))
        end
        printed=#report.samples
        if report.complete and peer.latched then return end
        assert(not peer.latched or (report.finishing and not peer.fault),peer.fault or 'Diagnostic stopped')
      end
      assert(R.now()<finish,'Diagnostic timed out: '..tostring(R.state.message))
      if not seen and R.now()>deadline+5000 then error('Diagnostic not started: '..tostring(R.state.message)) end
      sleep(.1)
    until false
  end
  local ok,why=pcall(function() parallel.waitForAny(test,R.receive,R.heartbeat,R.watchdog) end)
  -- Opening must precede report writes, including termination and lost workers.
  local stopped,stopReason=pcall(R.trip,ok and 'operator_stop' or 'diagnostic_aborted',ok and 'Diagnostic finished' or 'Diagnostic aborted: '..tostring(why))
  if not ok then report.complete=false; report.error=tostring(why) end
  U.write('/config/transformer-diagnostic.json',report)
  print(ok and 'Diagnostic complete.' or tostring(why))
  print('Report: /config/transformer-diagnostic.json')
  if not stopped then error(stopReason,0) end
  return
end
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
