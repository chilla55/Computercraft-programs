local Core=dofile('Powerplant/controller/controller_core.lua')
local UI=dofile('Powerplant/controller/controller_ui.lua')
local checks=0
local function check(v,m) assert(v,m); checks=checks+1 end
local function config()
  return {version=1,monitor='monitor',modem='back',voltageGauge='volts',currentGauge='',
    nominalVoltage=2640,gridMinVoltage=2376,gridMaxVoltage=2904,currentLimitAmps=0,
    sampleMaxAgeMs=1000,nodeTimeoutMs=2000,upstreamId=-1,
    transmission={inputGauge='',outputGauge='',ratio=0},
    transformers={{id=7,name='Unit A'},{id=8,name='Unit B'}},generators={{id=12,name='Generator'}}}
end
local function fixture(c)
  local sent={}
  local p=Core.new(c or config(),1,'master-session',function(id,m,protocol) sent[#sent+1]={id=id,m=m,protocol=protocol}; return true end)
  return p,sent
end
local function status(id,time,seq,extra)
  local m={schema=1,type='status',node=id,session='session-'..id,sentAt=time,lastSeq=seq or -1,
    phase='standby',nominalTarget=2640,enabled=false,breakers={{closed=false},{closed=false}},stages={},thermal={enabled=false}}
  for k,v in pairs(extra or {}) do m[k]=v end; return m
end
local function receive(p,m,time) return p.receive(m.node,m,Core.REGULATOR,time or m.sentAt) end
local p,sent=fixture(); p.measure(2640,nil,1000)
check(not p.action(7,'enable',1000),'unknown-session transformer enabled')
check(receive(p,status(7,1000,25)),'valid status rejected')
p.tick(1000)
check(sent[1].m.seq==26 and sent[1].m.enabled==false,'restart did not continue sequence disabled')
check(p.action(7,'enable',1000),'healthy unit could not enable'); p.tick(1001)
check(sent[#sent].m.enabled and sent[#sent].m.grid.sampledAt==1000,'dispatch lost actual sample timestamp')
check(p.snapshot(1001).transformers[1].status.breakers[1].closed==false,'intent invented closed breaker')
-- ACK records acceptance only.
receive(p,{schema=1,type='ack',node=7,session='session-7',sentAt=1001,seq=27,accepted=true})
check(p.snapshot(1001).transformers[1].status.breakers[1].closed==false,'ACK treated as contact confirmation')
-- Grid loss clears intent, and return of voltage never reconnects automatically.
p.measure(nil,nil,1250); p.tick(1250)
check(not sent[#sent].m.enabled,'grid failure did not disable')
p.measure(2640,nil,1500); p.tick(1500)
check(not sent[#sent].m.enabled,'grid recovery automatically re-enabled')
check(p.action(7,'enable',1500),'manual reconnect failed'); p.tick(2501)
check(not p.snapshot(2501).transformers[1].desired,'stale grid allowed connection')
-- Node loss also latches intent off independently of good voltage.
p.measure(2640,nil,3001); p.tick(3001)
check(not p.action(7,'enable',3001),'offline node enabled')
-- Session replacement disables; retired sessions and stale packets cannot roll it back.
check(receive(p,status(7,3100,0,{session='new-session'})),'new session rejected')
check(not receive(p,status(7,3200,50)),'retired session revived')
check(not receive(p,status(7,3000,1,{session='new-session'}),3200),'out-of-order status accepted')
check(not p.receive(99,status(7,3300),Core.REGULATOR,3300),'spoofed node ID accepted')
check(not receive(p,status(8,9000),3300),'future timestamp accepted')
-- Reset requires a status acknowledging disable AND both physically open poles.
p,sent=fixture(); p.measure(2640,nil,0)
receive(p,status(7,0,-1,{enabled=true,phase='fault',fault='hot',breakers={{closed=true},{closed=true}}}))
check(p.action(7,'reset',10),'reset request refused')
local disableSeq=sent[#sent].m.seq
p.tick(20); check(sent[#sent].m.type=='dispatch','reset sent before open feedback')
receive(p,status(7,30,disableSeq,{phase='fault',fault='hot',breakers={{closed=false},{closed=true}}}))
p.tick(30); check(sent[#sent-1].m.type~='reset','one open pole allowed reset')
receive(p,status(7,40,disableSeq,{phase='fault',fault='hot'})); p.tick(40)
local reset=sent[#sent-1].m
check(reset.type=='reset' and sent[#sent].m.enabled==false,'reset handshake missing')
receive(p,{schema=1,type='ack',node=7,session='session-7',sentAt=41,seq=reset.seq,accepted=true})
check(p.snapshot(41).transformers[1].resetPending,'ACK prematurely completed reset')
receive(p,status(7,50,reset.seq))
check(not p.snapshot(50).transformers[1].resetPending and not p.snapshot(50).transformers[1].desired,'reset completion re-enabled')
-- Rejected thermal reset remains disabled with its reason.
p.action(7,'reset',60); disableSeq=sent[#sent].m.seq; receive(p,status(7,70,disableSeq)); p.tick(70); reset=sent[#sent-1].m
receive(p,{schema=1,type='ack',node=7,session='session-7',sentAt=71,seq=reset.seq,accepted=false,reason='Still hot'})
check(p.snapshot(71).transformers[1].notice:find('Still hot') and not p.snapshot(71).transformers[1].resetPending,'reset rejection hidden')
-- Fault events inhibit enable even before periodic fault status arrives.
receive(p,{schema=1,type='fault',node=7,session='session-7',sentAt=80,reason='stuck'})
check(not p.action(7,'enable',80),'fault/status race permitted enable')
-- Current readings optional unless a configured limit requires them.
local c=config(); c.currentGauge='amps'; p=fixture(c); p.measure(2640,nil,0)
check(p.health(0).healthy,'optional current failure stopped regulation')
c.currentLimitAmps=20; p=fixture(c)
p.measure(2640,-20,0); check(p.health(0).healthy,'current boundary/sign wrong')
p.measure(2640,-20.1,1); check(not p.health(1).healthy,'reverse overcurrent ignored')
p.measure(2640,nil,2); check(not p.health(2).healthy,'required current failure ignored')
-- Future generator telemetry is named, validated and only paired when fresh.
p=fixture(); local m={schema=1,type='generator_status',node=12,sentAt=1000,sampledAt=1000,voltage=7200,current=-12}
check(p.receive(12,m,Core.NETWORK,1000),'generator telemetry rejected')
local g=p.snapshot(1000).generators[1]
check(g.available and g.measurements[1]==7200 and g.measurements[2]==-12,'voltage/current pair lost units or sign')
check(not p.receive(12,m,Core.NETWORK,1001),'duplicate generator packet accepted')
check(not p.snapshot(2001).generators[1].available,'stale generator shown live')
m.sentAt=1100; m.current=0/0; check(not p.receive(12,m,Core.NETWORK,1100),'NaN generator current accepted')
-- Configuration catches limits without meters and duplicate remote IDs.
c=config(); c.currentLimitAmps=10; check(not pcall(Core.validate,c),'unmeasurable current limit accepted')
c=config(); c.generators[1].id=7; check(not pcall(Core.validate,c),'conflicting node roles accepted')
-- UI shows measured contacts, missing readings, actionable controls and pagination.
local lines,cursor={},1
local screen={getSize=function() return 60,24 end,setCursorPos=function(x,y) cursor=y end,
 setBackgroundColor=function() end,setTextColor=function() end,clear=function() lines={} end,
 write=function(s) lines[cursor]=(lines[cursor] or '')..s end}
local palette={black=1,white=2,gray=3,cyan=4,lime=5,red=6,orange=7,lightGray=8,yellow=9,green=10}
local ui=UI.new(screen,palette); p=fixture(); p.measure(2640,nil,0); receive(p,status(7,0)); ui.draw(p.snapshot(0))
check(lines[2]:find('Draw %-%-'),'missing current displayed as zero')
check(lines[13]:find('OPEN'),'breaker feedback missing')
local action,id=ui.touch(2,22); check(action=='enable' and id==7,'enable touch mapping wrong')
action=ui.touch(40,24); check(action=='stop','global disable touch missing')
ui.page='generators'; ui.draw(p.snapshot(0)); check(lines[7]:find('OFFLINE'),'unavailable generator omitted')

-- Transmission high voltage is an independent diagnostic bus, never join feedback.
c=config(); c.transmission={inputGauge='tx_in',outputGauge='tx_out',ratio=10}; p=fixture(c)
p.measure(2640,nil,1000); p.measureTransmission(2640,26400,1000)
local snapshot=p.snapshot(1000)
check(snapshot.grid.voltage==2640 and snapshot.grid.healthy and snapshot.transmission.measuredRatio==10,'transmission voltage contaminated local bus')
check(snapshot.transmission.expectedOutputVoltage==26400,'transmission ratio semantics wrong')
p.measureTransmission(nil,nil,1100); check(p.health(1100).healthy,'diagnostic transmission gauge failure inhibited local grid')
-- Positional generator [voltage,current] payloads have the same validated envelope.
p=fixture(); m={schema=1,type='generator_status',node=12,sentAt=1000,sampledAt=1000,measurements={7200,5}}
check(p.receive(12,m,Core.NETWORK,1000) and p.snapshot(1000).generators[1].current==5,'paired generator readings rejected')
m.sentAt=1100; m.voltage=8000
check(not p.receive(12,m,Core.NETWORK,1100),'conflicting named/pair telemetry accepted')

-- Preserve the regulator's explicit bounded bank recovery, but never a latched fault.
p=fixture(); p.measure(2640,nil,1000); receive(p,status(7,1000)); p.action(7,'enable',1000)
receive(p,{schema=1,type='fault',node=7,session='session-7',sentAt=1010,reason='bank sync',recoverable=true})
p.tick(1010); check(p.snapshot(1010).transformers[1].desired,'recoverable bank sync lost enable intent')
receive(p,{schema=1,type='fault',node=7,session='session-7',sentAt=1020,reason='stuck',recoverable=false})
check(not p.snapshot(1020).transformers[1].desired,'failed bank recovery remained enabled')

-- Three roles dispatch their own output bus voltage; one stale bus does not affect another.
c=config(); c.buses={{id='consumer',name='Consumer',voltageGauge='consumer_v',currentGauge='',nominalVoltage=240,gridMinVoltage=216,gridMaxVoltage=264,currentLimitAmps=0},
 {id='line',name='Transmission',voltageGauge='line_v',currentGauge='',nominalVoltage=26400,gridMinVoltage=23760,gridMaxVoltage=29040,currentLimitAmps=0}}
c.transformers={{id=7,name='Generator',role='generator',bus='local',generatorId=12},
 {id=8,name='Consumer',role='consumer',bus='consumer'},{id=9,name='Line',role='transmission',bus='line'}}
p,sent=fixture(c); p.measure(2640,nil,1000); p.measureBus('consumer',240,nil,1000); p.measureBus('line',26400,nil,1000)
for _,id in ipairs({7,8,9}) do receive(p,status(id,1000,-1,{nominalTarget=id==8 and 240 or id==9 and 26400 or 2640})); check(p.action(id,'enable',1000),'role failed enable') end
p.tick(1000)
check(sent[1].m.grid.voltage==2640 and sent[2].m.grid.voltage==240 and sent[3].m.grid.voltage==26400,'crossed voltage domains')
p.measure(2640,nil,2001); p.measureBus('line',26400,nil,2001); p.tick(2001)
check(p.snapshot(2001).transformers[1].desired and not p.snapshot(2001).transformers[2].desired and p.snapshot(2001).transformers[3].desired,'bus fault was not isolated')
-- Dead-start supply is exclusive, explicit at both ends, and based on a real zero reading.
c.transformers[2].connectionMode='supply'; p,sent=fixture(c); p.measureBus('consumer',0,nil,1000)
receive(p,status(8,1000)); check(not p.action(8,'enable',1000),'supply activated without regulator permission')
receive(p,status(8,1001,-1,{connectionMode='supply',deadBusVolts=5,nominalTarget=240})); check(p.action(8,'enable',1001),'explicit dead-start refused')
p.tick(1001); check(sent[#sent].m.grid.voltage==0 and sent[#sent].m.grid.healthy,'dead bus replaced by invented nominal reading')
p.measureBus('consumer',nil,nil,1100); p.tick(1100); check(not p.snapshot(1100).transformers[2].desired,'missing gauge mistaken for dead circuit')
c.transformers[3].bus='consumer'; check(not pcall(Core.validate,c),'multiple owners of supply bus accepted')
-- Power reports retain maximum and actual watts independently of V*I.
c=config(); c.upstreamId=20; c.transformers[1].generatorId=12; p,sent=fixture(c)
m={schema=1,type='generator_status',node=12,sentAt=1000,sampledAt=1000,voltage=7200,current=8,maxPowerWatts=100000,currentPowerWatts=56000,
 controlSession='gen-session',lastCommandSeq=-1,supportedCommands={start=true,stop=true},running=true}
check(p.receive(12,m,Core.NETWORK,1000),'power/capability telemetry rejected')
check(p.snapshot(1000).generators[1].powerAvailable and p.snapshot(1000).generators[1].currentPowerWatts==56000,'watts replaced by estimated V*I')
m.sentAt=1001; m.maxPowerWatts=0/0; check(not p.receive(12,m,Core.NETWORK,1001),'invalid maximum power accepted')
local function upstream(kind,seq,extra,time)
 local request={schema=1,node=20,type=kind,session='master-session',seq=seq,sentAt=time or 1100}
 for k,v in pairs(extra or {}) do request[k]=v end
 return p.receive(20,request,Core.NETWORK,time or 1100)
end
p.measure(2640,nil,1000)
local cap={enabled=true,minTarget=2600,maxTarget=2680,targetToleranceVolts=1}
receive(p,status(7,1000,0,{phase='live',remoteControl=cap})); p.action(7,'enable',1000)
check(upstream('shutdown_prepare',1,{generator=12,eventId='shutdown-1',expiresAt=2000,targets={{node=7,voltage=2630}}}),'valid upstream preparation rejected')
p.tick(1100); check(sent[#sent].m.transition.targetVolts==2630 and sent[#sent].m.enabled,'temporary target not dispatched')
check(not upstream('shutdown_prepare',1,{generator=12,eventId='shutdown-1',expiresAt=2000,targets={{node=7,voltage=2630}}}),'replayed preparation accepted')
check(not upstream('shutdown_prepare',2,{generator=12,eventId='shutdown-2',expiresAt=2000,targets={{node=7,voltage=2700}}}),'out-of-bounds voltage permitted')
check(not upstream('shutdown_prepare',3,{generator=12,eventId='shutdown-1',expiresAt=2000,targets={{node=7,voltage=2640},{node=99,voltage=100}}}),'partial invalid target batch accepted')
check(p.snapshot(1100).transformers[1].transition.targetVolts==2630,'failed batch changed prior transition')
check(not p.snapshot(1100).transformers[1].transitionAtTarget,'acceptance mistaken for achieved voltage')
receive(p,status(7,1200,5,{phase='live',enabled=true,remoteControl=cap,currentTarget=2630,outputVoltage=2630,
 transition={id='shutdown-1'},breakers={{closed=true},{closed=true}}}))
check(p.snapshot(1200).transformers[1].transitionAtTarget,'actual target confirmation missing')
check(not upstream('generator_command',4,{generator=12,command='stop'},1200),'generator stop accepted before isolation')
check(upstream('generator_isolate',5,{generator=12},1200),'generator isolation request rejected')
check(not upstream('generator_command',6,{generator=12,command='stop'},1201),'cached pre-disable status permitted generator stop')
receive(p,status(7,1250,10)); check(upstream('generator_command',6,{generator=12,command='stop'},1250),'isolated generator stop rejected')
local command=sent[#sent-1]
check(command.id==12 and command.m.type=='generator_command' and command.m.command=='stop' and command.m.session=='gen-session','generator command routing wrong')
check(p.snapshot(1250).generators[1].commandPending~=nil,'send incorrectly meant stopped')
check(p.receive(12,{schema=1,type='generator_ack',node=12,session='gen-session',sentAt=1251,seq=command.m.seq,accepted=true},Core.NETWORK,1251),'generator ACK rejected')
check(p.snapshot(1251).generators[1].commandPending~=nil,'generator ACK incorrectly meant stopped')

-- Only actual post-command generator feedback completes a forwarded stop.
m={schema=1,type='generator_status',node=12,sentAt=1300,sampledAt=1300,voltage=0,current=0,maxPowerWatts=100000,currentPowerWatts=0,
 controlSession='gen-session',lastCommandSeq=command.m.seq,supportedCommands={start=true,stop=true},running=false}
check(p.receive(12,m,Core.NETWORK,1300) and not p.snapshot(1300).generators[1].commandPending,'actual stopped feedback did not complete request')
check(not p.snapshot(2301).generators[1].powerAvailable,'stale power used as available capacity')
-- An upstream session mismatch cannot mutate a transformer plan.
check(not upstream('shutdown_cancel',7,{session='old-master-session',eventId='shutdown-1'},1300),'old master session accepted')
-- Expiring a plan clears only the override, not the configured nominal or desired connection.
c=config(); c.upstreamId=20; p=fixture(c); p.measure(2640,nil,0)
receive(p,status(7,0,0,{phase='live',remoteControl=cap})); p.action(7,'enable',0)
local request={schema=1,type='shutdown_prepare',node=20,session='master-session',seq=1,sentAt=0,
 generator=12,eventId='short',expiresAt=500,targets={{node=7,voltage=2630}}}
check(p.receive(20,request,Core.NETWORK,0),'short preparation rejected'); p.tick(500)
check(not p.snapshot(500).transformers[1].transition and p.snapshot(500).transformers[1].desired,'expiry changed operator connection intent')

-- Optional adjustments are scoped to connection/disconnection events; never a permanent nominal setting.
request.seq=2; request.type='generator_transition'; request.direction='connect'; request.expiresAt=1000
check(p.receive(20,request,Core.NETWORK,0),'generator connection preparation rejected')
check(p.snapshot(0).transformers[1].transition.direction=='connect','connection intent lost')
request.seq=3; request.direction='normal_operation'
check(not p.receive(20,request,Core.NETWORK,0),'non-event voltage adjustment accepted')
print(('PASS: %d plant controller checks'):format(checks))
