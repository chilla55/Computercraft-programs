-- v18: input isolation, persistent maintenance and built-in concurrent UI.
-- v17: autonomous single-mode regulation with optional network supervision.
-- v16: scoped temporary voltage targets and explicitly permitted dead-bus supply.
-- v15: inverse-time thermal curve with one cooling credit per level.
-- v14: measured variac temperature protection (125 C / 5 s, immediate 140 C).
-- v13: estimated per-variac 29 A protection translated to source current.
-- v12: entry/exit ratio diagnostics and optional source voltage/current/power meters.
-- v11: peripheral discovery and monitored banks on shared stage drives.
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
-- Input gauge measures after any fixed input step-down, before all three banks.
-- Run: configure | status | run [target V/kV] [tolerance %] | sync
-- No arguments: configuration on first use, otherwise run saved configuration.
-- Every run checks direction with a small movement; no routine homing.
-- Misaligned banks alone may home to minimum after verified disconnection.
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
Envelope/grid timestamps are os.epoch('utc') milliseconds (thermal member timestamps use seconds). Grid samples expire after 2 s;
supervisory dispatch lease expires after 3 s (v17 defaults to local single-mode fallback). send success is NOT breaker-close confirmation.
Only status.breakers[1/2].closed reports actual contacts.

MASTER -> UNIT: enable/heartbeat (Lua table)
{
 schema=1, type='dispatch', node=NODE_ID, session=SESSION_FROM_STATUS,
 seq=NEXT_SEQUENCE, sentAt=os.epoch('utc'), enabled=true,
 grid={voltage=MEASURED_GRID_VOLTS, healthy=GRID_HEALTH_BOOLEAN,
       sampledAt=ACTUAL_GRID_SAMPLE_TIMESTAMP}
}
No runningTarget: nominal target stays locally configured. v16 optionally accepts scoped temporary transition targets (below).
A healthy live grid within the configured nominal range is required to join.
Parallel mode does not black-start a dead grid. v16 exclusive supply mode requires explicit local configuration (below).

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
retries per run/reset. Bank misalignment has a separate one-attempt-per-bank
recovery: verify both breakers open, home the shared drive to minimum, verify
EVERY member at minimum, retune and rejoin. Failed/repeated misalignment latches.
Fresh explicit unhealthy-grid supervision prevents supervised joining. v17 autonomous fallback handles lost/stale supervision as described below. No hardware fault can be bypassed by a master command.

STATUS REQUEST (does not renew enable lease)
{schema=1,type='get_status',node=NODE_ID,session=SESSION,seq=N,
 sentAt=os.epoch('utc')}
An accepted request gets ack plus an immediate status with requestSeq=N.
Requests do not enable the unit or renew its dispatch lease.

UNIT -> MASTER
Every message: schema=1, node, session, sentAt.
ack: seq, accepted, optional reason; acceptance means recorded intent only.
status: phase, nominalTarget, target (temporary active setpoint), enabled, fault,
 retries, minimumGeneratorVolts, inputVoltage, outputVoltage, grid, joinStage,
 variacs[1..3]={position,ratio,shaftSpeed,members}, breakers[1..2]=native status, lastSeq.
 Each stage retains its primary readings; members lists every configured variac
 as {name,position,ratio,shaftSpeed}. An unreadable bank is omitted, never zero.
Missing readings are omitted if a peripheral is unavailable; never assume zero.
Breaker 1 is plus; breaker 2 is minus. Current signs follow gauge orientation.
joinStage: standalone, settling, ramping, nominal.
v11 status additions (the v1 schema and original fields remain compatible):
 configuredTarget and currentTarget alias nominalTarget and target, in volts.
 voltages.input/output={peripheral,available,volts,sampledAt} describe the whole
 transformer assembly's existing input/output gauges. Missing readings have
 available=false and no volts/sample timestamp. They are NOT grid-side readings.
 stages[1..3]={stage,name,gear,available,position,degrees,ratio,members}.
 stage=1/2/3 maps to A/B/C. Position is 0..1; degrees is from minimum.
 The first selected member supplies the stage position. members contains every
 configured variac as {name,available,position,degrees,ratio,shaftSpeed}.
 An unavailable bank omits its aggregate position; readable members remain.
 faultDetails describes a currently latched fault; lastFault retains the most
 recent fault even after recovery: {code,stage,stageName,member,reason,sampledAt}.
 Stage/member fields are present only when known. Historical lastFault alone
 does not mean a fault is currently latched; inspect fault/phase and contacts.

v12 optional transformer measurements:
 voltages.source = BEFORE the entry transformer (raw generator-side voltage).
 voltages.input = AFTER entry transformer, BEFORE stage A (existing gauge).
 voltages.preStepUp = AFTER stage C, BEFORE exit transformer.
 voltages.output = AFTER exit transformer, BEFORE both breakers (existing gauge).
 Each voltage record includes configured, available, peripheral, volts, sampledAt.
 Unconfigured optional gauges have configured=false and available=false.
 Flat sourceVoltage/preStepUpVoltage fields are present only when measured.
 entryRatio = configured PRIMARY/SECONDARY voltage ratio (5 means 5:1).
 stepUp = configured EXIT output/input multiplier (2.5 means 2.5x).
 entryExpectedVoltage = sourceVoltage / entryRatio; exitExpectedVoltage =
 preStepUpVoltage * stepUp. These nominal predictions are not control feedback.
 entryMeasuredRatio = sourceVoltage / inputVoltage; exitMeasuredRatio =
 outputVoltage / preStepUpVoltage. Ratios require both readings above 1 V.
 ratioChecks.entry/exit={configured,available,tolerancePercent,measured,
 deviationPercent,withinTolerance}. Default comparison tolerance is 2%.
 A deviation is diagnostic, not an automatic trip or proof of wrong windings:
 load/source changes and losses also affect measured ratios. Samples are
 sequential, not simultaneous. Voltage ratios do not measure power efficiency.
 minimumGeneratorVolts remains the POST-entry variac-input threshold.
 minimumSourceVoltsEstimate = minimumGeneratorVolts * entryRatio is only an
 ideal source-side estimate, not an additional protection threshold.

 sourceMeters.current={configured,available,peripheral,method,amps,sampledAt}.
 sourceMeters.power={configured,available,peripheral,method,watts,sampledAt}.
 Both optional meters belong BEFORE the entry transformer / whole assembly.
 Readers use current()/power(), falling back to getValue(). Assigned gauges
 must return finite numbers in A/W; values retain the gauge's sign.
 sourceCurrentAmps and sourcePowerWatts are aliases for available measurements.
 sourcePowerEstimateWatts = sourceVoltage * abs(sourceCurrentAmps), a DC input
 power magnitude estimate. It requires both readings within 250 ms of each
 other; it is omitted otherwise. A power gauge is NOT required for this field.
 Measured sourcePowerWatts is never populated from an estimate.
 Missing optional meters remain unavailable and do not stop regulation, EXCEPT
 a source current gauge becomes required when sourceCurrentTripAmps > 0.
 sourceCurrentTripAmps defaults to 0 (no fixed source limit); a positive setting enables
 an absolute source-current limit. sourceCurrentProtectionEnabled reports this.
 Overlimit or missing/invalid current opens both breakers and latches a fault.
 Codes: source_overcurrent and source_current_unavailable, with peripheral,
 currentAmps (if available) and limitAmps. No automatic retry for these faults.
 This is source-side protection, NOT a measured current limit for every stage
 or branch. The output breakers cannot remove supply voltage from the assembly.
 The existing post-entry input and final-output gauges remain mandatory.

v13 per-variac estimated current protection:
 perVariacTripAmps defaults to 29 A PER variac, independent of voltage. The
 2794.423583984375 V reference is recorded for context; its 81.038 kW product
 is NOT used as a constant-power rating allowing higher current at lower volts.
 Protection enables when perVariacTripAmps > 0 AND both sourceGauge and
 sourceCurrentGauge are configured. Set perVariacTripAmps=0 to disable it.
 It enforces while closing/connected, including live motor movement. With both
 breakers open, source loss/excitation current is not treated as tap current.
 A positive fixed sourceCurrentTripAmps remains separately enforced in setup.

 stageCurrentProtection={enabled,enforcing,available,reason,perVariacLimitAmps,
 referenceVolts,assumesEqualSharing,sourceAmps,sourcePowerEstimateWatts,
 sourceLimitAmps,effectiveSourceLimitAmps,limitingStage,preExitVoltageMeasured,
 sampledAt,stages}. Each stage: {stage,name,members,voltageEstimate,bankLimitAmps,
 bankCurrentEstimate,perVariacCurrentEstimate,sourceLimitAmps}.
 Unavailable estimates omit limits/current estimates and contain a reason.

 The model uses actual bank positions with calibrated ratios and measured
 post-entry input voltage. It applies any pre-exit voltage shortfall to all
 stage-voltage estimates, and never boosts them above calibrated prediction.
 Use the measured preStepUpGauge if configured; otherwise final output / stepUp
 estimates pre-exit voltage. Source voltage/current and voltage-anchor samples
 must be available and within 250 ms. Power estimate = abs(source V * source A).
 For each stage: bank current estimate = source power / stage voltage estimate;
 per-variac current estimate = bank current estimate / configured member count;
 source limit = 29 A * member count * stage voltage estimate / source voltage.
 The lowest stage source limit wins. effectiveSourceLimitAmps also includes a
 positive, lower fixed sourceCurrentTripAmps. The configured entryRatio does
 not scale the measured post-entry voltage a second time.

 Exceeding the calculated limit opens/latches: stage_overcurrent_estimate,
 numeric stage, stageName, currentAmps (SOURCE), limitAmps (SOURCE),
 perVariacCurrentEstimate and perVariacLimitAmps. No automatic retries.
 Missing required model readings while enforcing opens/latches with
 stage_current_unavailable. A configured pre-exit gauge is required by this
 model, even though it was previously diagnostic-only.
 These are estimates assuming forward power flow and equal parallel sharing,
 not measured individual winding/branch currents. Source measurements cannot
 detect every unequal-sharing or circulating-current condition.

fault: reason, code, optional stage (1..3), stageName (A/B/C), member,
 recoverable (whether automatic bank recovery is being attempted).
 Codes include variac_stuck (no movement or failed minimum-endpoint check),
 bank_misaligned, drive_timeout, position_unstable, position_mismatch, and
 controller_fault. Stuck detection identifies an observed movement failure,
 not a proven mechanical cause; missing shaft power can produce the same fault.
 For bank misalignment, a recoverable fault precedes endpoint synchronisation.
 A failed sync emits a non-recoverable fault with the stage and stuck member.
 stopped: reason and breakersOpen verification result.

SAFETY / NETWORK NOTES
Explicit disable or a local protection trip interrupts motor waits and opens both contacts. Lost/stale supervision follows the v17 fallback policy below. An issued gearshift sequence can still finish after
opening. Local overcurrent, overvoltage, input-voltage and position checks remain.
These are cooperative CC tasks, not CPU threads. They yield during motor waits
and long searches. Chunk unloading/computer shutdown still stops the software.
Rednet is unauthenticated. ID/session/sequence checks reject accidental, replayed
or misaddressed traffic but cannot authenticate a malicious sender. Use a trusted
network; no cryptographic security is claimed.


v15 measured variac temperature protection:
 Status adds protectionMode="temperature" (default) or "current" (legacy).
 Existing protocol/channel/schema and command envelope are unchanged.
 thermal={enabled,warningC=125,tripC=140,graceSeconds=5,maxAgeSeconds=1,
   coolSeconds=5,recoveryConfirmSeconds=0.25,recoveryHysteresisC=0.25,
   curve={{temperatureC=126,seconds=5},{temperatureC=130,seconds=2},
     {temperatureC=135,seconds=0.5},{temperatureC=140,seconds=0}},fault?,members={...}}
 Each thermal.members item includes stage (1..3), stageName (A/B/C), member
 (peripheral name), available, temperatureC?, temperatureSource="measured",
 sampledAt? (UTC epoch SECONDS), aboveSince? (UTC epoch SECONDS), aboveSeconds,
 ambientTemperature?, nativeOverheated?, unavailableReason?, exposure,
 allowanceSeconds?, remainingSeconds?, recoveryUsed, recoveryArmed, coolSeconds.
 exposure is a consumed budget fraction (1 trips); recovery maps use string keys
 "126", "130", "135" with true values. Missing keys mean unused/unarmed.
 remainingSeconds assumes the present temperature stays constant; it is not a
 promised connection duration. Member coolSeconds is elapsed confirmed cooling;
 thermal.coolSeconds is the required cooling duration. aboveSeconds measures the
 episode age, including brief cool dips, not the remaining trip delay.
 These thermal timestamps are seconds; outer protocol timestamps remain milliseconds.
 Unavailable readings may retain a previous temperature field: only available=true
 identifies a fresh usable sample. Before initialization, thermal.available=false
 and members may be absent. In current mode thermal={enabled=false}.

 Above 125 C consume elapsed seconds / allowed seconds at the last reading.
 Allowed seconds interpolate between the curve points; 125..126 C uses 5 s.
 thermalGraceSeconds scales the 126 C allowance and the entire curve.
 Each downward crossing of 135, 130 or 126 C can refund 0.5 exposure ONCE per
 level per episode, capped at a full budget. Arm at level+0.25 C, then confirm
 non-increasing readings for 0.25 s at/below the crossed level. Warming cancels
 confirmation. A multi-level drop can credit only the reached level, not all
 skipped levels. Exhausted budgets cannot be rescued by a late cooling sample.
 Five continuous seconds <=125 C (thermalCoolSeconds) clears exposure/credits;
 brief cool dips and explicit fault reset retain them. At >=140 C trip on the
 first sample without grace. Missing/invalid/stale/unavailable
 thermal data also latch and prevent connection. The monitor interval is
 nominally 50 ms, subject to peripheral calls and server scheduling.
 Codes: thermal_overtemperature, thermal_hot_timeout, thermal_reading_unavailable.
 Fault messages and faultDetails identify stage, stageName and member, and
 include temperatureC/temperatureSource when known plus warningC, tripC and
 graceSeconds, exposure and recoveryUsed. A latched fault represents the first triggering condition.
 Native overheated is informational; the 140 C controller threshold governs.

 Exposure, recovery credits and thermal faults persist across restarts. Offline
 time charges the last accounting temperature; it does not confirm recovery or
 sustained cooling. Fresh readings are still required on startup. Cooling
 alone does not clear a fault. Disable before reset; reset requires fresh
 temperatures <=125 C on EVERY member. Rejected reset includes an ack reason.
 After successful reset, send a fresh enable with a valid grid sample.
 Thermal monitoring continues in managed standby and while fault-latched.
 Standalone thermal reset is available locally via reset_thermal; it verifies
 open breakers and fresh cool readings, and leaves both breakers open.

 Temperature mode does not enforce the v13 estimated per-variac current cap;
 stageCurrentProtection remains diagnostic with enforcing=false. Independent
 configured source-current and native breaker protections still apply.
 Migrated configurations without protectionMode default to temperature and
 require the addon 1.2.0 thermal API on every member. Choose current explicitly
 to retain v13 estimated-current enforcement without temperature monitoring.


v16 role-independent bus references and scoped shutdown preparation:
 The master supplies the assigned OUTPUT bus reading, whether generator,
 consumer or transmission voltage. Locally configured nominal target and
 transformer ratio must match that bus. Do not substitute another bus voltage.
 connectionMode="parallel" (default) requires an already-live bus.
 connectionMode="supply" explicitly permits an exclusively owned dead circuit
 at 0..deadBusVolts (default 5 V). This is a local setting, not remotely enabled.
 A fresh measured zero is required; unavailable readings never mean dead.
 Supply mode tunes to the configured/requested target when the bus is dead;
 for an already-live bus it still matches actual bus voltage before closing.
 After closing, a bus still dead beyond gridMaxAgeSeconds trips and isolates.
 Parallel mode retains its existing live-bus join checks.

 Optional field on an enabled dispatch:
 transition={id="shutdown-event",generator=GENERATOR_ID,targetVolts=2638,
             expiresAt=UTC_EPOCH_MILLISECONDS}
 remoteTargetPercent defaults to 0 (disabled) and must be configured locally
 to opt in. The target must fit nominal +/- this percentage; the percentage
 must be less than gridDeviationPercent. id is nonempty, <=80 characters;
 generator is a non-negative integer. Expiry must be future and <=30 seconds.
 runningTarget remains rejected. Invalid requests do not renew the lease.
 Accepted transitions do not alter nominal/configuredTarget. Once live,
 active targets use existing rampVoltsPerSecond/maxRampStepVolts and wait for
 electrical output to catch up. Joining a live bus still matches its voltage
 first. All temperature/current/voltage/position protections remain active.
 Omitted/expired transition returns toward nominal with the same ramp.
 Disabled dispatch clears transition; it never bypasses a latched fault.

 Status adds connectionMode, deadBusVolts, requestedTarget, transition and:
 remoteControl={temporaryTarget=true,enabled=BOOLEAN,minTarget,maxTarget,
                targetToleranceVolts=LOCAL_FALLBACK_VOLTS}.
 requestedTarget is the current scoped goal or nominal; currentTarget remains
 the actual progressing regulation setpoint. Compare measured output as well:
 an accepted target command is not evidence of voltage or power redistribution.
 This regulator never commands a generator clutch or infers a voltage change
 from generator maximum power; the upstream controller supplies that plan.


ENDER MODEM TRANSPORT
Use an ender modem on every communicating computer. Configuration lists only
wireless modem candidates; wired modems are not used for inter-computer rednet.
The modem API cannot distinguish ender from ordinary wireless hardware, so
install an actual ender modem. Wired peripheral sharing for this computer's
local devices remains separate. No remote peripheral access is assumed.
A missing modem is retried by telemetry; local protections remain active.
v17 autonomous operation uses the main dispatch lease only for optional supervision; expiry returns to local single mode. Legacy opt-out still opens on expiry. Upstream availability is not a regulator prerequisite: the local
main controller can supervise without an upstream controller.


v17 autonomous single-mode fallback (default):
 autonomousFallback=true: operate independently using local gauges, local
 protections and configured nominal voltage when no fresh main/grid data is
 available. Enabled units stay connected on communications loss; new runs can
 start in the existing standalone/single-mode algorithm without a supervisor.
 This does not substitute the isolated output gauge for a grid-side gauge:
 standalone connection behavior applies whenever supervision is unavailable.
 autonomousFallback=false retains legacy master-lease-required operation.
 masterId=-1 retains pure standalone operation without rednet.

 Missing/stale supervision immediately invalidates any temporary voltage goal;
 live setpoints ramp toward nominal using local limits. Normal regulation
 keeps nominal fixed. Optional remote targets are solely for generator
 connection/disconnection preparation, remain disabled by remoteTargetPercent=0
 by default, and never become permanent nominal configuration.

 Explicit dispatch enabled=false is persisted in transformer-operation-state.json
 (with .tmp recovery) and cannot expire into enabled operation. Local faults
 also inhibit operation. Reset does not enable. A valid enable saves enabled
 intent; local `enable` / `disable` commands save intent with contacts open.
 Starting `run` applies the saved intent. Missing state defaults to enabled
 single-mode operation; malformed state prevents operation.

 New MASTER -> UNIT command: type='release', with the normal envelope.
 It ends supervision/temporary targets without changing enabled intent.
 Optional dispatch enabled=true,autonomous=true requests local single mode
 without a grid sample, only when autonomousFallback is enabled locally.
 Neither can clear a fault. Reset requires effective operation disabled.

 Status adds autonomousFallback, controlMode='single'|'supervised', and
 supervisionAvailable. enabled now describes effective local operating intent.
 requestedTarget is nominal in single mode; transition is omitted when no
 active supervised adjustment exists. Computer/master restart must not send
 unsolicited disables to autonomous units. Observe their status first.


v18 local isolation telemetry:
 emergencyStopped: persisted local emergency-stop latch. Remote commands do not
 clear it; local Resume/reset verifies contacts and thermal reset conditions.
 maintenance={active,verified,drivesIdle,reason}. verified means configured input
 and output contacts were read open, NOT proof that the assembly has no voltage.
 inputBreakers=[{name,available,status}]: each configured input isolation contact.
 enabled is false during maintenance/emergency stop. A dispatch requesting true
 is rejected until local resume. Existing two-element breakers remains outputs.
 sparkGapVolts=7500: installation annotation for the independent source spark gap
 protecting generators; not a controller trip threshold or controllable endpoint.
 Maintenance and emergency stop open all configured input/output contacts.

Bank synchronization with input isolation:
 phase=homing covers isolated alignment verification and mechanical recovery.
 phase=energizing covers input-breaker charging/closure after bank verification.
 Alignment checks remain active during energized motion. Input and output
 contacts are opened before endpoint synchronization. Without configured input
 breakers, recovery latches bank_sync_requires_input_isolation with stage and
 stageName instead of homing an energized parallel bank. Input closure requires
 fresh aligned positions and idle drives. Alignment compares members within
 each bank, not the independently regulated positions of the three stages.
]=]
if args[1]=='protocol' then print(PROTOCOL_HELP); return end
local PATH = 'dual-variac-config.json'
local LOG = 'transformer-controller.log'
local presets = {120,240,480,2400,7200,24000,34500,69000,138000,230000,345000}
local C = {
  version=18, uiEnabled=true, inputBreakers={}, target=2640, thresholdPercent=2, stepUp=2.5,
  accuracyVolts=0.1, fallbackVolts=1, coarseBandPercent=2, maxFineStep=1,
  inputGauge='powergrid_voltage_gauge_6', outputGauge='powergrid_voltage_gauge_7',
  entryRatio=1, ratioTolerancePercent=2, sourceGauge='', preStepUpGauge='',
  sourceCurrentGauge='', sourcePowerGauge='', sourceCurrentTripAmps=0,
  autonomousFallback=true, connectionMode='parallel', deadBusVolts=5, remoteTargetPercent=0,
  perVariacTripAmps=29, protectionMode='temperature', thermalGraceSeconds=5, thermalMaxAgeSeconds=1, thermalCoolSeconds=5,
  variacsA={}, variacsB={}, variacsC={},
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
  assert(type(saved)=='table' and (saved.version==7 or saved.version==8 or saved.version==9 or saved.version==10 or saved.version==11 or saved.version==12 or saved.version==13 or saved.version==14 or saved.version==15 or saved.version==16 or saved.version==17 or saved.version==18),'Invalid configuration version')
  -- Explicitly migrate old two-stage mappings to the user's new three-stage
  -- installation. Other settings survive; configure writes the current mapping.
  local mappings={}
  for _,k in ipairs({'inputGauge','outputGauge','variacA','gearA','variacB','gearB','variacC','gearC','plusBreaker','minusBreaker'}) do mappings[k]=C[k] end
  for k in pairs(C) do if saved[k]~=nil then C[k]=saved[k] end end
  if saved.version==7 then
    for k,v in pairs(mappings) do C[k]=v end
    print('Migrated v7 peripheral mappings to the three-stage installation.')
  end
  if saved.version<9 and (saved.maxLiveStep==nil or saved.maxLiveStep==8) then C.maxLiveStep=315 end
  C.version=18
end
-- Keep legacy primary names for compatibility; each bank's first member is
-- the position used by the existing three-stage voltage planner.
for _,key in ipairs({'A','B','C'}) do
  if type(C['variacs'..key])=='table' and next(C['variacs'..key])==nil then
    C['variacs'..key]={C['variac'..key]}
  end
end
local function validate()
  for k,v in pairs(C) do
    if type(v)=='number' then assert(finite(v),'Invalid '..k) end
  end
  for _,k in ipairs({'target','stepUp','entryRatio','travelDegrees','moveTimeout','chargeTimeout','positionToleranceDegrees','maxInputVolts'}) do
    assert(type(C[k])=='number' and C[k]>0,'Invalid '..k)
  end
  assert(type(C.autonomousFallback)=='boolean','Invalid autonomous fallback setting')
  assert(C.connectionMode=='parallel' or C.connectionMode=='supply','Invalid connection mode')
  assert(finite(C.deadBusVolts) and C.deadBusVolts>=0 and C.deadBusVolts<C.target*.1,'Invalid dead bus threshold')
  assert(finite(C.remoteTargetPercent) and C.remoteTargetPercent>=0 and C.remoteTargetPercent<C.gridDeviationPercent,'Invalid remote target range')
  assert(C.protectionMode=='temperature' or C.protectionMode=='current','Protection mode must be temperature or current')
  assert(finite(C.thermalGraceSeconds) and C.thermalGraceSeconds>0,'Invalid thermal grace period')
  assert(finite(C.thermalCoolSeconds) and C.thermalCoolSeconds>0,'Invalid thermal cooling period')
  assert(finite(C.thermalMaxAgeSeconds) and C.thermalMaxAgeSeconds>=0.1,'Invalid thermal sample age')
  assert(finite(C.perVariacTripAmps) and C.perVariacTripAmps>=0,'Invalid per-variac current limit')
  assert(finite(C.sourceCurrentTripAmps) and C.sourceCurrentTripAmps>=0,'Invalid source current trip limit')
  assert(C.sourceCurrentTripAmps==0 or (type(C.sourceCurrentGauge)=='string' and C.sourceCurrentGauge~=''),'Source current trip requires a current gauge')
  assert(finite(C.ratioTolerancePercent) and C.ratioTolerancePercent>0 and C.ratioTolerancePercent<100,'Invalid ratio diagnostic tolerance')
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
  assert(type(C.uiEnabled)=='boolean','Invalid UI setting')
  assert(type(C.inputBreakers)=='table','Invalid input breaker list')
  local names={}
  for _,k in ipairs({'inputGauge','outputGauge','gearA','gearB','gearC','plusBreaker','minusBreaker'}) do
    assert(type(C[k])=='string' and #C[k]>0 and not names[C[k]],'Missing or duplicate peripheral: '..k)
    names[C[k]]=true
  end
  for index,name in pairs(C.inputBreakers) do
    assert(type(index)=='number' and index%1==0 and index>=1 and index<=#C.inputBreakers,'Input breakers must be a list')
    assert(type(name)=='string' and name~='' and not names[name],'Missing/duplicate input breaker')
    names[name]=true
  end
  for _,key in ipairs({'sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge'}) do
    local name=C[key]
    assert(type(name)=='string','Invalid optional gauge: '..key)
    if name~='' then
      assert(not names[name],'Duplicate peripheral: '..key)
      names[name]=true
    end
  end
  for _,key in ipairs({'A','B','C'}) do
    local bank=C['variacs'..key]
    assert(type(bank)=='table' and #bank>0,'Stage '..key..' needs at least one variac')
    local count=0
    for index,name in pairs(bank) do
      assert(type(index)=='number' and index%1==0 and index>=1 and index<=#bank,'Invalid bank list: '..key)
      assert(type(name)=='string' and #name>0 and not names[name],'Missing or duplicate bank member: '..tostring(name))
      names[name]=true; count=count+1
    end
    assert(count==#bank,'Invalid bank list: '..key)
    C['variac'..key]=bank[1]
  end
end
local function prompt(label,key,parse)
  write(label..' ['..tostring(C[key])..']: ')
  local s=read(); if s~='' then C[key]=parse and assert(parse(s),'Invalid '..key) or s end
end

-- Discovery only inspects exposed methods. It never moves shafts or contacts.
local roles={
  gauge={'voltage'}, current={'current'}, power={'power'}, variac={'getPosition','getRatio','getStatus'},
  gear={'rotate','isRunning'}, breaker={'getStatus','open','close','isClosed','setTripCurrent'},
  modem={'open','close','transmit','isOpen','isWireless'},
}
local function discover()
  local found={gauge={},current={},power={},variac={},gear={},breaker={},modem={}}
  local names=peripheral.getNames(); table.sort(names)
  print('Detected peripherals:')
  for _,name in ipairs(names) do
    local ok,methods=pcall(peripheral.getMethods,name)
    local available={}
    if ok and type(methods)=='table' then for _,method in ipairs(methods) do available[method]=true end end
    local matches={}
    for role,required in pairs(roles) do
      local compatible=true
      for _,method in ipairs(required) do if not available[method] then compatible=false end end
      if (role=='current' or role=='power') and available.getValue then compatible=true end
      if compatible and role=='modem' then
        local wirelessOK,wireless=pcall(function() return peripheral.wrap(name).isWireless() end)
        compatible=wirelessOK and wireless==true
      end
      if compatible then found[role][#found[role]+1]=name; matches[#matches+1]=role end
    end
    table.sort(matches)
    print(name..' ('..(#matches>0 and table.concat(matches,', ') or 'unrecognised')..')')
  end
  if #names==0 then print('None. Enable wired modem peripheral sharing, then configure again.') end
  return found
end
local function assignComponents()
  local found=discover()
  local assigned={}
  local function selectNames(label,role,current,multiple,optional)
    print(label)
    local candidates={}
    for _,name in ipairs(found[role]) do
      if not assigned[name] then candidates[#candidates+1]=name; print(('  %d: %s'):format(#candidates,name)) end
    end
    if optional then print(optional=='gauge' and '  -: leave this optional role unassigned' or '  -: keep modem setting for standalone mode') end
    while true do
      write('Select '..(multiple and 'numbers separated by commas' or 'number')..' ['..table.concat(current,', ')..']: ')
      local input=read()
      if optional=='gauge' and (input=='-' or (input=='' and current[1]=='')) then return {''} end
      if optional and input=='-' then return current end
      local selected={}
      if input=='' then
        for _,name in ipairs(current) do selected[#selected+1]=name end
      else
        for token in input:gmatch('[^,%s]+') do
          local index=tonumber(token)
          selected[#selected+1]=(index and candidates[index]) or token
        end
      end
      local seen={}; local valid=#selected>0 and (multiple or #selected==1)
      for _,name in ipairs(selected) do
        local present=false
        for _,candidate in ipairs(candidates) do if candidate==name then present=true end end
        if (not present and input~='') or seen[name] or assigned[name] then valid=false end
        seen[name]=true
      end
      if valid then
        for _,name in ipairs(selected) do assigned[name]=true end
        return selected
      end
      print('Choose available listed peripherals, once each. Names are also accepted.')
      if #candidates==0 then error('No available '..role..'; check peripheral sharing and rerun configure',0) end
    end
  end
  C.inputGauge=selectNames('Input gauge (after input step-down)','gauge',{C.inputGauge})[1]
  C.outputGauge=selectNames('Output gauge (after step-up, before BOTH breakers)','gauge',{C.outputGauge})[1]
  for _,key in ipairs({'A','B','C'}) do
    C['variacs'..key]=selectNames('Stage '..key..': variacs sharing ONE drive','variac',C['variacs'..key],true)
    C['variac'..key]=C['variacs'..key][1]
    C['gear'..key]=selectNames('Stage '..key..': sequenced gearshift','gear',{C['gear'..key]})[1]
  end
  C.plusBreaker=selectNames('Plus breaker','breaker',{C.plusBreaker})[1]
  C.minusBreaker=selectNames('Minus breaker','breaker',{C.minusBreaker})[1]
  C.modem=selectNames('Ender modem for computer-to-computer rednet','modem',{C.modem},false,C.masterId==-1)[1]
  C.sourceGauge=selectNames('Optional source gauge (BEFORE entry transformer)','gauge',{C.sourceGauge},false,'gauge')[1]
  C.preStepUpGauge=selectNames('Optional gauge AFTER stage C, BEFORE exit transformer','gauge',{C.preStepUpGauge},false,'gauge')[1]
  print('Source meters: BEFORE the entry transformer / whole assembly.')
  print('Generic getValue gauges are also listed; select the actual A/W meter.')
  C.sourceCurrentGauge=selectNames('Optional source CURRENT gauge (amps)','current',{C.sourceCurrentGauge},false,'gauge')[1]
  C.sourcePowerGauge=selectNames('Optional source POWER gauge (watts)','power',{C.sourcePowerGauge},false,'gauge')[1]
  local inputs=selectNames('Optional INPUT isolation breakers (all input poles)','breaker',#C.inputBreakers>0 and C.inputBreakers or {''},true,'gauge')
  C.inputBreakers=inputs[1]=='' and {} or inputs
  print('Assigned stage banks:')
  for _,key in ipairs({'A','B','C'}) do
    print(key..': '..table.concat(C['variacs'..key],', ')..' <- '..C['gear'..key])
  end
end

if args[1]=='standards' then
  print('Server voltage presets (V): '..table.concat(presets,', '))
  print('Custom targets such as 2640 are supported.'); return
end
if args[1]=='configure' or (not exists and not args[1]) then
  print('Three series variac banks followed by a FIXED step-up transformer.')
  print('Gauge 7: AFTER fixed step-up, BEFORE both breakers.')
  prompt('Nominal standalone target V / kV','target',volts)
  prompt('Master computer ID (-1 = standalone)','masterId',tonumber)
  assignComponents()
  prompt('Grid matching tolerance +/- volts','joinToleranceVolts',tonumber)
  prompt('Stable seconds after joining','joinHoldSeconds',tonumber)
  prompt('Return to nominal: volts per second','rampVoltsPerSecond',tonumber)
  prompt('Maximum target change per ramp step (V)','maxRampStepVolts',tonumber)
  prompt('Preferred accuracy +/- VOLTS','accuracyVolts',tonumber)
  prompt('Fallback accuracy +/- VOLTS','fallbackVolts',tonumber)
  prompt('Entry ratio primary:secondary (5 or 5:1; 1 = no conversion)','entryRatio',function(value)
    local a,b=value:match('^%s*([%d%.]+)%s*:%s*([%d%.]+)%s*$')
    if a then
      a,b=tonumber(a),tonumber(b)
      return a and b and b>0 and a/b or nil
    end
    return tonumber(value)
  end)
  prompt('Exit voltage multiplier (output/input)','stepUp',tonumber)
  prompt('Ratio comparison tolerance percent (diagnostic only)','ratioTolerancePercent',tonumber)
  prompt('Whole shaft degrees for full arm travel','travelDegrees',tonumber)
  prompt('Coarse travel limit (315 = direct target)','maxLiveStep',tonumber)
  prompt('Switch to fine steps within +/- percent','coarseBandPercent',tonumber)
  prompt('Maximum FINE step in degrees','maxFineStep',tonumber)
  prompt('Maximum tested variac INPUT voltage','maxInputVolts',tonumber)
  prompt('Extra generator voltage above calculated minimum','inputHeadroomVolts',tonumber)
  prompt('Final overvoltage trip above target (%)','outputTripPercent',tonumber)
  prompt('Breaker amps (0 keeps existing settings)','breakerTripAmps',tonumber)
  prompt('Fixed source trip amps (0 = no additional fixed limit)','sourceCurrentTripAmps',tonumber)
  prompt('Stage protection: temperature or current','protectionMode')
  prompt('Continue in single mode without supervisor (true/false)','autonomousFallback',function(v)
    assert(v=='true' or v=='false','Use true or false'); return v=='true' and 'true' or 'false'
  end)
  if type(C.autonomousFallback)=='string' then C.autonomousFallback=C.autonomousFallback=='true' end
  prompt('Connection mode: parallel or exclusive supply','connectionMode')
  prompt('Dead bus maximum volts (supply only)','deadBusVolts',tonumber)
  prompt('Temporary remote target +/- percent (0 disables)','remoteTargetPercent',tonumber)
  prompt('Curve allowance at 126 C (130 C = 40%, 135 C = 10%)','thermalGraceSeconds',tonumber)
  prompt('Seconds at/below 125 C to restore recovery credits','thermalCoolSeconds',tonumber)
  prompt('Current-mode PER VARIAC trip amps (0 = off)','perVariacTripAmps',tonumber)
  if C.protectionMode=='current' and C.perVariacTripAmps>0 and (C.sourceGauge=='' or C.sourceCurrentGauge=='') then
    print('Stage-current protection needs BOTH source voltage and current gauges; currently unavailable.')
  end
  validate()
  local f=assert(fs.open(PATH..'.tmp','w')); f.write(textutils.serializeJSON(C)); f.close()
  if fs.exists(PATH..'.bak') then fs.delete(PATH..'.bak') end
  if fs.exists(PATH) then fs.move(PATH,PATH..'.bak') end
  fs.move(PATH..'.tmp',PATH)
  print('Saved. Run transformer_controller run'); return
end
local command=args[1] or 'run'
assert(command=='run' or command=='sync' or command=='status' or command=='reset_thermal' or command=='enable' or command=='disable' or command=='maintenance' or command=='resume' or command=='emergency','Use configure, standards, status, run, sync, reset_thermal, enable, disable, maintenance, resume or emergency')
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
local emergencyStopped=false
local maintenanceRequested=false
local maintenanceVerified=false
local maintenanceLoaded=false
local maintenanceFailure
local MAINTENANCE_PATH='transformer-maintenance.json'
local MAINTENANCE_PREFIX='MAINTENANCE: '
local reloadRequested=false
local uiActive=C.uiEnabled and type(term.isColor)=='function' and term.isColor()
local uiMessage=''
local function loadMaintenance()
  if maintenanceLoaded then return end
  local path=fs.exists(MAINTENANCE_PATH..'.tmp') and MAINTENANCE_PATH..'.tmp' or MAINTENANCE_PATH
  if fs.exists(path) then
    local f=assert(fs.open(path,'r')); local saved=textutils.unserializeJSON(f.readAll()); f.close()
    assert(type(saved)=='table' and type(saved.active)=='boolean','Invalid saved maintenance state')
    maintenanceRequested=saved.active
    emergencyStopped=saved.emergency==true
    if emergencyStopped then maintenanceRequested=true end
  end
  maintenanceLoaded=true
end
local function saveMaintenance(active)
  maintenanceRequested=active
  local f=assert(fs.open(MAINTENANCE_PATH..'.tmp','w'),'Cannot save maintenance state')
  f.write(textutils.serializeJSON({active=active,emergency=emergencyStopped})); f.close()
  if fs.exists(MAINTENANCE_PATH) then fs.delete(MAINTENANCE_PATH) end
  fs.move(MAINTENANCE_PATH..'.tmp',MAINTENANCE_PATH)
  maintenanceLoaded=true
end
local operationEnabled=true
local operationLoaded=false
local operationSaved
local OPERATION_PATH='transformer-operation-state.json'
local function loadOperation()
  if operationLoaded or not (managed and C.autonomousFallback) then return end
  local path=fs.exists(OPERATION_PATH..'.tmp') and OPERATION_PATH..'.tmp' or OPERATION_PATH
  if fs.exists(path) then
    local f=assert(fs.open(path,'r')); local saved=textutils.unserializeJSON(f.readAll()); f.close()
    assert(type(saved)=='table' and saved.version==1 and type(saved.enabled)=='boolean','Invalid saved operation state')
    operationEnabled=saved.enabled; operationSaved=saved.enabled
  end
  operationLoaded=true
end
local function setOperation(enabled)
  if not (managed and C.autonomousFallback) then return end
  loadOperation(); operationEnabled=enabled
  if operationSaved==enabled then return end
  local f=assert(fs.open(OPERATION_PATH..'.tmp','w'),'Cannot persist operator enable/disable')
  f.write(textutils.serializeJSON({version=1,enabled=enabled})); f.close()
  if fs.exists(OPERATION_PATH) then fs.delete(OPERATION_PATH) end
  fs.move(OPERATION_PATH..'.tmp',OPERATION_PATH); operationSaved=enabled
end
local function isEnabled()
  if managed and C.autonomousFallback then return operationEnabled end
  return not managed or net.enabled
end
local function supervised()
  if not managed then return false end
  if not C.autonomousFallback then return true end
  local g=net.grid
  return net.enabled and os.clock()-net.lastSeen<=C.masterTimeoutSeconds and g~=nil
    and os.epoch('utc')-g.sampledAt<=C.gridMaxAgeSeconds*1000 and g.sampledAt-os.epoch('utc')<=250
end
local joinState={stage='standalone',target=nominalTarget}
local function deadBus() return C.connectionMode=='supply' and net.grid and net.grid.voltage>=0 and net.grid.voltage<=C.deadBusVolts end
local function desiredTarget()
  local t=net.transition
  return supervised() and t and os.epoch('utc')<t.expiresAt and t.targetVolts or nominalTarget
end
local function joiningTarget() if not supervised() then return nominalTarget end; return deadBus() and desiredTarget() or net.grid.voltage end
local networkOpened=false
local STANDBY_PREFIX='STANDBY: '
local function networkReady()
  if maintenanceRequested then return false,'Maintenance active' end
  if not managed then return true end
  if C.autonomousFallback then
    if not operationEnabled then return false,'Explicitly disabled; enable required' end
    if not supervised() then return true end
  end
  if not net.enabled then return false,'Disabled by master / awaiting dispatch' end
  if os.clock()-net.lastSeen>C.masterTimeoutSeconds then return false,'Master heartbeat expired' end
  local g=net.grid
  if not g or not g.healthy then return false,'Grid not healthy / no grid reading' end
  local age=(os.epoch('utc')-g.sampledAt)/1000
  if age< -0.25 or age>C.gridMaxAgeSeconds then return false,'Grid reading stale' end
  if not deadBus() and (g.voltage<nominalTarget*(1-C.gridDeviationPercent/100) or g.voltage>nominalTarget*(1+C.gridDeviationPercent/100)) then
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
    target=joining and joiningTarget() or joinState.target
  elseif not joining then target=joinState.target end
  local changed=math.abs(C.target-target)>0.001
  C.target=target
  coarseBand=target*C.coarseBandPercent/100
  minimumGeneratorVolts=target/(C.stepUp*calibratedRatio(1)^3)+C.inputHeadroomVolts
  return changed
end
local minImprovement=math.min(0.001,tol/10)
local gauges,variacs,gears,breakers={},{},{},{}
local directions={}
local bankMoving={true,true,true}
local bankNeedsSync={}
local bankSyncAttempts={}
local BANK_SYNC_PREFIX='BANK_MISALIGNED: '
local faultContext
local lastFault
local function stageFault(code,i,message,member)
  faultContext={code=code,stage=i,stageName=string.char(64+i),member=member,reason=message}
  error(message,0)
end
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
  local members={}
  for j,p in ipairs(variacs[i]) do
    local name=C['variacs'..string.char(64+i)][j]
    local s=p.getStatus()
    assert(type(s)=='table' and finite(s.position) and s.position>=0 and s.position<=1,'Invalid variac position: '..name)
    assert(finite(s.ratio) and s.ratio>=0.0099 and s.ratio<=1.0001,'Invalid variac ratio: '..name)
    assert(math.abs(s.ratio-(0.01+0.99*s.position))<0.001,'Unsupported position/ratio relationship: '..name)
    members[j]={name=name,position=s.position,ratio=s.ratio,shaftSpeed=s.shaftSpeed}
  end
  local first=assert(members[1],'Empty variac bank')
  return {position=first.position,ratio=first.ratio,shaftSpeed=first.shaftSpeed,members=members}
end
local function aligned(i,s)
  local low,high=1,0
  for _,member in ipairs(s.members) do
    low=math.min(low,member.position); high=math.max(high,member.position)
  end
  if (high-low)*C.travelDegrees>C.positionToleranceDegrees then
    stageFault('bank_misaligned',i,BANK_SYNC_PREFIX..i..(' stage %s differs by %.2f degrees'):format(string.char(64+i),(high-low)*C.travelDegrees))
  end
end
local function positionChange(a,b)
  local delta=0
  for j,member in ipairs(a.members) do delta=math.max(delta,math.abs(member.position-b.members[j].position)*C.travelDegrees) end
  return delta
end
local function readV(i)
  local v=gauges[i].voltage(); assert(finite(v),'Invalid voltage gauge reading')
  return math.abs(v)
end
-- Extra gauges are diagnostic: missing data never replaces a control reading.
-- Wrap optional gauges per sample so an attached/replaced gauge can recover.
local function voltageMeasurements()
  local readings={}
  for i,key in ipairs({'input','output','source','preStepUp'}) do
    local name=({C.inputGauge,C.outputGauge,C.sourceGauge,C.preStepUpGauge})[i]
    local sample={peripheral=name,configured=name~='',available=false}
    readings[key]=sample
    if sample.configured then
      local ok,value=pcall(function()
        local p=assert(peripheral.wrap(name),'Missing optional gauge: '..name)
        local v=p.voltage(); assert(finite(v),'Invalid optional voltage reading')
        return math.abs(v)
      end)
      if ok then sample.volts=value; sample.sampledAt=os.epoch('utc'); sample.available=true end
    end
  end
  return readings
end
local function sourceMeter(name,method,unit)
  local sample={peripheral=name,configured=name~='',available=false}
  if not sample.configured then return sample end
  local ok,value=pcall(function()
    local p=assert(peripheral.wrap(name),'Missing source meter: '..name)
    local reader=type(p[method])=='function' and method or 'getValue'
    sample.method=reader
    local v=p[reader](); assert(finite(v),'Invalid source '..method..' reading')
    return v -- Preserve signed current/power; orientation belongs to the meter.
  end)
  if ok then sample[unit]=value; sample.available=true; sample.sampledAt=os.epoch('utc') end
  return sample
end
local function ratioCheck(expected,measured)
  local result={configured=expected,available=finite(measured) and finite((measured/expected-1)*100),tolerancePercent=C.ratioTolerancePercent}
  if result.available then
    result.measured=measured
    result.deviationPercent=(measured/expected-1)*100
    result.withinTolerance=math.abs(result.deviationPercent)<=C.ratioTolerancePercent
  end
  return result
end
local function stageCurrentEnabled()
  return C.perVariacTripAmps>0 and C.sourceGauge~='' and C.sourceCurrentGauge~=''
end
local function stageCurrentEstimate(readings,current)
  local result={enabled=stageCurrentEnabled(),available=false,perVariacLimitAmps=C.perVariacTripAmps,
    referenceVolts=2794.423583984375,assumesEqualSharing=true,stages={}}
  if not result.enabled then result.reason='Requires source voltage/current gauges and a positive per-variac limit'; return result end
  readings=readings or voltageMeasurements()
  current=current or sourceMeter(C.sourceCurrentGauge,'current','amps')
  local ok,reason=pcall(function()
    local source,input=readings.source,readings.input
    assert(source.available and source.volts>1,'Source voltage unavailable/too low')
    assert(input.available and input.volts>1,'Variac input voltage unavailable/too low')
    assert(current.available,'Source current unavailable')
    local oldest=math.min(source.sampledAt,input.sampledAt,current.sampledAt)
    local newest=math.max(source.sampledAt,input.sampledAt,current.sampledAt)
    -- The pre-exit gauge anchors loaded stage-voltage estimates. Until fitted,
    -- use final output divided by the configured exit multiplier as an estimate.
    local preExit=C.preStepUpGauge~='' and readings.preStepUp or readings.output
    assert(preExit.available and preExit.volts>0,'Pre-exit voltage unavailable/zero')
    oldest=math.min(oldest,preExit.sampledAt); newest=math.max(newest,preExit.sampledAt)
    assert(newest-oldest<=250,'Stage-current samples are more than 250 ms apart')
    local preExitVolts=preExit.volts/(C.preStepUpGauge~='' and 1 or C.stepUp)
    local modeled=input.volts
    for i=1,3 do
      local bank=snapshot(i); local ratio=1
      for _,member in ipairs(bank.members) do ratio=math.min(ratio,calibratedRatio(member.position)) end
      modeled=modeled*ratio
      result.stages[i]={stage=i,name=string.char(64+i),members=#bank.members,voltageEstimate=modeled}
    end
    -- Apply any observed voltage shortfall to every stage. Never raise a stage
    -- voltage estimate above its calibrated prediction from an output spike.
    local correction=math.min(1,preExitVolts/modeled)
    local power=source.volts*math.abs(current.amps)
    assert(finite(power),'Invalid source power estimate')
    local lowest=math.huge
    for i,stage in ipairs(result.stages) do
      stage.voltageEstimate=stage.voltageEstimate*correction
      assert(stage.voltageEstimate>0 and finite(stage.voltageEstimate),'Invalid stage voltage estimate')
      stage.bankLimitAmps=C.perVariacTripAmps*stage.members
      stage.bankCurrentEstimate=power/stage.voltageEstimate
      stage.perVariacCurrentEstimate=stage.bankCurrentEstimate/stage.members
      stage.sourceLimitAmps=stage.bankLimitAmps*stage.voltageEstimate/source.volts
      assert(finite(stage.perVariacCurrentEstimate) and finite(stage.sourceLimitAmps),'Invalid stage current estimate')
      if stage.sourceLimitAmps<lowest then lowest=stage.sourceLimitAmps; result.limitingStage=i end
    end
    result.sourceLimitAmps=lowest
    result.effectiveSourceLimitAmps=C.sourceCurrentTripAmps>0 and math.min(lowest,C.sourceCurrentTripAmps) or lowest
    result.sourceAmps=current.amps
    result.sourcePowerEstimateWatts=power
    result.preExitVoltageMeasured=C.preStepUpGauge~=''
    result.sampledAt=os.epoch('utc')
  end)
  if ok then result.available=true else result.reason=tostring(reason); result.stages={} end
  return result
end
local function breakerState(i)
  local device=breakers[i] or assert(peripheral.wrap(i==1 and C.plusBreaker or C.minusBreaker),'Missing output breaker')
  local s=device.getStatus()
  assert(type(s)=='table' and type(s.closed)=='boolean','Invalid breaker status')
  return s
end
local thermalPolicy
local thermalReadings={}
local thermalSampleTimes={}
local thermalLastPoll
local thermalSampling=false
local thermalScanStarted
local thermalInitialized=false
local function cancelThermalSampling()
  -- Called only after waitForAny has discarded its worker coroutines. Their
  -- suspended pcall cleanup cannot run, so release the abandoned scan here.
  thermalSampling=false; thermalScanStarted=nil
end
local thermalSaved
local THERMAL_PATH='transformer-thermal-state.json'
local function thermalEnabled() return C.protectionMode=='temperature' end
local function thermalEnsure(forReset)
  if thermalPolicy then return end
  local directory=fs.getDir(shell.getRunningProgram())
  local factory=assert(loadfile(fs.combine(directory,'thermal_protection.lua')),
    'Missing thermal_protection.lua beside transformer_controller.lua')()
  local policy=factory.new({C.variacsA,C.variacsB,C.variacsC},
    {warningC=125,tripC=140,graceSeconds=C.thermalGraceSeconds,maxAgeSeconds=C.thermalMaxAgeSeconds,coolSeconds=C.thermalCoolSeconds})
  do
    local checkpoint
    for _,path in ipairs({THERMAL_PATH..'.tmp',THERMAL_PATH,THERMAL_PATH..'.bak'}) do
      if fs.exists(path) then checkpoint=path; break end
    end
    if checkpoint then
      local file=assert(fs.open(checkpoint,'r'),'Cannot read thermal checkpoint')
      local saved=textutils.unserializeJSON(file.readAll()); file.close()
      local restored,reason=pcall(policy.restore,saved)
      if not restored then
        if not forReset then error(reason,0) end
        policy=factory.new({C.variacsA,C.variacsB,C.variacsC},
          {graceSeconds=C.thermalGraceSeconds,maxAgeSeconds=C.thermalMaxAgeSeconds,coolSeconds=C.thermalCoolSeconds})
      end
    end
  end
  thermalPolicy=policy
end
local function thermalSave()
  local serialized=textutils.serializeJSON(thermalPolicy.export())
  if serialized==thermalSaved then return end
  local file=assert(fs.open(THERMAL_PATH..'.tmp','w'),'Cannot save thermal checkpoint')
  file.write(serialized); file.close()
  -- CC has no atomic replace; keep a backup across the replacement window.
  if fs.exists(THERMAL_PATH..'.bak') then fs.delete(THERMAL_PATH..'.bak') end
  if fs.exists(THERMAL_PATH) then fs.move(THERMAL_PATH,THERMAL_PATH..'.bak') end
  fs.move(THERMAL_PATH..'.tmp',THERMAL_PATH)
  thermalSaved=serialized
end
local function thermalRaise(detail)
  if detail then
    if detail.code=='thermal_reading_unavailable' then
      local reading=thermalReadings[detail.member]
      local sampledAt=thermalSampleTimes[detail.member]
      local why=reading and reading.reason
      if not why and sampledAt then
        why=('last sample %.3f s ago; limit %.3f s'):format(os.epoch('utc')/1000-sampledAt,C.thermalMaxAgeSeconds)
      end
      if why then detail.reason=detail.reason..' ('..tostring(why)..')' end
    end
    faultContext=detail; error(detail.reason,0)
  end
end
local function thermalPoll(enforce)
  if not thermalEnabled() then return end
  thermalEnsure()
  if thermalSampling or (thermalLastPoll and os.clock()-thermalLastPoll<0.05) then
    if enforce and (thermalInitialized or not thermalSampling
      or os.epoch('utc')/1000-thermalScanStarted>=C.thermalMaxAgeSeconds) then
      -- Do not mark untouched members missing halfway through the first scan.
      -- A blocked first scan still has the configured freshness deadline.
      local detail=thermalPolicy.check(os.epoch('utc')/1000)
      if detail then thermalSave(); thermalRaise(detail) end
    end
    return
  end
  thermalSampling=true; thermalScanStarted=os.epoch('utc')/1000
  local ok,err=pcall(function()
    if thermalLastPoll and os.clock()-thermalLastPoll>C.thermalMaxAgeSeconds then
      local stale=thermalPolicy.check(os.epoch('utc')/1000)
      if stale and enforce then thermalSave(); thermalRaise(stale) end
    end
    for _,key in ipairs({'A','B','C'}) do
      for _,name in ipairs(C['variacs'..key]) do
        local available,value=pcall(function()
          local device=assert(peripheral.wrap(name),'Variac unavailable')
          assert(type(device.getThermalStatus)=='function','Temperature API 1.2.0 is required')
          local reading=device.getThermalStatus()
          assert(type(reading)=='table' and reading.unit=='C','Invalid thermal status')
          if reading.available~=true then error(tostring(reading.reason or 'unavailable'),0) end
          assert(finite(reading.temperature) and reading.temperature>=-273.15,'Invalid device temperature')
          return reading
        end)
        local now=os.epoch('utc')/1000
        thermalReadings[name]=available and value or {available=false,unit='C',reason=tostring(value)}
        thermalSampleTimes[name]=now
        local detail=thermalPolicy.update(name,available and value.temperature or nil,now,'measured')
        if detail and enforce then thermalSave(); thermalRaise(detail) end
      end
    end
    thermalLastPoll=os.clock(); thermalInitialized=true
    local detail=thermalPolicy.check(os.epoch('utc')/1000)
    thermalSave()
    if enforce then thermalRaise(detail) end
  end)
  thermalSampling=false; thermalScanStarted=nil
  if not ok then error(err,0) end
end
local function thermalStatus()
  if not thermalEnabled() then return {enabled=false} end
  if not thermalPolicy then return {enabled=true,available=false,warningC=125,tripC=140,graceSeconds=C.thermalGraceSeconds} end
  local status=thermalPolicy.status(os.epoch('utc')/1000); status.enabled=true
  for _,member in ipairs(status.members) do
    local reading=thermalReadings[member.member]
    if reading then
      member.ambientTemperature=reading.ambientTemperature
      member.nativeOverheated=reading.overheated
      member.unavailableReason=reading.reason
    end
  end
  return status
end
local function thermalReset()
  if not thermalEnabled() then return true end
  thermalEnsure(true)
  thermalPoll(false)
  local ok,reason=thermalPolicy.reset(os.epoch('utc')/1000)
  if ok then thermalSave() end
  return ok,reason
end
local function guard()
  if maintenanceRequested then error(MAINTENANCE_PREFIX..'Isolating transformer',0) end
  if thermalEnabled() then thermalPoll(true) end
  if managed then
    local ready,reason=networkReady()
    if not ready then error(STANDBY_PREFIX..reason,0) end
  end
  if C.sourceCurrentTripAmps>0 then
    local sample=sourceMeter(C.sourceCurrentGauge,'current','amps')
    local reason,code
    if not sample.available then
      reason='Source current reading unavailable; cannot enforce source trip limit'
      code='source_current_unavailable'
    elseif math.abs(sample.amps)>C.sourceCurrentTripAmps then
      reason=('Source overcurrent: %.3f A exceeds %.3f A limit'):format(math.abs(sample.amps),C.sourceCurrentTripAmps)
      code='source_overcurrent'
    end
    if reason then
      faultContext={code=code,reason=reason,peripheral=C.sourceCurrentGauge,
        currentAmps=sample.amps,limitAmps=C.sourceCurrentTripAmps}
      error(reason,0)
    end
  end
  if phase=='homing' then
    -- Mechanical work with contacts open must not require input voltage.
    for _,name in ipairs({C.plusBreaker,C.minusBreaker}) do
      assert(peripheral.wrap(name).isClosed()==false,'Output closed during bank alignment: '..name)
    end
    for _,name in ipairs(C.inputBreakers) do
      assert(peripheral.wrap(name).isClosed()==false,'Input closed during bank alignment: '..name)
    end
    return
  end
  -- With the load isolated, source current can be excitation/loss current,
  -- so it must not be amplified into fictitious tap current during homing.
  if C.protectionMode=='current' and stageCurrentEnabled() and (phase=='live' or phase=='closing') then
    local estimate=stageCurrentEstimate()
    if not estimate.available then
      local reason='Cannot enforce per-variac current limit: '..estimate.reason
      faultContext={code='stage_current_unavailable',reason=reason}
      error(reason,0)
    end
    if math.abs(estimate.sourceAmps)>estimate.sourceLimitAmps then
      local i=estimate.limitingStage; local stage=estimate.stages[i]
      local reason=('Stage %d estimated %.3f A per variac exceeds %.3f A; source %.3f A, equivalent limit %.3f A')
        :format(i,stage.perVariacCurrentEstimate,C.perVariacTripAmps,math.abs(estimate.sourceAmps),estimate.sourceLimitAmps)
      faultContext={code='stage_overcurrent_estimate',stage=i,stageName=string.char(64+i),reason=reason,
        currentAmps=estimate.sourceAmps,limitAmps=estimate.sourceLimitAmps,
        perVariacCurrentEstimate=stage.perVariacCurrentEstimate,perVariacLimitAmps=C.perVariacTripAmps,
        peripheral=C.sourceCurrentGauge}
      error(reason,0)
    end
  end
  for _,name in ipairs(C.inputBreakers) do
    local device=assert(peripheral.wrap(name),'Missing input breaker '..name)
    assert(device.isClosed(),'Input breaker opened: '..name..'; automatic reclose disabled')
  end
  local a,b=breakerState(1),breakerState(2)
  if phase=='live' then
    if supervised() and deadBus() and joinState.since and os.clock()-joinState.since>C.gridMaxAgeSeconds then
      error('Supply bus remained dead after breaker close',0)
    end
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
  for i=1,3 do
    if variacs[i] then
      local s=snapshot(i)
      aligned(i,s) -- Movement never exempts an energized parallel bank.
    end
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
local function openInputs()
  local errors={}
  for _,name in ipairs(C.inputBreakers) do
    local ok,reason=pcall(function()
      local device=assert(peripheral.wrap(name),'Missing input breaker '..name)
      device.open(); assert(device.isClosed()==false,'Input breaker failed to open: '..name)
    end)
    if not ok then errors[#errors+1]=tostring(reason) end
  end
  assert(#errors==0,table.concat(errors,'; '))
end
local function isolateAll()
  local outOK,outError=pcall(openBoth)
  local inOK,inError=pcall(openInputs)
  maintenanceVerified=outOK and inOK and #C.inputBreakers>0
  maintenanceFailure=not maintenanceVerified and tostring(not outOK and outError or not inOK and inError or 'No input breakers configured') or nil
  return outOK and inOK,table.concat({not outOK and tostring(outError) or '',not inOK and tostring(inError) or ''},' ')
end
local function maintainIsolation()
  local errors={}
  local names={C.plusBreaker,C.minusBreaker}
  for _,name in ipairs(C.inputBreakers) do names[#names+1]=name end
  for _,name in ipairs(names) do
    local ok,reason=pcall(function()
      local device=assert(peripheral.wrap(name),'Missing '..name)
      local closed=device.isClosed()
      assert(type(closed)=='boolean','Invalid contact state: '..name)
      if closed then device.open(); assert(device.isClosed()==false,'Failed to reopen '..name) end
    end)
    if not ok then errors[#errors+1]=tostring(reason) end
  end
  maintenanceVerified=#errors==0 and #C.inputBreakers>0
  maintenanceFailure=#errors>0 and table.concat(errors,'; ') or (#C.inputBreakers==0 and 'No input breakers configured' or nil)
end
local function drivesIdle()
  for _,key in ipairs({'A','B','C'}) do
    local ok,idle=pcall(function() return peripheral.wrap(C['gear'..key]).isRunning()==false end)
    if not ok or not idle then return false end
  end
  return true
end
local function energizeInputs()
  -- Fresh positions for EVERY bank before any input pole can energize it.
  for i=1,3 do
    assert(gears[i].isRunning()==false,'Drive still running before input close: stage '..i)
    aligned(i,snapshot(i))
  end
  if #C.inputBreakers==0 then return end
  phase='energizing'
  openBoth()
  local started=os.clock()
  for _,name in ipairs(C.inputBreakers) do
    local device=assert(peripheral.wrap(name),'Missing input breaker '..name)
    while true do
      if maintenanceRequested then error(MAINTENANCE_PREFIX..'Requested during input close',0) end
      local ready,reason=networkReady(); if not ready then error(STANDBY_PREFIX..reason,0) end
      thermalPoll(true)
      local state=device.getStatus()
      if state.closed or state.canClose then break end
      assert(os.clock()-started<C.chargeTimeout,'Charge input breaker '..name)
      sleep(.1)
    end
    if maintenanceRequested then error(MAINTENANCE_PREFIX..'Requested during input close',0) end
    -- Charging may have taken time; recheck immediately before each pole closes.
    for i=1,3 do
      assert(gears[i].isRunning()==false,'Drive started before input close: stage '..i)
      aligned(i,snapshot(i))
    end
    device.close(); assert(device.isClosed(),'Input breaker failed to close: '..name)
  end
  maintenanceVerified=false
  -- Allow source-side gauges to update before undervoltage protection starts.
  sleep(.25)
end
local function idle(i)
  local start=os.clock()
  while gears[i].isRunning() do
    if os.clock()-start>=C.moveTimeout then stageFault('drive_timeout',i,'Gearshift timeout: stage '..i) end
    pause(0.05)
  end
  guard()
end
local function settled(i,skipAlignment)
  -- Read the physical arm until interpolation has stopped, not merely gear idle.
  local start=os.clock(); local old=snapshot(i); local stable=0
  repeat
    pause(0.05)
    local p=snapshot(i)
    if positionChange(p,old)<0.02 then stable=stable+1 else stable=0 end
    old=p
    if os.clock()-start>=C.moveTimeout then stageFault('position_unstable',i,'Variac bank failed to settle: stage '..i) end
  until stable>=4
  local s=snapshot(i)
  if not skipAlignment then aligned(i,s); bankMoving[i]=false end
  return s
end
local function rotateRaw(i,n,modifier,skipAlignment)
  idle(i); guard()
  bankMoving[i]=true
  gears[i].rotate(n,modifier)
  pause(0.1); idle(i)
  return settled(i,skipAlignment)
end
local function discoverDirection(i,skipAlignment)
  local before=snapshot(i).position
  local after=rotateRaw(i,3,1,skipAlignment).position
  local delta=after-before; local modifier=1
  if math.abs(delta)*C.travelDegrees<0.2 then
    before=after; modifier=-1
    after=rotateRaw(i,3,-1,skipAlignment).position; delta=after-before
  end
  if math.abs(delta)*C.travelDegrees<0.2 then
    stageFault('variac_stuck',i,'Stage '..i..' did not move; check shaft power',C['variacs'..string.char(64+i)][1])
  end
  directions[i]=delta>0 and modifier or -modifier
  log(('Stage %d: increasing modifier %d'):format(i,directions[i]))
end
local function syncBank(i)
  -- Fault-only homing, explicitly requested for shared-shaft banks. Never
  -- assume that a command can cancel a sequence already running in hardware.
  local isolated,reason=isolateAll(); assert(isolated,reason)
  if #C.inputBreakers==0 then
    stageFault('bank_sync_requires_input_isolation',i,'Bank sync requires configured input isolation breakers')
  end
  phase='homing'
  bankNeedsSync[i]=nil -- An interrupted attempt must not restart homing indefinitely.
  bankMoving[i]=true
  idle(i); settled(i,true)
  log(('BANK SYNC stage %d: input and output breakers OPEN; detecting direction'):format(i))
  discoverDirection(i,true)
  -- Full travel plus the direction-test margin takes every linked member to
  -- minimum, irrespective of their starting offsets. Verify actual endpoints.
  local s=rotateRaw(i,math.ceil(C.travelDegrees)+3,-directions[i],true)
  for _,member in ipairs(s.members) do
    if member.position*C.travelDegrees>0.1 then
      stageFault('variac_stuck',i,'Bank sync failed: '..member.name..' did not reach minimum position',member.name)
    end
  end
  aligned(i,s); bankMoving[i]=false; bankNeedsSync[i]=nil
  log(('BANK SYNC stage %d: all %d members verified at minimum'):format(i,#s.members))
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
  local planningTolerance=(supervised() and phase~='live') and math.min(tol,C.joinToleranceVolts) or tol
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
    local wanted=phase=='live' and joinState.target or joiningTarget()
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
        local p=snapshot(i)
        pending[#pending+1]={index=i,expected=clamp(p.position+plan[i]/C.travelDegrees,0,1),last=p,initial=p,stable=0}
      end
    end
    if #pending==0 then return end
    -- All motors in this group run together. Peripheral calls are sequential,
    -- but we do not wait for one motor's entire movement before starting another.
    for _,m in ipairs(pending) do
      guard()
      local i=m.index
      log(('Stage %d movement %+d degrees (group %s)'):format(i,plan[i],sign<0 and 'lower' or 'raise'))
      bankMoving[i]=true
      gears[i].rotate(math.abs(plan[i]),sign*directions[i])
    end
    local start=os.clock()
    repeat
      pause(0.05)
      local done=true
      for _,m in ipairs(pending) do
        local i=m.index
        local p=snapshot(i)
        if not gears[i].isRunning() and positionChange(p,m.last)<0.02 then
          m.stable=m.stable+1
        else m.stable=0 end
        m.last=p
        if m.stable<4 or os.clock()-start<0.2 then done=false end
      end
      if done then break end
      if os.clock()-start>=C.moveTimeout then
        for _,m in ipairs(pending) do
          if m.stable<4 then stageFault('drive_timeout',m.index,'Grouped movement timeout: stage '..m.index) end
        end
      end
    until false
    for _,m in ipairs(pending) do
      local s=snapshot(m.index); aligned(m.index,s); bankMoving[m.index]=false
      -- A completely stalled 1-degree fine move must not hide inside the
      -- 1-degree positional tolerance and be retried forever.
      for j,member in ipairs(s.members) do
        local before=m.initial.members[j].position
        local expected=clamp(before+plan[m.index]/C.travelDegrees,0,1)
        if math.abs(expected-before)*C.travelDegrees>=0.2
          and math.abs(member.position-before)*C.travelDegrees<0.2 then
          stageFault('variac_stuck',m.index,'Stage '..m.index..' member did not move: '..member.name,member.name)
        end
      end
      local errorDegrees=math.abs(s.position-m.expected)*C.travelDegrees
      if errorDegrees>C.positionToleranceDegrees then
        stageFault('position_mismatch',m.index,
          ('Stage %d physical position error %.2f deg; check gearing/travelDegrees'):format(m.index,errorDegrees),s.members[1].name)
      end
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
  uiMessage=message
  if uiActive then return end
  if message==lastDisplayMessage and os.clock()-lastDisplay<0.5 then return end
  lastDisplay=os.clock(); lastDisplayMessage=message
  term.clear(); term.setCursorPos(1,1)
  print('Three-stage bank controller v18'); print(message)
  if managed then print(('Master %d | grid %s V'):format(C.masterId,net.grid and ('%.3f'):format(net.grid.voltage) or '--')) end
  if managed then print('Control: '..(supervised() and 'supervised' or 'single')..' | '..joinState.stage) end
  print(('Recovery attempts used: %d / 3'):format(retries))
  print(('Target %.3f V | preferred +/-%.3f V'):format(C.target,tol))
  print(('Fallback +/-%.3f V | step-up x%.4g'):format(fallback,C.stepUp))
  if latest then print(('Input %.3f V | Final output %.3f V'):format(latest[1],latest[2])) end
  print(('Variac input minimum: %.3f V'):format(minimumGeneratorVolts))
  print(('Entry primary:secondary %.4g:1 | exit x%.4g'):format(C.entryRatio,C.stepUp))
  if C.sourceCurrentTripAmps>0 then print(('Source current trip: %.3f A'):format(C.sourceCurrentTripAmps)) end
  if C.sourceGauge~='' or C.preStepUpGauge~='' then
    local readings=voltageMeasurements()
    for _,key in ipairs({'source','preStepUp'}) do
      local sample=readings[key]
      if sample.configured then print((key=='source' and 'Before entry: ' or 'Before exit: ')..
        (sample.available and ('%.3f V'):format(sample.volts) or 'unavailable')) end
    end
    for _,spec in ipairs({{'Entry','source','input',C.entryRatio},{'Exit','output','preStepUp',C.stepUp}}) do
      local a,b=readings[spec[2]],readings[spec[3]]
      if a.available and b.available and a.volts>1 and b.volts>1 then
        local result=ratioCheck(spec[4],a.volts/b.volts)
        if result.available then
          print(('%s ratio %.3f / %.3f: %+.2f%% %s'):format(spec[1],result.measured,result.configured,
            result.deviationPercent,result.withinTolerance and 'OK' or 'CHECK'))
        end
      end
    end
  end
  for _,meter in ipairs({
    {C.sourceCurrentGauge,'current','amps','Source current: ',' A'},
    {C.sourcePowerGauge,'power','watts','Source power: ',' W'},
  }) do
    local sample=sourceMeter(meter[1],meter[2],meter[3])
    if sample.configured then print(meter[4]..(sample.available and ('%.3f'):format(sample[meter[3]])..meter[5] or 'unavailable')) end
  end
  if C.protectionMode=='current' and stageCurrentEnabled() then
    local estimate=stageCurrentEstimate()
    if estimate.available then
      print(('Stage cap %.1f A each | source <=%.3f A (stage %d)')
        :format(C.perVariacTripAmps,estimate.effectiveSourceLimitAmps,estimate.limitingStage))
    else print('Stage current estimate: unavailable') end
  end
  local temperatures=thermalStatus()
  if temperatures.enabled then
    print(('Thermal curve: 126/130/135 C = %.2f/%.2f/%.2fs; hard trip 140 C')
      :format(C.thermalGraceSeconds,C.thermalGraceSeconds*.4,C.thermalGraceSeconds*.1))
    for _,member in ipairs(temperatures.members or {}) do
      print(('%s: %s'):format(member.member,member.available and ('%.1f C | budget %.0f%% | credits used %d/3'):format(member.temperatureC,
        math.max(0,1-(member.exposure or 0))*100,
        ((member.recoveryUsed or {})['126'] and 1 or 0)+((member.recoveryUsed or {})['130'] and 1 or 0)+((member.recoveryUsed or {})['135'] and 1 or 0)) or 'temperature unavailable'))
    end
  end
  for i=1,3 do
    local s=snapshot(i)
    print(('Stage %s (%d): %.2f%% | ratio %.5f'):format(string.char(64+i),#s.members,s.position*100,s.ratio))
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
    local closeBand=supervised() and math.min(fallback,C.joinToleranceVolts) or fallback
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
    if not supervised() or math.abs(readV(2)-joiningTarget())<=C.joinToleranceVolts then break end
    assert(os.clock()-start<90,'Grid kept moving; could not match before close')
  until false
  assert(breakerState(1).canClose and breakerState(2).canClose,'Breaker charge lost before close')
  phase='closing'
  -- Calls are sequential, never claimed to be an atomic two-pole operation.
  local function closePole(i)
    guard()
    if supervised() and math.abs(readV(2)-joiningTarget())>C.joinToleranceVolts then
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
  do
    joinState={stage=supervised() and 'settling' or 'ramping',target=C.target,since=os.clock(),lastTick=os.clock()}
  end
  phase='live'; pause(0.25)
end
local function initialise()
  breakers[1]=wrap(C.plusBreaker,{'getStatus','open','close','isClosed','setTripCurrent'})
  breakers[2]=wrap(C.minusBreaker,{'getStatus','open','close','isClosed','setTripCurrent'})
  openBoth()
  loadOperation(); loadMaintenance()
  if maintenanceRequested then error(MAINTENANCE_PREFIX..'Saved maintenance state',0) end
  gauges[1]=wrap(C.inputGauge,{'voltage'}); gauges[2]=wrap(C.outputGauge,{'voltage'})
  for i,key in ipairs({'A','B','C'}) do
    bankMoving[i]=true
    variacs[i]={}
    for j,name in ipairs(C['variacs'..key]) do variacs[i][j]=wrap(name,{'getStatus'}) end
    gears[i]=wrap(C['gear'..key],{'rotate','isRunning'})
  end
  thermalPoll(true)
  if C.breakerTripAmps>0 then
    for i=1,2 do breakers[i].setTripCurrent(C.breakerTripAmps) end
  end
end
local function advanceJoin()
  local now=os.clock()
  local output=readV(2)
  local a,b=breakerState(1),breakerState(2)
  local current=math.max(math.abs(a.current),math.abs(b.current))
  if C.autonomousFallback and not supervised() and joinState.stage=='settling' then
    joinState.stage='ramping'; joinState.lastTick=now
  end
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
  local goal=desiredTarget()
  if joinState.stage=='nominal' and math.abs(joinState.target-goal)>.001 then
    joinState.stage='ramping'; joinState.lastTick=now
  end
  if joinState.stage=='ramping' then
    local dt=math.max(0,now-joinState.lastTick)
    joinState.lastTick=now
    -- Wait for each electrical adjustment to catch up before moving the goal.
    if math.abs(output-joinState.target)<=fallback then
      local step=math.min(C.maxRampStepVolts,C.rampVoltsPerSecond*dt)
      local delta=goal-joinState.target
      joinState.target=joinState.target+clamp(delta,-step,step)
      if math.abs(joinState.target-goal)<0.001 then
        joinState.target=goal; joinState.stage='nominal'
      end
    end
  end
  return false
end
local function run()
  -- Remove input supply before sampling, waiting for a master, or homing.
  local opened,why=isolateAll(); assert(opened,why)
  loadMaintenance()
  if maintenanceRequested then
    phase='maintenance'
    isolateAll()
    while maintenanceRequested do
      maintainIsolation(); sleep(.25)
    end
  end
  if (managed or uiActive) and faultLatched then
    phase='fault'
    while not net.reset do
      if maintenanceRequested then error(MAINTENANCE_PREFIX..'Requested',0) end
      sleep(0.1)
    end
    faultLatched=nil; net.reset=false; retries=0; bankSyncAttempts={}; net.enabled=false
    log('Master explicitly reset latched fault; fresh enable required')
  end
  initialise()
  if managed then
    phase='standby'
    while true do
      if maintenanceRequested then error(MAINTENANCE_PREFIX..'Requested',0) end
      if faultLatched and net.reset then
        faultLatched=nil; net.reset=false; retries=0; bankSyncAttempts={}
        log('Master explicitly reset latched fault')
      end
      local ready=networkReady()
      if not faultLatched and ready then break end
      if breakerState(1).closed or breakerState(2).closed then openBoth() end
      if not uiActive then
      term.clear(); term.setCursorPos(1,1)
      print('Three-stage bank controller v18: STANDBY')
      print(faultLatched or select(2,networkReady()) or 'Waiting for master')
      print('Q: quit | explicit enable required when disabled')
      end
      sleep(0.1)
    end
  end
  phase='homing'
  local isolated,reason=isolateAll(); assert(isolated,reason)
  selectTarget(true); guard()
  log(('START v18 target %.2f step-up %.5f; generator minimum %.3f V'):format(C.target,C.stepUp,minimumGeneratorVolts))
  for i=1,3 do
    -- A sequence interrupted by a trip may still be physically running.
    if bankNeedsSync[i] then syncBank(i) else idle(i); settled(i) end
    if not directions[i] then
      display('Checking shaft direction '..i); discoverDirection(i)
    end
  end
  energizeInputs()
  phase='setup'; guard()
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
if command=='maintenance' then
  assert(#C.inputBreakers>0,'Configure input breakers first')
  saveMaintenance(true)
  local ok,reason=isolateAll(); assert(ok,reason)
  print('Maintenance saved; input and output breakers verified open.')
  print('Run the controller UI to inspect and resume locally.')
  return
end
if command=='enable' or command=='disable' then
  openBoth()
  assert(managed and C.autonomousFallback,'Local enable/disable state is for autonomous supervised installations')
  setOperation(command=='enable')
  print('Saved '..command..'; breakers remain open. Run the program to regulate.')
  return
end
if command=='reset_thermal' then
  -- A reset never connects or moves hardware, and it cannot clear a hot fault.
  local opened,reason=pcall(openBoth)
  assert(opened,'Cannot reset with unverified breakers: '..tostring(reason))
  assert(thermalEnabled(),'Select temperature protection in configure first')
  local ok,err=thermalReset(); assert(ok,err)
  print('Thermal fault cleared; all variacs have fresh readings at or below 125 C.')
  print('Both breakers remain open. Start run when ready.')
  return
end
if command=='status' then
  -- Read only: no movement, breaker operations or protection setting changes.
  print(('Entry primary:secondary %.4g:1 | exit voltage x%.4g'):format(C.entryRatio,C.stepUp))
  local names={C.inputGauge,C.outputGauge,C.plusBreaker,C.minusBreaker}
  for _,key in ipairs({'sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge'}) do if C[key]~='' then names[#names+1]=C[key] end end
  for _,key in ipairs({'A','B','C'}) do
    for _,name in ipairs(C['variacs'..key]) do names[#names+1]=name end
    names[#names+1]=C['gear'..key]
  end
  for _,name in ipairs(names) do
    print(name)
    local ok,result=pcall(function()
      local p=assert(peripheral.wrap(name),'Missing')
      if p.getStatus then
        local state=p.getStatus()
        if p.getThermalStatus then
          local ok,value=pcall(p.getThermalStatus)
          state.thermal=ok and value or {available=false,reason=tostring(value)}
        end
        return state
      end
      if p.voltage then return {voltage=p.voltage()} end
      if p.current then return {amps=p.current()} end
      if p.power then return {watts=p.power()} end
      if p.getValue then return {value=p.getValue()} end
      return {running=p.isRunning()}
    end)
    print(ok and textutils.serialize(result) or tostring(result))
  end
  return
end
local function keyboard()
  if uiActive then while true do sleep(1) end end
  while true do
    local event,value=os.pullEvent()
    if event=='char' and value:lower()=='q' then error('Stopped by user',0) end
  end
end
local function openNetwork()
  if not managed then return false end
  local ok=pcall(function()
    local modem=assert(peripheral.wrap(C.modem),'Ender modem unavailable')
    assert(type(modem.isWireless)=='function' and modem.isWireless()==true,'Ender/wireless modem required')
    if not rednet.isOpen(C.modem) then rednet.open(C.modem) end
  end)
  networkOpened=ok
  return ok
end
local function networkSend(message)
  if not managed or not networkOpened then return end
  message.schema=1; message.node=nodeId; message.session=session
  message.sentAt=os.epoch('utc')
  -- Link loss does not disable local protection. The lease expires separately.
  pcall(rednet.send,C.masterId,message,PROTOCOL)
end
local function statusMessage(requestSeq)
  local data={type='status',phase=phase,emergencyStopped=emergencyStopped,sparkGapVolts=7500,maintenance={active=maintenanceRequested,verified=maintenanceVerified,
    drivesIdle=maintenanceRequested and drivesIdle() or nil,reason=maintenanceFailure},inputBreakers={},nominalTarget=nominalTarget,target=C.target,
    connectionMode=C.connectionMode,deadBusVolts=C.deadBusVolts,
    remoteControl={temporaryTarget=true,targetToleranceVolts=C.fallbackVolts,minTarget=nominalTarget*(1-C.remoteTargetPercent/100),
      maxTarget=nominalTarget*(1+C.remoteTargetPercent/100),enabled=C.remoteTargetPercent>0},
    requestedTarget=desiredTarget(),transition=(supervised() and net.transition and net.transition.expiresAt>os.epoch('utc')) and net.transition or nil,
    configuredTarget=nominalTarget,currentTarget=C.target,requestSeq=requestSeq,
    protectionMode=C.protectionMode,thermal=thermalStatus(),
    autonomousFallback=C.autonomousFallback,controlMode=supervised() and 'supervised' or 'single',
    supervisionAvailable=supervised(),enabled=not maintenanceRequested and isEnabled(),fault=faultLatched,faultDetails=faultLatched and lastFault or nil,lastFault=lastFault,
    retries=retries,minimumGeneratorVolts=minimumGeneratorVolts,
    grid=net.grid,joinStage=joinState.stage,variacs={},stages={},breakers={},lastSeq=net.lastSeq,
    sourceCurrentTripAmps=C.sourceCurrentTripAmps,sourceCurrentProtectionEnabled=C.sourceCurrentTripAmps>0,
    entryRatio=C.entryRatio,stepUp=C.stepUp,minimumSourceVoltsEstimate=minimumGeneratorVolts*C.entryRatio,
    voltages=voltageMeasurements(),sourceMeters={
      current=sourceMeter(C.sourceCurrentGauge,'current','amps'),
      power=sourceMeter(C.sourcePowerGauge,'power','watts')}}
  for _,key in ipairs({'input','output','source','preStepUp'}) do
    local sample=data.voltages[key]
    if sample.available then data[key..'Voltage']=sample.volts end
  end
  -- Nominal expectations and observed ratios are diagnostic only. Voltage
  -- ratios alone cannot determine power losses or transformer efficiency.
  if data.sourceVoltage and finite(data.sourceVoltage/C.entryRatio) then data.entryExpectedVoltage=data.sourceVoltage/C.entryRatio end
  if data.preStepUpVoltage and finite(data.preStepUpVoltage*C.stepUp) then data.exitExpectedVoltage=data.preStepUpVoltage*C.stepUp end
  if data.sourceVoltage and data.sourceVoltage>1 and data.inputVoltage and data.inputVoltage>1 then
    data.entryMeasuredRatio=data.sourceVoltage/data.inputVoltage
  end
  if data.preStepUpVoltage and data.preStepUpVoltage>1 and data.outputVoltage and data.outputVoltage>1 then
    data.exitMeasuredRatio=data.outputVoltage/data.preStepUpVoltage
  end
  data.ratioChecks={entry=ratioCheck(C.entryRatio,data.entryMeasuredRatio),exit=ratioCheck(C.stepUp,data.exitMeasuredRatio)}
  if data.sourceMeters.current.available then data.sourceCurrentAmps=data.sourceMeters.current.amps end
  if data.sourceMeters.power.available then data.sourcePowerWatts=data.sourceMeters.power.watts end
  local source,current=data.voltages.source,data.sourceMeters.current
  -- This DC estimate is a magnitude; current orientation is still reported
  -- separately. Never substitute an estimate for the measured power field.
  if source.available and current.available
    and math.abs(source.sampledAt-current.sampledAt)<=250 then
    local estimate=source.volts*math.abs(current.amps)
    if finite(estimate) then data.sourcePowerEstimateWatts=estimate end
  end
  data.stageCurrentProtection=stageCurrentEstimate(data.voltages,data.sourceMeters.current)
  data.stageCurrentProtection.enforcing=C.protectionMode=='current' and stageCurrentEnabled() and (phase=='live' or phase=='closing')
  for i,key in ipairs({'A','B','C'}) do
    local stage={stage=i,name=key,gear=C['gear'..key],available=false,members={}}
    data.stages[i]=stage
    -- Preserve each readable member even if another member is unavailable.
    for j,name in ipairs(C['variacs'..key]) do
      local member={name=name,available=false}; stage.members[j]=member
      local ok,value=pcall(function() return variacs[i][j].getStatus() end)
      if ok and type(value)=='table' and finite(value.position) and value.position>=0 and value.position<=1 then
        member.available=true; member.position=value.position; member.degrees=value.position*C.travelDegrees
        if finite(value.ratio) then member.ratio=value.ratio end
        if finite(value.shaftSpeed) then member.shaftSpeed=value.shaftSpeed end
      end
    end
    local ok,value=pcall(snapshot,i)
    if ok then
      data.variacs[i]=value; stage.available=true
      stage.position=value.position; stage.degrees=value.position*C.travelDegrees; stage.ratio=value.ratio
    end
  end
  for _,name in ipairs(C.inputBreakers) do
    local ok,value=pcall(function() return peripheral.wrap(name).getStatus() end)
    data.inputBreakers[#data.inputBreakers+1]={name=name,available=ok,status=ok and value or nil}
  end
  for i=1,2 do local ok,value=pcall(breakerState,i); if ok then data.breakers[i]=value end end
  return data
end
local function uiAction(action)
  if action.kind=='emergency' then
    -- Latch in memory before any yielding peripheral call. Attempt EVERY
    -- contact even if a peripheral fails. Save before a peripheral call can
    -- yield; even a failed save must not prevent the opening attempts.
    emergencyStopped=true; maintenanceRequested=true; net.enabled=false
    local saved,reason=pcall(saveMaintenance,true)
    local errors={}
    local names={C.plusBreaker,C.minusBreaker}
    for _,name in ipairs(C.inputBreakers) do names[#names+1]=name end
    for _,name in ipairs(names) do
      local ok,reason=pcall(function() assert(peripheral.wrap(name),'Missing '..name).open() end)
      if not ok then errors[#errors+1]=tostring(reason) end
    end
    local opened,openError=isolateAll()
    if not saved then errors[#errors+1]='Cannot persist emergency stop: '..tostring(reason) end
    if not opened then errors[#errors+1]=tostring(openError) end
    uiMessage=#errors>0 and table.concat(errors,'; ') or 'EMERGENCY STOP latched. Local Resume resets.'
    return
  elseif action.kind=='maintenance' then
    assert(#C.inputBreakers>0,'Configure input breakers first')
    maintenanceRequested=true
    saveMaintenance(true)
    local opened,reason=isolateAll()
    setOperation(false)
    assert(opened,reason)
    uiMessage='Maintenance requested; waiting for drives to stop.'
  elseif action.kind=='resume' then
    if not maintenanceRequested and not faultLatched and isEnabled() then
      uiMessage='Transformer is already running.'
      return
    end
    local opened,reason=isolateAll(); assert(opened,reason)
    assert(drivesIdle(),'Wait for all gearshift sequences to finish')
    local cool,why=thermalReset(); assert(cool,why)
    emergencyStopped=false
    local saved,saveError=pcall(saveMaintenance,false)
    if not saved then emergencyStopped=true; maintenanceRequested=true; error(saveError,0) end
    setOperation(true); net.reset=true
    uiMessage='Local reset accepted; normal startup checks apply.'
  elseif action.kind=='setting' then
    local key=action.key; local old=C[key]
    assert(old~=nil and key~='version','Unknown/read-only setting')
    if key~='target' then
      assert(maintenanceRequested,'Enter maintenance before editing this setting')
      local opened,reason=isolateAll()
      assert(maintenanceRequested and opened and maintenanceVerified and drivesIdle(),reason or 'Verified maintenance required')
    end
    local value=action.value
    if type(old)=='number' then value=key=='target' and volts(value) or tonumber(value)
    elseif type(old)=='boolean' then assert(value=='true' or value=='false','Enter true or false'); value=value=='true'
    elseif type(old)=='table' then local list={} for name in value:gmatch('[^,%s]+') do list[#list+1]=name end; value=list end
    assert(value~=nil,'Invalid value')
    C[key]=value
    local valid,why=pcall(validate)
    if valid then valid=C.target/(C.stepUp*calibratedRatio(1)^3)+C.inputHeadroomVolts<C.maxInputVolts; why='Target exceeds configured input range' end
    if not valid then C[key]=old; error(why,0) end
    local saved={}; for k,v in pairs(C) do saved[k]=v end
    saved.target=key=='target' and value or nominalTarget
    local written,writeError=pcall(function()
      local f=assert(fs.open(PATH..'.tmp','w')); f.write(textutils.serializeJSON(saved)); f.close()
      if fs.exists(PATH) then fs.delete(PATH) end
      fs.move(PATH..'.tmp',PATH)
    end)
    C[key]=old
    assert(written,writeError)
    if key=='target' then nominalTarget=value; net.transition=nil; uiMessage='Target saved; ramping toward '..value..' V'
    else reloadRequested=true end
  end
end
if command=='resume' or command=='emergency' then
  if command=='resume' then loadMaintenance(); loadOperation() end
  uiAction({kind=command})
  print(uiMessage)
  print('Breakers remain open; run the controller to apply normal startup checks.')
  return
end
local function uiSnapshot()
  -- The screen needs a small display sample, not the complete network report
  -- (which also calculates protection estimates and rereads stage positions).
  local data={phase=phase,message=uiMessage,config={},stages={},breakers={},inputBreakers={},
    emergencyStopped=emergencyStopped,sparkGapVolts=7500,fault=faultLatched,
    maintenance={active=maintenanceRequested,verified=maintenanceVerified,reason=maintenanceFailure,
      drivesIdle=maintenanceRequested and drivesIdle() or nil},
    nominalTarget=nominalTarget,target=C.target,entryRatio=C.entryRatio,stepUp=C.stepUp,
    voltages=voltageMeasurements(),sourceMeters={
      current=sourceMeter(C.sourceCurrentGauge,'current','amps'),
      power=sourceMeter(C.sourcePowerGauge,'power','watts')}}
  for key,sample in pairs(data.voltages) do if sample.available then data[key..'Voltage']=sample.volts end end
  for k,v in pairs(C) do data.config[k]=v end
  data.config.target=nominalTarget
  for i,key in ipairs({'A','B','C'}) do
    local stage={stage=i,gear=C['gear'..key],members={}}; data.stages[i]=stage
    for j,name in ipairs(C['variacs'..key]) do
      local member={name=name,available=false}; stage.members[j]=member
      local ok,state=pcall(function() return peripheral.wrap(name).getStatus() end)
      if ok and type(state)=='table' and finite(state.position) then
        member.position=state.position; member.available=true
      end
      -- Protection owns live temperature polling. Never start a second live
      -- thermal scan merely to draw the same temperatures on screen.
      local t
      if thermalEnabled() and not maintenanceRequested then
        local sampledAt=thermalSampleTimes[name]
        local now=os.epoch('utc')/1000
        if sampledAt and now>=sampledAt and now-sampledAt<=C.thermalMaxAgeSeconds then t=thermalReadings[name] end
      else
        local good,value=pcall(function() return peripheral.wrap(name).getThermalStatus() end)
        if good then t=value end
      end
      if type(t)=='table' and t.available and finite(t.temperature) then member.temperature=t.temperature end
    end
  end
  for _,name in ipairs(C.inputBreakers) do
    local ok,value=pcall(function() return peripheral.wrap(name).getStatus() end)
    data.inputBreakers[#data.inputBreakers+1]={name=name,available=ok,status=ok and value or nil}
  end
  for i=1,2 do local ok,value=pcall(breakerState,i); if ok then data.breakers[i]=value end end
  return data
end
local function userInterface()
  if not uiActive then while true do sleep(1) end end
  local path=fs.combine(fs.getDir(shell.getRunningProgram()),'regulator_ui.lua')
  local ui=assert(loadfile(path),'Missing regulator_ui.lua beside controller')().new(term,colors)
  -- Never call peripherals in the navigation/render loop. CC peripheral calls
  -- may yield with a filtered event wait, discarding clicks for that coroutine.
  local cached={phase=phase,config={},stages={},inputBreakers={},breakers={},
    voltages={},sourceMeters={},maintenance={active=maintenanceRequested},message='Reading peripherals...'}
  for k,v in pairs(C) do cached.config[k]=v end
  for _,key in ipairs({'source','input','preStepUp','output'}) do cached.voltages[key]={available=false} end
  for _,key in ipairs({'current','power'}) do cached.sourceMeters[key]={available=false} end
  local updateEvent='regulator_ui_update'
  local function draw()
    cached.phase=phase; cached.message=uiMessage
    cached.emergencyStopped=emergencyStopped
    cached.maintenance.active=maintenanceRequested
    cached.config.target=nominalTarget
    ui.draw(cached)
  end
  local function input()
    draw()
    while true do
      local event={os.pullEvent()}
      local name=event[1]
      if name==updateEvent or name=='term_resize' or name=='mouse_click'
        or name=='mouse_scroll' or name=='char' or name=='key' or name=='paste' then
        local action=ui.event(table.unpack(event))
        if action then
          if action.kind=='stop' then error('Stopped by user',0) end
          local ok,reason=pcall(uiAction,action)
          if not ok then uiMessage=tostring(reason):gsub('^.-:%d+: ','') end
          if reloadRequested then error('RELOAD_CONFIG',0) end
        end
        draw()
      end
    end
  end
  local function sample()
    while true do
      local nextSnapshot=uiSnapshot()
      cached=nextSnapshot -- Publish only a complete set; never a partial sample.
      os.queueEvent(updateEvent)
      sleep(1)
    end
  end
  parallel.waitForAny(input,sample)
end
local function telemetry()
  while true do
    if managed then openNetwork(); networkSend(statusMessage()) end
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
        if maintenanceRequested and m.enabled then reason='Maintenance requires local resume'
        elseif type(m.enabled)~='boolean' then reason='enabled must be boolean'
        elseif not m.enabled then
          net.enabled=false; net.transition=nil; setOperation(false)
        elseif C.autonomousFallback and faultLatched then reason='Fault latched; disable and reset first'
        elseif m.autonomous==true then
          if not C.autonomousFallback then reason='Autonomous operation disabled locally'
          else setOperation(true); net.enabled=false; net.transition=nil end
        else
          local g=m.grid
          if type(g)~='table' or not finite(g.voltage) or g.voltage<0 or (g.voltage==0 and C.connectionMode~='supply') or type(g.healthy)~='boolean' or not finite(g.sampledAt) then
            reason='Grid voltage, healthy and sampledAt required'
          elseif os.epoch('utc')-g.sampledAt>C.gridMaxAgeSeconds*1000 or g.sampledAt-os.epoch('utc')>250 then reason='Stale grid sample'
          elseif m.runningTarget~=nil then reason='Use scoped transition targets; nominal target is locally configured'
          elseif m.transition~=nil and (C.remoteTargetPercent==0 or type(m.transition)~='table'
            or type(m.transition.id)~='string' or #m.transition.id==0 or #m.transition.id>80
            or not finite(m.transition.generator) or m.transition.generator<0 or m.transition.generator%1~=0
            or not finite(m.transition.targetVolts)
            or m.transition.targetVolts<nominalTarget*(1-C.remoteTargetPercent/100)
            or m.transition.targetVolts>nominalTarget*(1+C.remoteTargetPercent/100)
            or not finite(m.transition.expiresAt) or m.transition.expiresAt<=os.epoch('utc')
            or m.transition.expiresAt-os.epoch('utc')>30000) then reason='Temporary target not permitted or invalid'
          else
            -- Copy only the validated fields. One task owns all shaft commands.
            net.grid={voltage=g.voltage,healthy=g.healthy,sampledAt=g.sampledAt}
            local t=m.transition
            net.transition=t and {id=t.id,generator=t.generator,targetVolts=t.targetVolts,expiresAt=t.expiresAt,direction=t.direction} or nil
            setOperation(true); net.enabled=true
          end
        end
      elseif m.type=='release' then
        if not C.autonomousFallback then reason='Autonomous operation disabled locally'
        else net.enabled=false; net.transition=nil; net.lastSeen=-math.huge end
      elseif m.type=='reset' then
        if isEnabled() then reason='Disable before reset'
        else
          local resetOK,resetReason=thermalReset()
          if resetOK then net.reset=true else reason=resetReason end
        end
      elseif m.type~='get_status' then reason='Unknown message type' end
      if not reason then
        net.lastSeq=m.seq
        -- Only dispatch renews the command lease; status requests cannot keep
        -- an old enable command alive indefinitely.
        if m.type=='dispatch' then net.lastSeen=os.clock() end
      end
      networkSend({type='ack',seq=m.seq,accepted=not reason,reason=reason,
        note='Acceptance records intent; status reports actual contact state'})
      if not reason and m.type=='get_status' then networkSend(statusMessage(m.seq)) end
    end
  end
end
local function monitor()
  while true do
    if thermalEnabled() and phase~='initializing' and phase~='maintenance' then thermalPoll(not faultLatched) end
    if phase=='live' or phase=='homing' or (managed and (phase=='setup' or phase=='closing')) then guard() end
    sleep(0.05)
  end
end
local ok,err
if managed then
  local opened,openError=pcall(openBoth)
  if not opened then error('Cannot start managed mode with unverified breakers: '..tostring(openError),0) end
  rednet.close(); openNetwork()
end
while true do
  phase='initializing'; faultContext=nil
  -- CC cooperative tasks: every blocking peripheral/timer wait yields so the
  -- receiver and protection task continue during motor movement and searches.
  ok,err=pcall(function() parallel.waitForAny(run,keyboard,monitor,receiver,telemetry,userInterface) end)
  cancelThermalSampling()
  phase='stopping'
  local disconnected,disconnectError=isolateAll()
  if not disconnected then
    ok=false; err='Cannot verify both breakers open: '..tostring(disconnectError)
    break
  end
  local reason=tostring(err)
  if reason=='RELOAD_CONFIG' then reloadRequested=true; break end
  if ok or reason:find('Terminated',1,true) or reason=='Stopped by user' then break end
  if not reason:find(STANDBY_PREFIX,1,true) and not reason:find(MAINTENANCE_PREFIX,1,true) then
    lastFault=faultContext or {code='controller_fault',reason=reason}
    lastFault.sampledAt=os.epoch('utc')
  end
  if reason:find(MAINTENANCE_PREFIX,1,true) then
    log('Maintenance isolation requested')
  elseif managed and reason:find(STANDBY_PREFIX,1,true) then
    log('STANDBY: '..reason)
  elseif reason:sub(1,#BANK_SYNC_PREFIX)==BANK_SYNC_PREFIX
    and not bankSyncAttempts[tonumber(reason:match('^BANK_MISALIGNED: (%d+)'))] then
    local i=assert(tonumber(reason:match('^BANK_MISALIGNED: (%d+)')))
    bankSyncAttempts[i]=true; bankNeedsSync[i]=true
    log('BANK SYNC requested after verified disconnect: '..reason)
    networkSend({type='fault',reason=reason..'; disconnected, attempting minimum-endpoint bank sync',
      code=lastFault.code,stage=lastFault.stage,stageName=lastFault.stageName,member=lastFault.member,recoverable=true})
  elseif reason:find(RETRY_PREFIX,1,true) and retries<3 then
    retries=retries+1
    log(('RECOVERY %d/3: both open; use fresh stable readings, re-position, recharge'):format(retries))
  else
    if reason:find(RETRY_PREFIX,1,true) then reason='Recovery failed after 3 retries; '..reason end
    err=reason
    if not managed and not uiActive then break end
    faultLatched=reason; net.enabled=false; net.reset=false
    setOperation(false)
    log('LATCHED FAULT: '..reason)
    networkSend({type='fault',reason=reason,code=lastFault.code,stage=lastFault.stage,
      stageName=lastFault.stageName,member=lastFault.member,recoverable=false,
      peripheral=lastFault.peripheral,currentAmps=lastFault.currentAmps,limitAmps=lastFault.limitAmps,
      perVariacCurrentEstimate=lastFault.perVariacCurrentEstimate,perVariacLimitAmps=lastFault.perVariacLimitAmps,
      temperatureC=lastFault.temperatureC,temperatureSource=lastFault.temperatureSource,
      warningC=lastFault.warningC,tripC=lastFault.tripC,graceSeconds=lastFault.graceSeconds,
      exposure=lastFault.exposure,recoveryUsed=lastFault.recoveryUsed})
    -- Remain online for telemetry and explicit disable/reset/start commands.
  end
end
phase='stopping'
local opened,openError=isolateAll()
if managed and C.autonomousFallback then pcall(setOperation,false) end
local reason=ok and 'Stopped' or tostring(err)
print(reason); log('STOP: '..reason)
networkSend({type='stopped',reason=reason,breakersOpen=opened})
if opened then print('All configured breakers verified open. No automatic reclose.')
else printError('Could not open/verify both breakers: '..tostring(openError)) end
print('An in-progress gearshift sequence may finish after stopping.')
print('Log: '..LOG)

if reloadRequested then return shell.run(shell.getRunningProgram(),'run') end
