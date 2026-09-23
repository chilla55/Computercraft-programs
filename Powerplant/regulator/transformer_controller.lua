-- v10: master-aware three series variacs, preferred +/-0.1 V, fallback +/-1 V.
-- Managed join: match grid -> close -> hold positions until settled -> ramp to
-- the configured nominal target. Natural sharing remains the electrical model.
-- Concurrent cooperative tasks: controller, protection, rednet RX, telemetry, keyboard.
-- Standalone is retained with masterId=-1. Run "protocol" for the wire format.
-- Master OFF disconnects output; no generator engine/excitation actuator exists here.
-- Nominal initial preset searches all whole-degree combinations while disconnected.
-- Feedback: direct calculated coarse destinations across the full travel outside +/-2%.
-- Same-direction movements start together; fine corrections normally use 1 degree.
-- A 16-degree coordinated search may rebalance stages if fine control is stuck.
-- Recovery uses fresh, stable open-circuit feedback, never a latched trip-spike gain.
-- Fine accuracy depends on shaft resolution and source/load stability.
-- Initial close plus at most THREE retries per program run. No retry-counter
-- reset on brief success. Other faults and user stops remain latched open.
-- Wiring: gauge 6 -> variac 1 -> variac 2 -> variac 4 -> fixed step-up -> breakers -> network.
-- Gauge 7 measures final voltage across plus/minus AFTER the fixed step-up.
-- Gauge 7 MUST be on the TRANSFORMER side of BOTH breakers, so actual output
-- can be brought into the target band and verified BEFORE every close.
-- Gauge 6 measures the generator directly, before all three variacs.
-- Run: configure | status | run [target V/kV] [tolerance %] | sync
-- No arguments: configuration on first use, otherwise run saved configuration.
-- Every run checks direction with a small movement; no homing is performed.
-- Directions are kept in RAM and checked again on every restart. sync aliases run.
-- All three gearshifts must control independent shafts, with no other active controller.
-- Breakers isolate the LOAD, not the variacs' input. They cannot prevent
-- no-load overheating caused by excessive generator voltage.
-- CC programs cannot provide protection while the computer/chunks are unloaded.

-- Fit from the supplied 316-point, 100 V calibration (0..315 shaft degrees).
-- File zero = maximum output; arm position zero = minimum output.
-- No-load voltage fit is a predictor, not a loaded-voltage guarantee.
local CAL_MIN = 0.00999996389330349
local CAL_SPAN = 0.989990071137444
local function calibratedRatio(position) return CAL_MIN + CAL_SPAN*position end

local args = {...}
local PROTOCOL_HELP = [=[
POWER PLANT REGULATOR PROTOCOL v1
Protocol string: powerplant.regulator.v1

SETUP
Run configure. Keep nominal target 2640. Set masterId to your master computer's
ID and modem to back (or its actual name). masterId=-1 retains standalone mode.
Gauge 7 stays after step-up and BEFORE breakers. The master needs an independent
live GRID-side reading while this unit is disconnected. Do not use this unit's
isolated output as the grid reading. This protocol is for the user's DC network.

Each boot emits status every 0.5 s to the configured master. Read its node and
session fields first. Send a fresh dispatch approximately every 0.5 s. The
master must use increasing integer seq values for this session. On master reboot,
read lastSeq from status and resume above it. On node reboot use its NEW session.
All timestamps are os.epoch('utc') milliseconds. Grid samples expire after 2 s;
dispatch lease expires after 3 s. send success is NOT breaker-close confirmation.
Only status.breakers[1/2].closed reports actual contacts.

MASTER -> UNIT: enable/heartbeat (Lua table)
{
 schema=1, type='dispatch', node=NODE_ID, session=SESSION_FROM_STATUS,
 seq=NEXT_SEQUENCE, sentAt=os.epoch('utc'), enabled=true,
 grid={voltage=MEASURED_GRID_VOLTS, healthy=GRID_HEALTH_BOOLEAN,
       sampledAt=ACTUAL_GRID_SAMPLE_TIMESTAMP}
}
No runningTarget: nominal target is locally configured and remains 2640 V.
A healthy live grid within the configured nominal range is required to join.
A dead grid is not automatically black-started by managed mode.

JOIN BEHAVIOUR
1. Open both breakers and verify isolation.
2. Detect shaft directions once per controller boot, without homing.
3. Match the current grid reading, normally within 1 V, and recheck immediately
   before each pole closes. The two contacts are sequential, not an atomic pair.
4. Hold positions while natural sharing settles. Default: voltage changes <=1 V
   and current changes <=0.25 A between samples for 3 s, with a 30 s timeout.
5. Ramp the REGULATION SETPOINT toward the configured 2640 V at up to 1 V/s,
   at most 1 V per update, waiting for the output to catch up. Actual shaft steps
   and bus voltage are discrete and are not guaranteed to obey that slew rate.
6. Continue normal regulation at nominal voltage. No separate current-sharing
   controller or remote nominal-voltage override is used.

MASTER -> UNIT: disable (repeat if ACK is not received)
{schema=1,type='dispatch',node=NODE_ID,session=SESSION,seq=N,
 sentAt=os.epoch('utc'),enabled=false}
This opens both contacts and leaves the node online in standby. It does NOT
stop the generator shaft or excitation. No such actuator is configured.

FAULT RESET
Send disable first. Then:
{schema=1,type='reset',node=NODE_ID,session=SESSION,seq=N,
 sentAt=os.epoch('utc')}
Wait for standby with fault absent, THEN send fresh enable dispatches. Reset
acceptance alone does not mean completed. Hardware faults stay latched even if
normal enable heartbeats continue. Overvoltage/close failures retain at most 3
retries per run/reset. Stale/unhealthy master data opens and waits for fresh
healthy enable dispatches. No hardware fault can be bypassed by a master command.

STATUS REQUEST (does not renew enable lease)
{schema=1,type='get_status',node=NODE_ID,session=SESSION,seq=N,
 sentAt=os.epoch('utc')}
Periodic status supplies the response; ack only acknowledges the request.

UNIT -> MASTER
Every message: schema=1, node, session, sentAt.
ack: seq, accepted, optional reason; acceptance means recorded intent only.
status: phase, nominalTarget, target (temporary active setpoint), enabled, fault,
 retries, minimumGeneratorVolts, inputVoltage, outputVoltage, grid, joinStage,
 variacs[1..3]={position,ratio,shaftSpeed}, breakers[1..2]=native status, lastSeq.
Missing readings are omitted if a peripheral is unavailable; never assume zero.
Breaker 1 is plus; breaker 2 is minus. Current signs follow gauge orientation.
joinStage: standalone, settling, ramping, nominal.
fault/stopped: reason; stopped also includes breakersOpen verification result.

SAFETY / NETWORK NOTES
Disable, stale grid, lost dispatches or unhealthy grid interrupts motor waits
and opens both contacts. An issued gearshift sequence can still finish after
opening. Local overcurrent, overvoltage, input-voltage and position checks remain.
These are cooperative CC tasks, not CPU threads. They yield during motor waits
and long searches. Chunk unloading/computer shutdown still stops the software.
Rednet is unauthenticated. ID/session/sequence checks reject accidental, replayed
or misaddressed traffic but cannot authenticate a malicious sender. Use a trusted
network; no cryptographic security is claimed.
]=]
if args[1]=='protocol' then print(PROTOCOL_HELP); return end
local PATH = 'dual-variac-config.json'
local LOG = 'transformer-controller.log'
local presets = {120,240,480,2400,7200,24000,34500,69000,138000,230000,345000}
local C = {
  version=10, target=2640, thresholdPercent=2, stepUp=2.5,
  accuracyVolts=0.1, fallbackVolts=1, coarseBandPercent=2, maxFineStep=1,
  inputGauge='powergrid_voltage_gauge_6', outputGauge='powergrid_voltage_gauge_7',
  variacA='powergrid:variac_1', gearA='Create_SequencedGearshift_4',
  variacB='powergrid:variac_2', gearB='Create_SequencedGearshift_5',
  variacC='powergrid:variac_4', gearC='Create_SequencedGearshift_6',
  plusBreaker='powergrid:hv_breaker_2', minusBreaker='powergrid:hv_breaker_3',
  travelDegrees=315, maxLiveStep=315, pollSeconds=0.1, settleSeconds=0.2,
  moveTimeout=30, chargeTimeout=60, positionToleranceDegrees=1,
  maxInputVolts=2800, outputTripPercent=10, inputHeadroomVolts=0,
  masterId=-1, modem='back', gridMaxAgeSeconds=2, masterTimeoutSeconds=3,
  telemetrySeconds=0.5, joinToleranceVolts=1, gridDeviationPercent=10,
  joinHoldSeconds=3, gridSettleTimeout=30, rampVoltsPerSecond=1, maxRampStepVolts=1,
  breakerTripAmps=0, -- 0 = PRESERVE both native settings; never disables protection.
}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function round(x) return math.floor(x+0.5) end
local function volts(s)
  local t=tostring(s):lower():gsub('%s','')
  local n=t:match('^([%d%.]+)kv$') or t:match('^([%d%.]+)k$')
  return n and tonumber(n)*1000 or tonumber((t:gsub('v$','')))
end
local exists=fs.exists(PATH)
if exists then
  local f=assert(fs.open(PATH,'r')); local saved=textutils.unserializeJSON(f.readAll()); f.close()
  assert(type(saved)=='table' and (saved.version==7 or saved.version==8 or saved.version==9 or saved.version==10),'Invalid configuration version')
  -- Explicitly migrate old two-stage mappings to the user's new three-stage
  -- installation. Other settings survive; configure writes the v10 mapping.
  local mappings={}
  for _,k in ipairs({'inputGauge','outputGauge','variacA','gearA','variacB','gearB','variacC','gearC','plusBreaker','minusBreaker'}) do mappings[k]=C[k] end
  for k in pairs(C) do if saved[k]~=nil then C[k]=saved[k] end end
  if saved.version==7 then
    for k,v in pairs(mappings) do C[k]=v end
    print('Migrated v7 peripheral mappings to the three-stage installation.')
  end
  if saved.version<9 and (saved.maxLiveStep==nil or saved.maxLiveStep==8) then C.maxLiveStep=315 end
  C.version=10
end
local function validate()
  for k,v in pairs(C) do
    if type(v)=='number' then assert(finite(v),'Invalid '..k) end
  end
  for _,k in ipairs({'target','stepUp','travelDegrees','moveTimeout','chargeTimeout','positionToleranceDegrees','maxInputVolts'}) do
    assert(type(C[k])=='number' and C[k]>0,'Invalid '..k)
  end
  assert(finite(C.masterId) and C.masterId%1==0 and C.masterId>=-1,'Master ID must be -1 or a computer ID')
  assert(type(C.modem)=='string' and #C.modem>0,'Missing modem name')
  assert(C.gridMaxAgeSeconds>=0.1 and C.masterTimeoutSeconds>=C.gridMaxAgeSeconds,'Invalid master freshness deadlines')
  assert(C.telemetrySeconds>=0.1 and C.joinToleranceVolts>0 and C.joinHoldSeconds>=0,'Invalid network limits')
  assert(C.gridSettleTimeout>C.joinHoldSeconds and C.rampVoltsPerSecond>0 and C.maxRampStepVolts>0,'Invalid join/ramp timing')
  assert(C.gridDeviationPercent>0 and C.gridDeviationPercent<100,'Invalid allowed grid deviation')
  assert(finite(C.inputHeadroomVolts) and C.inputHeadroomVolts>=0,'Input headroom must be nonnegative volts')
  assert(C.thresholdPercent>0 and C.thresholdPercent<20,'Tolerance must be between 0 and 20 percent')
  assert(finite(C.accuracyVolts) and C.accuracyVolts>0,'Accuracy must be positive volts')
  assert(finite(C.fallbackVolts) and C.fallbackVolts>=C.accuracyVolts,'Fallback must be at least preferred accuracy')
  assert(C.target*C.outputTripPercent/100>C.fallbackVolts,'Output trip must exceed fallback tolerance')
  assert(finite(C.coarseBandPercent) and C.coarseBandPercent>0 and C.coarseBandPercent<100,'Invalid coarse band percent')
  assert(C.target*C.coarseBandPercent/100>=C.fallbackVolts,'Coarse band must contain fallback band')
  assert(finite(C.maxFineStep) and C.maxFineStep>=1 and C.maxFineStep%1==0 and C.maxFineStep<=C.maxLiveStep,'Invalid fine step')
  assert(C.maxLiveStep>=1 and C.maxLiveStep<=315 and C.maxLiveStep%1==0,'Live step must be 1..315 whole degrees')
  assert(C.pollSeconds>=0.05 and C.settleSeconds>=0.1,'Polling >=0.05, settling >=0.1 seconds')
  assert(C.breakerTripAmps>=0 and C.breakerTripAmps<=100 and C.breakerTripAmps%1==0,'Breaker setting must be 0..100 whole amps')
  local names={}
  for _,k in ipairs({'inputGauge','outputGauge','variacA','variacB','variacC','gearA','gearB','gearC','plusBreaker','minusBreaker'}) do
    assert(type(C[k])=='string' and #C[k]>0 and not names[C[k]],'Missing or duplicate peripheral: '..k)
    names[C[k]]=true
  end
end
local function prompt(label,key,parse)
  write(label..' ['..tostring(C[key])..']: ')
  local s=read(); if s~='' then C[key]=parse and assert(parse(s),'Invalid '..key) or s end
end
if args[1]=='standards' then
  print('Server voltage presets (V): '..table.concat(presets,', '))
  print('Custom targets such as 2640 are supported.'); return
end
if args[1]=='configure' or (not exists and not args[1]) then
  print('Three variacs followed by a FIXED step-up transformer.')
  print('Gauge 7: AFTER fixed step-up, BEFORE both breakers.')
  prompt('Nominal standalone target V / kV','target',volts)
  prompt('Master computer ID (-1 = standalone)','masterId',tonumber)
  prompt('Rednet modem name','modem')
  prompt('Grid matching tolerance +/- volts','joinToleranceVolts',tonumber)
  prompt('Stable seconds after joining','joinHoldSeconds',tonumber)
  prompt('Return to nominal: volts per second','rampVoltsPerSecond',tonumber)
  prompt('Maximum target change per ramp step (V)','maxRampStepVolts',tonumber)
  prompt('Preferred accuracy +/- VOLTS','accuracyVolts',tonumber)
  prompt('Fallback accuracy +/- VOLTS','fallbackVolts',tonumber)
  prompt('Fixed voltage multiplier (output/input)','stepUp',tonumber)
  for _,k in ipairs({'inputGauge','outputGauge','variacA','gearA','variacB','gearB','variacC','gearC','plusBreaker','minusBreaker'}) do prompt(k,k) end
  prompt('Whole shaft degrees for full arm travel','travelDegrees',tonumber)
  prompt('Coarse travel limit (315 = direct target)','maxLiveStep',tonumber)
  prompt('Switch to fine steps within +/- percent','coarseBandPercent',tonumber)
  prompt('Maximum FINE step in degrees','maxFineStep',tonumber)
  prompt('Maximum tested variac INPUT voltage','maxInputVolts',tonumber)
  prompt('Extra generator voltage above calculated minimum','inputHeadroomVolts',tonumber)
  prompt('Final overvoltage trip above target (%)','outputTripPercent',tonumber)
  prompt('Breaker amps (0 keeps existing settings)','breakerTripAmps',tonumber)
  validate()
  local f=assert(fs.open(PATH..'.tmp','w')); f.write(textutils.serializeJSON(C)); f.close()
  if fs.exists(PATH..'.bak') then fs.delete(PATH..'.bak') end
  if fs.exists(PATH) then fs.move(PATH,PATH..'.bak') end
  fs.move(PATH..'.tmp',PATH)
  print('Saved. Run transformer_controller run'); return
end
local command=args[1] or 'run'
assert(command=='run' or command=='sync' or command=='status','Use configure, standards, status, run, or sync')
if args[2] then C.target=assert(volts(args[2]),'Invalid target') end
if args[3] then
  C.thresholdPercent=assert(tonumber(args[3]),'Invalid tolerance')
  C.accuracyVolts=C.target*C.thresholdPercent/100
  C.fallbackVolts=math.max(C.accuracyVolts,C.fallbackVolts)
end
validate()
local nominalTarget=C.target
local managed=C.masterId>=0
local PROTOCOL='powerplant.regulator.v1'
local net={enabled=false,lastSeen=-math.huge,lastSeq=-1,grid=nil,reset=false}
local nodeId=managed and os.getComputerID() or 0
local session=managed and (tostring(nodeId)..':'..tostring(os.epoch('utc'))..':'..tostring(math.random(1,2147483647))) or 'standalone'
local faultLatched
local joinState={stage='standalone',target=nominalTarget}
local networkOpened=false
local STANDBY_PREFIX='STANDBY: '
local function networkReady()
  if not managed then return true end
  if not net.enabled then return false,'Disabled by master / awaiting dispatch' end
  if os.clock()-net.lastSeen>C.masterTimeoutSeconds then return false,'Master heartbeat expired' end
  local g=net.grid
  if not g or not g.healthy then return false,'Grid not healthy / no grid reading' end
  local age=(os.epoch('utc')-g.sampledAt)/1000
  if age< -0.25 or age>C.gridMaxAgeSeconds then return false,'Grid reading stale' end
  if g.voltage<nominalTarget*(1-C.gridDeviationPercent/100) or g.voltage>nominalTarget*(1+C.gridDeviationPercent/100) then
    return false,'Grid voltage outside allowed nominal range'
  end
  return true
end
local tol=C.accuracyVolts
local fallback=C.fallbackVolts
local coarseBand=C.target*C.coarseBandPercent/100
-- Best no-load ratio with all three stages at maximum. Downstream load losses
-- may require a higher input; optional headroom raises this hard trip threshold.
local minimumGeneratorVolts=C.target/(C.stepUp*calibratedRatio(1)^3)+C.inputHeadroomVolts
assert(minimumGeneratorVolts<C.maxInputVolts,'Target requires input above the configured variac voltage limit')
local function selectTarget(joining)
  local target=nominalTarget
  if managed then
    local ready,reason=networkReady()
    if not ready then error(STANDBY_PREFIX..reason,0) end
    target=joining and net.grid.voltage or joinState.target
  end
  local changed=math.abs(C.target-target)>0.001
  C.target=target
  coarseBand=target*C.coarseBandPercent/100
  minimumGeneratorVolts=target/(C.stepUp*calibratedRatio(1)^3)+C.inputHeadroomVolts
  return changed
end
local minImprovement=math.min(0.001,tol/10)
local gauges,variacs,gears,breakers={},{},{},{}
local directions={}
local phase='setup'
local latest
local retries=0
local RETRY_PREFIX='RETRYABLE: '
local function retryFault(message) error(RETRY_PREFIX..message,0) end
local function log(s)
  local line=('[%.2f] %s'):format(os.clock(),s)
  local f=fs.open(LOG,'a'); if f then f.writeLine(line); f.close() end
end
local function wrap(name,methods)
  local p=assert(peripheral.wrap(name),'Missing peripheral: '..name)
  for _,m in ipairs(methods) do assert(type(p[m])=='function',name..' lacks '..m) end
  return p
end
local function snapshot(i)
  local s=variacs[i].getStatus()
  assert(type(s)=='table' and finite(s.position) and s.position>=0 and s.position<=1,'Invalid variac position')
  assert(finite(s.ratio) and s.ratio>=0.0099 and s.ratio<=1.0001,'Invalid variac ratio')
  assert(math.abs(s.ratio-(0.01+0.99*s.position))<0.001,'Unsupported position/ratio relationship')
  return s
end
local function readV(i)
  local v=gauges[i].voltage(); assert(finite(v),'Invalid voltage gauge reading')
  return math.abs(v)
end
local function breakerState(i)
  local s=breakers[i].getStatus()
  assert(type(s)=='table' and type(s.closed)=='boolean','Invalid breaker status')
  return s
end
local function guard()
  if managed then
    local ready,reason=networkReady()
    if not ready then error(STANDBY_PREFIX..reason,0) end
  end
  local a,b=breakerState(1),breakerState(2)
  if phase=='live' then
    assert(a.closed and b.closed,'Breaker opened; automatic reclose disabled')
    assert(a.currentValid and b.currentValid,'Breaker current reading invalid')
    for _,s in ipairs({a,b}) do
      assert(finite(s.current),'Invalid current')
      if s.tripEnabled and s.tripCurrent>0 then
        assert(math.abs(s.current)<=s.tripCurrent,'Current exceeds native breaker setting')
      end
    end
    local output=readV(2)
    if output>C.target*(1+C.outputTripPercent/100) then
      -- Trip immediately, but never train the model on a fault/transient.
      log(('OVERVOLTAGE input %.3f V; output %.3f V'):format(readV(1),output))
      retryFault(('Final output overvoltage: %.2f V (limit %.2f V)')
        :format(output,C.target*(1+C.outputTripPercent/100)))
    end
  elseif phase=='setup' then
    assert(not a.closed and not b.closed,'Breaker closed during disconnected setup')
  end
  local v=readV(1)
  assert(v>1,'Generator voltage missing')
  assert(v>=minimumGeneratorVolts,
    ('Generator undervoltage: %.3f V < calculated minimum %.3f V for %.3f V target; both breakers will open')
      :format(v,minimumGeneratorVolts,C.target))
  assert(v<=C.maxInputVolts,'Variac input too high; reduce/disconnect generator voltage')
end
local function pause(seconds)
  local finish=os.clock()+seconds
  repeat guard(); sleep(0.05) until os.clock()>=finish
  guard()
end
local function openBoth()
  -- Try both independently, including when the other is missing or errors.
  local errors={}
  for i,name in ipairs({C.plusBreaker,C.minusBreaker}) do
    local ok,err=pcall(function()
      local b=breakers[i] or assert(peripheral.wrap(name),'Missing '..name)
      b.open()
      assert(not b.isClosed(),name..' did not open')
    end)
    if not ok then errors[#errors+1]=tostring(err) end
  end
  if #errors>0 then error(table.concat(errors,'; '),0) end
end
local function idle(i)
  local start=os.clock()
  while gears[i].isRunning() do
    assert(os.clock()-start<C.moveTimeout,'Gearshift timeout: '..i)
    pause(0.05)
  end
  guard()
end
local function settled(i)
  -- Read the physical arm until interpolation has stopped, not merely gear idle.
  local start=os.clock(); local old=snapshot(i).position; local stable=0
  repeat
    pause(0.05)
    local p=snapshot(i).position
    if math.abs(p-old)*C.travelDegrees<0.02 then stable=stable+1 else stable=0 end
    old=p
    assert(os.clock()-start<C.moveTimeout,'Variac arm failed to settle')
  until stable>=4
  return snapshot(i)
end
local function rotateRaw(i,n,modifier)
  idle(i); guard()
  gears[i].rotate(n,modifier)
  pause(0.1); idle(i)
  return settled(i)
end
local function discoverDirection(i)
  local before=snapshot(i).position
  local after=rotateRaw(i,3,1).position
  local delta=after-before; local modifier=1
  if math.abs(delta)*C.travelDegrees<0.2 then
    before=after; modifier=-1
    after=rotateRaw(i,3,-1).position; delta=after-before
  end
  assert(math.abs(delta)*C.travelDegrees>=0.2,'Stage '..i..' did not move; check shaft power')
  directions[i]=delta>0 and modifier or -modifier
  log(('Stage %d: increasing modifier %d'):format(i,directions[i]))
end
local function choose(input,output,live,limitOverride)
  local angles={}
  local product=1
  for i=1,3 do
    local s=snapshot(i)
    angles[i]=s.position*C.travelDegrees
    product=product*calibratedRatio(s.position)
  end
  local basis=output and output/product or input*C.stepUp
  local fine=live and math.abs(output-C.target)<=coarseBand
  local limit=live and (fine and C.maxFineStep or C.maxLiveStep) or math.ceil(C.travelDegrees)
  if limitOverride then limit=limitOverride end
  local lows,highs={},{}
  for i=1,3 do
    lows[i]=math.max(-limit,math.ceil(-angles[i]))
    highs[i]=math.min(limit,math.floor(C.travelDegrees-angles[i]))
  end
  local best
  local planningTolerance=(managed and phase~='live') and math.min(tol,C.joinToleranceVolts) or tol
  local function consider(da,db,dc)
    if dc<lows[3] or dc>highs[3] then return end
    local ra=calibratedRatio((angles[1]+da)/C.travelDegrees)
    local rb=calibratedRatio((angles[2]+db)/C.travelDegrees)
    local rc=calibratedRatio((angles[3]+dc)/C.travelDegrees)
    local predicted=basis*ra*rb*rc
    local err=math.abs(predicted-C.target)
    local travel=math.abs(da)+math.abs(db)+math.abs(dc)
    local inside=err<=planningTolerance*0.5
    local better=not best or (inside and not best.inside)
    if best and inside==best.inside then
      if inside then better=travel<best.travel or (travel==best.travel and err<best.err)
      else better=err<best.err-1e-6 or (math.abs(err-best.err)<1e-6 and travel<best.travel) end
    end
    if better then best={da,db,dc,err=err,travel=travel,predicted=predicted,inside=inside,input=input,output=output,target=C.target} end
  end
  local rows=0
  for da=lows[1],highs[1] do
    local ra=calibratedRatio((angles[1]+da)/C.travelDegrees)
    for db=lows[2],highs[2] do
      if live and fine and not limitOverride then
        for dc=lows[3],highs[3] do consider(da,db,dc) end
      else
        -- For each A/B pair, output increases monotonically with C. Only
        -- adjacent C settings and interval bounds can be nearest the target.
        local rb=calibratedRatio((angles[2]+db)/C.travelDegrees)
        local wanted=(C.target/(basis*ra*rb)-CAL_MIN)*C.travelDegrees/CAL_SPAN-angles[3]
        local dc=round(wanted)
        for offset=-1,1 do consider(da,db,dc+offset) end
        consider(da,db,lows[3]); consider(da,db,highs[3])
      end
    end
    rows=rows+1
    -- Yield during the broad initial search so stop events can be handled.
    if rows%16==0 then pause(0.05) end
  end
  assert(best,'No available three-variac setting')
  return best
end
local function apply(plan)
  if managed then
    local ready,reason=networkReady()
    if not ready then error(STANDBY_PREFIX..reason,0) end
    local wanted=phase=='live' and joinState.target or net.grid.voltage
    if math.abs(wanted-plan.target)>C.joinToleranceVolts then
      log('REPLAN: master/grid target changed'); return false
    end
  end
  if phase=='live' and plan.output then
    local input,output=readV(1),readV(2)
    -- Do not execute a large plan calculated before a source/load change.
    if math.abs(input-plan.input)>math.max(1,plan.input*0.005)
      or math.abs(output-plan.output)>math.max(fallback,plan.output*0.005) then
      log('REPLAN: voltage changed during calculation'); return false
    end
  end
  local function group(sign)
    local pending={}
    for i=1,3 do
      if plan[i]*sign>0 then
        idle(i)
        local p=snapshot(i).position
        pending[#pending+1]={index=i,expected=clamp(p+plan[i]/C.travelDegrees,0,1),last=p,stable=0}
      end
    end
    if #pending==0 then return end
    -- All motors in this group run together. Peripheral calls are sequential,
    -- but we do not wait for one motor's entire movement before starting another.
    for _,m in ipairs(pending) do
      guard()
      local i=m.index
      log(('Stage %d movement %+d degrees (group %s)'):format(i,plan[i],sign<0 and 'lower' or 'raise'))
      gears[i].rotate(math.abs(plan[i]),sign*directions[i])
    end
    local start=os.clock()
    repeat
      pause(0.05)
      local done=true
      for _,m in ipairs(pending) do
        local i=m.index
        local p=snapshot(i).position
        if not gears[i].isRunning() and math.abs(p-m.last)*C.travelDegrees<0.02 then
          m.stable=m.stable+1
        else m.stable=0 end
        m.last=p
        if m.stable<4 or os.clock()-start<0.2 then done=false end
      end
      if done then break end
      assert(os.clock()-start<C.moveTimeout,'Grouped movement timeout; check shafts')
    until false
    for _,m in ipairs(pending) do
      local errorDegrees=math.abs(snapshot(m.index).position-m.expected)*C.travelDegrees
      assert(errorDegrees<=C.positionToleranceDegrees,
        ('Stage %d physical position error %.2f deg; check gearing/travelDegrees'):format(m.index,errorDegrees))
    end
  end
  -- Finish all reductions before starting increases, limiting temporary peaks.
  group(-1); group(1)
  pause(C.settleSeconds)
  return true
end
local lastDisplay=-math.huge
local lastDisplayMessage
local function display(message)
  if message==lastDisplayMessage and os.clock()-lastDisplay<0.5 then return end
  lastDisplay=os.clock(); lastDisplayMessage=message
  term.clear(); term.setCursorPos(1,1)
  print('Three-variac controller v10'); print(message)
  if managed then print(('Master %d | grid %s V'):format(C.masterId,net.grid and ('%.3f'):format(net.grid.voltage) or '--')) end
  if managed then print('Grid join: '..joinState.stage) end
  print(('Recovery attempts used: %d / 3'):format(retries))
  print(('Target %.3f V | preferred +/-%.3f V'):format(C.target,tol))
  print(('Fallback +/-%.3f V | step-up x%.4g'):format(fallback,C.stepUp))
  if latest then print(('Input %.3f V | Final output %.3f V'):format(latest[1],latest[2])) end
  print(('Generator minimum: %.3f V'):format(minimumGeneratorVolts))
  for i=1,3 do
    local s=snapshot(i)
    print(('Variac %s: %.2f%% | ratio %.5f'):format(string.char(64+i),s.position*100,s.ratio))
  end
  for i=1,2 do
    local s=breakerState(i)
    print(('%s: %s | %s A | trip %s'):format(i==1 and '+' or '-',s.closed and 'closed' or 'open',
      s.currentValid and ('%.3f'):format(s.current) or 'invalid',s.tripEnabled and tostring(s.tripCurrent) or 'OFF'))
  end
  print('Q / Ctrl+T: stop and open BOTH breakers')
end
local function settledVoltages()
  local start=os.clock()
  local previous
  local stable=0
  while true do
    guard()
    local v={readV(1),readV(2)}
    if previous and math.abs(v[1]-previous[1])<=math.max(0.1,v[1]*0.001)
      and math.abs(v[2]-previous[2])<=math.max(tol,v[2]*0.001) then
      stable=stable+1
    else stable=0 end
    if stable>=3 then return v end
    assert(os.clock()-start<10,'Voltage readings did not settle with breakers open')
    previous=v; pause(0.1)
  end
end
local function diagnoseCapacity(input,output)
  local product=1; local parts={}
  for i=1,3 do
    local s=snapshot(i)
    product=product*calibratedRatio(s.position)
    parts[i]=('%s %.3f%%'):format(string.char(64+i),100*s.position)
  end
  local ceiling=output/product*calibratedRatio(1)^3
  log(('CAPACITY input %.3f V; output %.3f V; target %.3f V; %s; estimated passthrough %.3f V; currents + %.3f / - %.3f A')
    :format(input,output,C.target,table.concat(parts,', '),ceiling,breakerState(1).current,breakerState(2).current))
  return ('No useful correction: input %.2f V, output %.2f V, estimated passthrough %.2f V; see CAPACITY log')
    :format(input,output,ceiling)
end
local function tuneDisconnected()
  local start=os.clock()
  local inBand=0
  while true do
    if selectTarget(true) then inBand=0 end
    guard()
    latest=settledVoltages()
    local output=latest[2]
    assert(output>1,'Gauge 7 must read transformer output while breakers are OPEN; place it before both breakers')
    assert(os.clock()-start<90,'Could not reach target with breakers open within 90 seconds')
    local err=math.abs(output-C.target)
    local closeBand=managed and math.min(fallback,C.joinToleranceVolts) or fallback
    local acceptable=err<=math.min(tol,closeBand)
    local message='Verifying preferred accuracy with both OPEN'
    if not acceptable then
      -- With the load isolated, calculate the full destination directly from
      -- freshly settled output. No 8-degree crawl and no retained fault gain.
      local plan=choose(latest[1],output,false)
      if plan.travel>0 and plan.err<err-minImprovement then
        inBand=0
        display(err>coarseBand and 'Coarse positioning; both breakers OPEN' or 'Fine positioning; both breakers OPEN')
        apply(plan)
      elseif err<=closeBand then
        acceptable=true
        message='Nearest setting within fallback; both OPEN'
      else
        error(('Target unreachable while disconnected: error %.4f V, allowed %.4f V')
          :format(err,fallback),0)
      end
    end
    if acceptable then
      inBand=inBand+1
      if inBand>=3 then return end
      display(message)
      pause(0.15)
    end
  end
end
local function connect()
  local start=os.clock()
  repeat
    guard()
    if breakerState(1).canClose and breakerState(2).canClose then break end
    assert(os.clock()-start<C.chargeTimeout,'Charge BOTH breaker mechanisms before running')
    display('Waiting for both breakers to charge'); pause(0.2)
  until false
  -- Charging may take time; tune and verify again immediately before closing.
  repeat
    tuneDisconnected()
    guard()
    if not managed or math.abs(readV(2)-net.grid.voltage)<=C.joinToleranceVolts then break end
    assert(os.clock()-start<90,'Grid kept moving; could not match before close')
  until false
  assert(breakerState(1).canClose and breakerState(2).canClose,'Breaker charge lost before close')
  phase='closing'
  -- Calls are sequential, never claimed to be an atomic two-pole operation.
  local function closePole(i)
    guard()
    if managed and math.abs(readV(2)-net.grid.voltage)>C.joinToleranceVolts then
      error(STANDBY_PREFIX..'Grid changed before breaker close; matching again',0)
    end
    local ok,err=pcall(breakers[i].close)
    if not ok then
      if tostring(err):find('Terminated',1,true) then error(err,0) end
      retryFault('Breaker close failed: '..tostring(err))
    end
    if not breakerState(i).closed then retryFault('Breaker '..i..' failed to close') end
  end
  closePole(2)
  closePole(1)
  if not (breakerState(1).closed and breakerState(2).closed) then
    retryFault('Both breakers did not remain closed')
  end
  if managed then
    joinState={stage='settling',target=C.target,since=os.clock(),lastTick=os.clock()}
  end
  phase='live'; pause(0.25)
end
local function initialise()
  breakers[1]=wrap(C.plusBreaker,{'getStatus','open','close','isClosed','setTripCurrent'})
  breakers[2]=wrap(C.minusBreaker,{'getStatus','open','close','isClosed','setTripCurrent'})
  openBoth()
  gauges[1]=wrap(C.inputGauge,{'voltage'}); gauges[2]=wrap(C.outputGauge,{'voltage'})
  for i,key in ipairs({'A','B','C'}) do
    variacs[i]=wrap(C['variac'..key],{'getStatus'})
    gears[i]=wrap(C['gear'..key],{'rotate','isRunning'})
  end
  if C.breakerTripAmps>0 then
    for i=1,2 do breakers[i].setTripCurrent(C.breakerTripAmps) end
  end
end
local function advanceJoin()
  if not managed then return false end
  local now=os.clock()
  local output=readV(2)
  local a,b=breakerState(1),breakerState(2)
  local current=math.max(math.abs(a.current),math.abs(b.current))
  if joinState.stage=='settling' then
    if joinState.lastV and math.abs(output-joinState.lastV)<=C.joinToleranceVolts
      and math.abs(current-joinState.lastI)<=0.25 then
      joinState.stableSince=joinState.stableSince or now
    else joinState.stableSince=nil end
    joinState.lastV=output; joinState.lastI=current
    assert(now-joinState.since<C.gridSettleTimeout,'Grid/current did not settle after joining')
    if joinState.stableSince and now-joinState.stableSince>=C.joinHoldSeconds then
      -- Start the ramp from the actual settled bus voltage, avoiding a jump
      -- back to a pre-connection value if natural sharing changed the grid.
      joinState.target=output; joinState.stage='ramping'; joinState.lastTick=now
      log(('Grid settled at %.3f V; ramping to configured %.3f V'):format(output,nominalTarget))
    else
      -- Hold shaft positions during natural sharing; protections remain active.
      return true
    end
  end
  if joinState.stage=='ramping' then
    local dt=math.max(0,now-joinState.lastTick)
    joinState.lastTick=now
    -- Wait for each electrical adjustment to catch up before moving the goal.
    if math.abs(output-joinState.target)<=fallback then
      local step=math.min(C.maxRampStepVolts,C.rampVoltsPerSecond*dt)
      local delta=nominalTarget-joinState.target
      joinState.target=joinState.target+clamp(delta,-step,step)
      if math.abs(joinState.target-nominalTarget)<0.001 then
        joinState.target=nominalTarget; joinState.stage='nominal'
      end
    end
  end
  return false
end
local function run()
  if managed and faultLatched then
    phase='fault'
    while not net.reset do sleep(0.1) end
    faultLatched=nil; net.reset=false; retries=0; net.enabled=false
    log('Master explicitly reset latched fault; fresh enable required')
  end
  initialise()
  if managed then
    phase='standby'
    while true do
      if faultLatched and net.reset then
        faultLatched=nil; net.reset=false; retries=0
        log('Master explicitly reset latched fault')
      end
      local ready=networkReady()
      if not faultLatched and ready then break end
      if breakerState(1).closed or breakerState(2).closed then openBoth() end
      term.clear(); term.setCursorPos(1,1)
      print('Three-variac controller v10: STANDBY')
      print(faultLatched or select(2,networkReady()) or 'Waiting for master')
      print('Q: quit | master controls grid connection')
      sleep(0.1)
    end
  end
  phase='setup'; selectTarget(true); guard()
  log(('START v10 target %.2f step-up %.5f; generator minimum %.3f V'):format(C.target,C.stepUp,minimumGeneratorVolts))
  for i=1,3 do
    -- A sequence interrupted by a trip may still be physically running.
    idle(i); settled(i)
    if not directions[i] then
      display('Checking shaft direction '..i); discoverDirection(i)
    end
  end
  -- Normally the actual open-circuit output is available. If all stages are
  -- near minimum and the voltage is below 1 V, use a nominal preset once.
  latest=settledVoltages()
  if latest[2]<=1 then
    local plan=choose(latest[1],nil,false)
    assert(plan.err<=fallback,'Target outside nominal voltage range/accuracy')
    apply(plan)
  end
  tuneDisconnected()
  display('Closing both breakers'); connect()
  local unreachableSince
  local previous
  while true do
    guard()
    local holding=advanceJoin()
    if selectTarget(false) then previous=nil; unreachableSince=nil end
    latest={readV(1),readV(2)}
    local input,output=latest[1],latest[2]
    assert(output>1,'No final output voltage; check gauge, wiring and load')
    local err=math.abs(output-C.target)
    local stable=previous and math.abs(input-previous[1])<=math.max(1,previous[1]*0.005)
      and math.abs(output-previous[2])<=math.max(1,previous[2]*0.005)
    previous=latest
    if holding then
      unreachableSince=nil; previous=nil; display('Joined grid: waiting for natural sharing to settle')
    elseif err<=tol then
      unreachableSince=nil; display('Holding preferred voltage accuracy')
    elseif not stable then
      display('Waiting for readings to settle')
    else
      local p=choose(input,output,true)
      -- A 1-degree neighbourhood can have a local minimum when ratios become
      -- similar. A bounded coordinated re-balance escapes it; otherwise the
      -- ramp could stall even though a useful three-stage combination exists.
      if err>fallback and (p.travel==0 or p.err>=err-minImprovement) then
        local wider=choose(input,output,true,16)
        if wider.err<p.err-minImprovement then
          p=wider; log('PRECISION REBALANCE: 1-degree neighbourhood exhausted')
        end
      end
      if p.travel>0 and p.err<err-minImprovement then
        unreachableSince=nil
        display(err>coarseBand and 'Coarse adjustment' or 'Fine adjustment')
        log(('%s ADJUST %.3f -> predicted %.3f'):format(err>coarseBand and 'COARSE' or 'FINE',output,p.predicted))
        apply(p); previous=nil
      elseif err<=fallback then
        unreachableSince=nil
        display('Holding fallback: nearest useful local setting')
      else
        unreachableSince=unreachableSince or os.clock()
        if os.clock()-unreachableSince>=3 then error(diagnoseCapacity(input,output),0) end
        display('No useful adjustment available')
      end
    end
    pause(C.pollSeconds)
  end
end
if command=='status' then
  -- Read only: no movement, breaker operations or protection setting changes.
  for _,name in ipairs({C.inputGauge,C.variacA,C.gearA,C.variacB,C.gearB,C.variacC,C.gearC,C.outputGauge,C.plusBreaker,C.minusBreaker}) do
    print(name)
    local ok,result=pcall(function()
      local p=assert(peripheral.wrap(name),'Missing')
      if p.getStatus then return p.getStatus() end
      if p.voltage then return {voltage=p.voltage()} end
      return {running=p.isRunning()}
    end)
    print(ok and textutils.serialize(result) or tostring(result))
  end
  return
end
local function keyboard()
  while true do
    local event,value=os.pullEvent()
    if event=='char' and value:lower()=='q' then error('Stopped by user',0) end
  end
end
local function networkSend(message)
  if not managed or not networkOpened then return end
  message.schema=1; message.node=nodeId; message.session=session
  message.sentAt=os.epoch('utc')
  -- Link loss does not disable local protection. The lease expires separately.
  pcall(rednet.send,C.masterId,message,PROTOCOL)
end
local function telemetry()
  while true do
    if managed then
      local data={type='status',phase=phase,nominalTarget=nominalTarget,target=C.target,
        enabled=net.enabled,fault=faultLatched,retries=retries,minimumGeneratorVolts=minimumGeneratorVolts,
        grid=net.grid,joinStage=joinState.stage,variacs={},breakers={},lastSeq=net.lastSeq}
      local ok,value=pcall(function() return readV(1) end); if ok then data.inputVoltage=value end
      ok,value=pcall(function() return readV(2) end); if ok then data.outputVoltage=value end
      for i=1,3 do ok,value=pcall(snapshot,i); if ok then data.variacs[i]=value end end
      for i=1,2 do ok,value=pcall(breakerState,i); if ok then data.breakers[i]=value end end
      networkSend(data)
    end
    sleep(C.telemetrySeconds)
  end
end
local function receiver()
  if not managed then while true do sleep(1) end end
  while true do
    local sender,m=rednet.receive(PROTOCOL,0.5)
    if sender==C.masterId and type(m)=='table' and m.schema==1 and m.node==nodeId and m.session==session then
      local reason
      if not finite(m.seq) or m.seq%1~=0 or m.seq<0 or m.seq>9007199254740991 then reason='Invalid sequence'
      elseif m.seq<=net.lastSeq then reason='Duplicate/old sequence'
      elseif not finite(m.sentAt) or os.epoch('utc')-m.sentAt>C.masterTimeoutSeconds*1000 or m.sentAt-os.epoch('utc')>250 then reason='Stale command'
      elseif m.type=='dispatch' then
        if type(m.enabled)~='boolean' then reason='enabled must be boolean'
        elseif not m.enabled then
          net.enabled=false
        else
          local g=m.grid
          if type(g)~='table' or not finite(g.voltage) or g.voltage<=0 or type(g.healthy)~='boolean' or not finite(g.sampledAt) then
            reason='Grid voltage, healthy and sampledAt required'
          elseif os.epoch('utc')-g.sampledAt>C.gridMaxAgeSeconds*1000 or g.sampledAt-os.epoch('utc')>250 then reason='Stale grid sample'
          elseif m.runningTarget~=nil then reason='Nominal target is locally configured; omit runningTarget'
          else
            -- Copy only the validated fields. One task owns all shaft commands.
            net.grid={voltage=g.voltage,healthy=g.healthy,sampledAt=g.sampledAt}
            net.enabled=true
          end
        end
      elseif m.type=='reset' then
        if net.enabled then reason='Disable before reset' else net.reset=true end
      elseif m.type~='get_status' then reason='Unknown message type' end
      if not reason then
        net.lastSeq=m.seq
        -- Only dispatch renews the command lease; status requests cannot keep
        -- an old enable command alive indefinitely.
        if m.type=='dispatch' then net.lastSeen=os.clock() end
      end
      networkSend({type='ack',seq=m.seq,accepted=not reason,reason=reason,
        note='Acceptance records intent; status reports actual contact state'})
    end
  end
end
local function monitor()
  while true do
    if phase=='live' or (managed and (phase=='setup' or phase=='closing')) then guard() end
    sleep(0.05)
  end
end
local ok,err
if managed then
  local opened,openError=pcall(openBoth)
  if not opened then error('Cannot start managed mode with unverified breakers: '..tostring(openError),0) end
  rednet.open(C.modem); networkOpened=true
end
while true do
  phase='initializing'
  -- CC cooperative tasks: every blocking peripheral/timer wait yields so the
  -- receiver and protection task continue during motor movement and searches.
  ok,err=pcall(function() parallel.waitForAny(run,keyboard,monitor,receiver,telemetry) end)
  phase='stopping'
  local disconnected,disconnectError=pcall(openBoth)
  if not disconnected then
    ok=false; err='Cannot verify both breakers open: '..tostring(disconnectError)
    break
  end
  local reason=tostring(err)
  if ok or reason:find('Terminated',1,true) or reason=='Stopped by user' then break end
  if managed and reason:find(STANDBY_PREFIX,1,true) then
    log('STANDBY: '..reason)
  elseif reason:find(RETRY_PREFIX,1,true) and retries<3 then
    retries=retries+1
    log(('RECOVERY %d/3: both open; use fresh stable readings, re-position, recharge'):format(retries))
  else
    if reason:find(RETRY_PREFIX,1,true) then reason='Recovery failed after 3 retries; '..reason end
    err=reason
    if not managed then break end
    faultLatched=reason; net.enabled=false; net.reset=false
    log('LATCHED FAULT: '..reason)
    networkSend({type='fault',reason=reason})
    -- Remain online for telemetry and explicit disable/reset/start commands.
  end
end
phase='stopping'
local opened,openError=pcall(openBoth)
local reason=ok and 'Stopped' or tostring(err)
print(reason); log('STOP: '..reason)
networkSend({type='stopped',reason=reason,breakersOpen=opened})
if opened then print('Both breakers verified open. No automatic reclose.')
else printError('Could not open/verify both breakers: '..tostring(openError)) end
print('An in-progress gearshift sequence may finish after stopping.')
print('Log: '..LOG)
