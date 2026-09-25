# Power plant regulator — setup (v18)

This package contains the three-variac controller and its rednet protocol. The previous v10 controller was reported checked with 29 simulated scenarios. v11 added peripheral discovery, shared-drive banks and fault-only bank synchronisation. v12 added entry/exit measurements and source metering. v13 added estimated per-variac current trips. v14 added live per-member temperature protection using the addon 1.2.0 API. v15 adds an inverse-time curve with one recovery credit per cooling level; these changes still need in-game testing. The monitor-based plant master is in [../controller](../controller/SETUP.md) and implements `PROTOCOL.txt`.

## Files

- `transformer_controller.lua` — controller with discovery-based configuration and monitored variac banks.
- `regulator_ui.lua` — concurrent local UI for an advanced computer; no monitor required.
- `thermal_protection.lua` — required temperature policy module; install beside the controller.
- `startup_optional.lua` — optional boot launcher. It does not run automatically under this name.
- `PROTOCOL.txt` — message schema, timestamps, session/sequence handling, telemetry, enable/disable and fault reset.
- `SETUP.md` — these instructions.

## Electrical layout

Generator → optional source voltage/current/power meters → optional entry transformer → input gauge → variac A → variac B → variac C → optional pre-exit voltage gauge → fixed exit step-up → output gauge → plus/minus breakers → grid.

Both gauges measure across the appropriate circuit terminals, not across the length of a wire. The output gauge must be after the output transformer and on the transformer side of BOTH breakers, so it remains readable while disconnected. For managed joining, the master needs a separate grid-side measurement that remains live when this unit is disconnected.

For the approximately 7.14–7.25 kV generator discussed, use the input 5:1 step-down before the input gauge (200 primary / 40 secondary turns, if using the 240-turn allowance). The output transformer remains 2.5× step-up (68 primary / 170 secondary). Configure `entryRatio=5` for that entry step-down: it means primary/secondary voltage, so the expected post-entry voltage is source voltage / 5. The existing `stepUp=2.5` setting still describes only the exit transformer. Enter `5`, `5:1`, or `200:40` at the entry-ratio prompt. Older configurations migrate to `entryRatio=1` (no assumed conversion); configure your actual ratio explicitly.

These ratios address voltage, not the current capacity of the variacs or transformers. Each of the three series stages can contain one or more parallel variacs driven by ONE shared sequenced gearshift. Every configured member is monitored for actual position. The first selected member supplies the stage position used by the voltage planner; additional parallel members do not multiply the voltage ratio. Current sharing still requires experimental verification: the variac API does not expose per-member current.

## Peripheral map

| Role | Peripheral |
|---|---|
| Generator-side input, after any input step-down | `powergrid_voltage_gauge_6` |
| Variac A | `powergrid:variac_1` |
| Drive A | `Create_SequencedGearshift_4` |
| Variac B | `powergrid:variac_2` |
| Drive B | `Create_SequencedGearshift_5` |
| Variac C | `powergrid:variac_4` |
| Drive C | `Create_SequencedGearshift_6` |
| Final output, before breakers | `powergrid_voltage_gauge_7` |
| Plus breaker | `powergrid:hv_breaker_2` |
| Minus breaker | `powergrid:hv_breaker_3` |
| Rednet modem | `back` by default |

Enable peripheral sharing on the wired modems. All three drives need independent shaft control. Breaker mechanisms must have mechanical charging available. Remove conflicting old controller programs or redstone pulse controls before testing the direct breaker API.

## Installation

1. Extract the ZIP on your PC. Put `transformer_controller.lua` in the in-game computer's root directory using your existing file-transfer method. CC does not need to extract the ZIP itself.
2. Stop the older controller before replacing its file. Keep a backup of your in-game configuration if you have customised it.
3. Inspect the peripherals without changing hardware:

   ```lua
   transformer_controller.lua status
   ```

4. Configure (discovery reads peripheral methods without operating hardware):

   ```lua
   transformer_controller.lua configure
   ```

   The wizard lists all visible peripherals and offers compatible choices for each role. Select by number or peripheral name; for a stage bank, enter multiple choices separated by commas. Assign the input/output gauges, each stage’s variac members and single gearshift, plus/minus breakers, and modem, then any optional source/pre-exit voltage and source current/power gauges. Enter keeps the displayed selection only if its members are available and unused. A component cannot belong to two roles or stages. In standalone mode, `-` skips modem assignment. Enable wired peripheral sharing before configuration.

5. Keep the nominal target at **2640 V** and the output multiplier at **2.5**. Defaults aim for ±0.1 V with a ±1 V fallback. Exact accuracy depends on actuator resolution and source/load stability.
6. Choose the master mode described below, then start:

   ```lua
   transformer_controller.lua run
   ```

The saved configuration is `dual-variac-config.json` for compatibility with older versions, despite there now being three stages. Configuration versions 7–17 are accepted and migrated in memory; `configure` saves version 18. Old single-variac mappings become one-member banks. New `variacsA`, `variacsB`, and `variacsC` lists store all members, and legacy `variacA/B/C` names mirror each bank’s first member. Version 7 peripheral mappings are migrated to the three-stage mapping above. An old default 8° coarse limit is upgraded to direct full-travel correction. Custom coarse limits are retained.

## Standalone mode

Set master ID to **-1**. The controller opens all configured input and output breakers, verifies alignment within every bank, checks each shaft direction with a small movement, positions from actual readback and measured output, then connects and regulates directly to the configured nominal target. There is no routine homing rotation. A detected bank misalignment uses the fault-only recovery below.

Standalone mode has no independent grid-voltage information and does NOT perform managed grid matching. Use managed mode when joining an already energised grid.

## Managed mode

Set master ID to the actual plant-master computer ID and modem to its actual peripheral name. The node starts disconnected and awaits valid dispatch messages. Use:

```lua
transformer_controller.lua protocol
```

or read `PROTOCOL.txt` for integration details. Protocol: `powerplant.regulator.v1`.

The master learns this node's ID and boot session from periodic status, then sends fresh enabled/disabled dispatches about every 0.5 seconds with increasing sequence numbers. Enabled dispatches include actual grid voltage, health and the measurement timestamp. A send acknowledgement is not proof that contacts closed; inspect both breaker statuses.

When enabled onto a healthy grid, the controller:

1. Matches the reported grid voltage, for example 2625 V, within the configured join tolerance (default ±1 V).
2. Rechecks matching immediately before closing each breaker.
3. Holds shaft positions during natural electrical sharing until voltage/current changes settle for 3 seconds by default.
4. Ramps its temporary regulation setpoint toward the unchanged nominal 2640 V target, default up to 1 V/s and 1 V per update, waiting for output to follow.
5. Continues regulating at nominal voltage.

This is a SETPOINT ramp, not a guaranteed physical voltage slew limit. Discrete movements and the connected grid affect actual voltage. Normal fine moves use 1°; a coordinated search up to 16° may rebalance stages if a local fine setting cannot improve the error. Protection remains active during settling, movement and searches.

The master decides grid health and which generators are enabled. This node does not implement a separate current-sharing algorithm. Managed mode requires a live grid and does not automatically black-start a dead grid. Master OFF opens the output breakers; it cannot stop the generator's shaft or excitation because no actuator for that is configured.

## Interface for the future master

A master program is still not included. The node sends periodic status and answers an accepted `get_status` request immediately, with `requestSeq` matching the request sequence. Use the existing session, sender and sequence envelope in `PROTOCOL.txt`; reading status does not renew an enable lease.

Status includes transformer input/output voltages from the existing gauges, all three stage positions and every bank member, `configuredTarget` (nominal) and `currentTarget` (temporary matching/ramp target). The older `inputVoltage`, `outputVoltage`, `nominalTarget`, `target`, and `variacs` fields remain available. `voltages` and `stages` add peripheral names and explicit availability. These readings describe the whole transformer assembly. The master still needs its own independent grid-side measurement.

Stage faults report numeric `stage` (1=A, 2=B, 3=C), `stageName`, a machine-readable `code`, and a member name when known. `variac_stuck` reports failure to move or reach the minimum endpoint. Other motion failures use `drive_timeout`, `position_unstable`, or `position_mismatch`. `lastFault` preserves the latest fault for later status requests, while `faultDetails` accompanies a currently latched fault. Inspect actual breaker statuses to establish whether the transformer is connected.

## Optional measurements and ratio checks

| Reading | Placement | Configuration |
|---|---|---|
| Source voltage | Before entry transformer | `sourceGauge` (optional) |
| Variac input voltage | After entry transformer, before stage A | `inputGauge` (required, existing) |
| Pre-exit voltage | After stage C, before exit transformer | `preStepUpGauge` (optional) |
| Final output voltage | After exit transformer, before both breakers | `outputGauge` (required, existing) |
| Source current | Before entry transformer, total assembly feed | `sourceCurrentGauge` (optional) |
| Source power | Same source-side measurement boundary | `sourcePowerGauge` (optional) |

Assign the actual new peripheral names through discovery; no names are assumed. Enter leaves an unassigned optional meter disabled; `-` removes an assignment. Current/power discovery accepts `current()`/`power()` or a generic `getValue()` reader. With a generic reader, select the correct physical meter returning amps or watts. Optional missing/invalid readings are marked unavailable and retried on later samples, without substituting calculated values for measured control voltages. Source voltage/current gauges and a configured pre-exit gauge become required during connection when estimated stage-current protection is enabled. The source current gauge is also required whenever the fixed source-current trip is enabled.

`ratioChecks.entry` compares source/input voltage against `entryRatio`; `ratioChecks.exit` compares output/pre-exit voltage against `stepUp`. Both readings must exceed 1 V. The default diagnostic tolerance is 2%, configurable as `ratioTolerancePercent`. A mismatch does not automatically trip: load sag and sequential sampling can also cause a difference. The entry ratio never scales the already measured variac input a second time. The calculated input-voltage floor stays on the post-entry side; `minimumSourceVoltsEstimate` is an ideal source-side estimate including the configured entry ratio.

For this DC network, the source voltage and current gauges are sufficient to estimate input power. `sourcePowerEstimateWatts` is voltage × absolute current when their samples are within 250 ms. The dedicated power gauge is optional and reports a separate `sourcePowerWatts` measurement. No stale/missing reading is replaced by zero. Source meters alone do not establish the assembly's efficiency; that also requires output power.

## Source current protection

Set `sourceCurrentTripAmps` to the desired absolute source-current limit in amps. The default `0` disables this additional fixed source limit. The separate per-variac estimate below can still enforce a calculated limit in legacy current mode. A positive value requires `sourceCurrentGauge`. Exceeding the limit, or losing a valid reading from that gauge, opens both output breakers and latches the fault. Managed mode requires disable/reset/fresh enable; these faults do not trigger automatic reclosure. Existing native breaker protection remains independent.

The source gauge measures total current before the entry transformer. Current can be higher after voltage reduction and in later stages; this setting does not establish individual stage or branch current limits. Choose the threshold for the tested installation. Opening downstream output breakers sheds the load but does not de-energise the transformer input. Software polling cannot guarantee that a transient is caught before hardware damage.

## Live temperature protection (v15)

Install both `transformer_controller.lua` and `thermal_protection.lua` together. The default `protectionMode="temperature"` requires addon **1.2.0** with working `getThermalStatus()` on every selected variac. This also applies to migrated configurations without an explicit protection mode: update the server addon and restart before running. No inferred or ambient temperature substitutes for an unavailable reading.

- Every variac in all three banks is monitored, including additional members sharing a drive.
- The full allowance is **5 seconds at 126°C**, **2 seconds at 130°C**, and **0.5 seconds at 135°C**, tapering to zero at 140°C. Between points, interpolate the allowed duration linearly; between 125°C and 126°C use five seconds.
- Each member accumulates exposure: elapsed time divided by the allowance at its last sampled temperature. At 100% exposure, open both breakers and latch `thermal_hot_timeout`. Changing temperature retains accumulated exposure. For example, one second at 130°C consumes 50%; moving to 135°C leaves 0.25 seconds.
- Cooling through **135°C, 130°C or 126°C** can return **half the full allowance once at each level per episode**, capped at a full budget. Credits are tracked separately per member. A level arms after reaching at least 0.25°C above it; the reading must then cross downward through it and remain non-increasing for 0.25 seconds. Warming cancels confirmation. Skipping multiple levels grants only the reached level's credit, never stacked credits. An expired allowance cannot be revived.
- At **125°C or below**, exposure stops growing. Exposure and all recovery credits reset only after **five continuous seconds** of valid cool readings (`thermalCoolSeconds`). A brief cool dip or explicit fault reset does not replenish credits. Cooling alone never clears a latched fault.
- `thermalGraceSeconds` scales the whole curve: it sets the 126°C allowance, with 130°C at 40% and 135°C at 10%. Existing settings migrate with these semantics.
- At **140°C or above**, trip on the first reading, with no grace period.
- Missing, invalid, initializing, disabled or stale readings latch a fault and prevent connection. The maximum sample age defaults to one second (`thermalMaxAgeSeconds`). Monitoring runs at a nominal 50 ms interval; peripheral/server delays affect actual response time.

Temperature mode replaces the estimated per-variac 29 A trip. The independent fixed source-current limit, native breaker protection and voltage protection remain active as configured. `configure` offers explicit legacy `current` mode, which does not monitor temperature. The native `overheated` flag is diagnostic; the controller uses its own lower 140°C threshold.

Faults, exposure, used/armed credits and accounting timestamps are saved in `transformer-thermal-state.json` in the working directory, with `.tmp`/`.bak` recovery files. Restarting the controller does not clear a fault or grant another hot grace interval. The last accounting temperature charges unobserved elapsed time at its previous rate; it is never marked as a live reading. Restarting cancels pending recovery and cooling confirmations. v14 checkpoints migrate without dropping elapsed hot time. Keep this state file when updating the program; an unreadable checkpoint prevents normal operation.

Reset requires fresh readings at **125°C or below from every member**. In managed mode, disable, send `reset`, then send a fresh enable command after reset succeeds. In standalone mode, run:

```text
transformer_controller.lua reset_thermal
```

The local command verifies both breakers open, checks all temperatures, clears the thermal checkpoint fault while preserving episode exposure/credits, and leaves the breakers open without moving shafts. Then run the controller explicitly. This command also permits recovery from a damaged checkpoint after validating fresh, cool readings. `status` remains read-only and displays native thermal availability. Managed fault telemetry identifies the affected stage and peripheral; see `PROTOCOL.txt`.

## Source-verified thermal analysis

See [THERMAL_MODEL.md](THERMAL_MODEL.md) for the inspected Power Grid 0.6.2 implementation, exact loss/tick equations, the initial-construction versus refresh discrepancy, and a numerical comparison with the tests. Under those defaults, smoke begins at 125°C and overheating at 175°C: the 124.9°C observations below describe the smoke boundary, not the destruction threshold. Installed server settings remain unverified. v15 uses native measured temperatures for protection; this analysis is retained for reference, not used to calculate trip temperatures.

## Observed per-variac test points

The user reported these measurements and confirmed the third point was just below overheating after waiting for it to stabilize. Its elapsed test duration was not specified. The user later confirmed 124.9°C for the third point and the fourth measurement below. All reported thermal tests used maximum arm position (position 1, nominal ratio 1:1); this confirms the test position, not a separate primary-side current measurement.

| Measured voltage | Measured current | Voltage × current | Temperature | Reported context |
|---|---|---|---|---|
| 2794.067626953125 V | 30.973 A | 86.541 kW | Not reported | Reported maximum-current point |
| 981.9259033203125 V | 93.303 A | 91.617 kW | Not reported | Reported point before overheating |
| 1985.8565673828125 V | 72.945 A | 144.858 kW | 124.9°C | Just below overheating after stabilization |
| 2793.994873046875 V | 30.864 A | 86.234 kW | 124.9°C | Repeat high-voltage measurement |

The first two powers differ by approximately 5.87%, which initially suggested a roughly constant-power thermal boundary. The third point is 58.11% above the second in power. The third point was confirmed as a stabilized near-overheating observation. A single constant-power boundary does not fit all three points; consistency of other test conditions still needs checking. Do not infer a thermal curve or continuous rating without accounting for test duration, initial temperature, loading and installed mod behavior.

The chosen reference of 2794.423583984375 V × 29 A is 81.038 kW. A hypothetical constant-power cap at that value would permit approximately 82.530 A at 981.9259033203125 V and 40.808 A at 1985.8565673828125 V. That model has not been adopted or validated. v15 uses measured temperature by default; the fixed 29 A estimate below remains available in legacy current mode.

### Candidate combined voltage/current fit

Fitting only the first two points to `a * V^2 + b * I^2 = 1` gives:

```text
a = 1.1555019983031357e-7
b = 0.00010207272496019205
I_boundary(V) = sqrt((1 - a * V^2) / b)
```

This predicts **73.0247 A at 1985.8565673828125 V**, compared with the independently reported **72.945 A**: a difference of approximately **0.109%**. That agreement makes a combined squared-voltage/squared-current model worth further testing, rather than a constant-power limit. This is an empirical fit to the supplied measurements. The later upstream 0.6.2 source analysis in [THERMAL_MODEL.md](THERMAL_MODEL.md) explains it using actual internal branch losses; the installed server implementation remains unverified. Do not extrapolate its intercepts into voltage/current ratings or change the existing input-voltage ceiling.

The two points explicitly confirmed at **124.9°C** (1985.8565673828125 V / 72.945 A and 2793.994873046875 V / 30.864 A) provide an equal-temperature fit:

```text
a = 1.1562378343259862e-7
b = 0.00010224126367015651
a * V^2 + b * I^2 = 1  (empirical 124.9°C contour)
```

It predicts **93.2223 A at 981.9259033203125 V**, close to the earlier 93.303 A point whose exact temperature was not reported. Different transmitted powers (86.234 kW and 144.858 kW) at the same reported temperature strengthen the combined voltage/current interpretation. This equation describes one temperature contour; it does not establish temperature at arbitrary voltage/current, transient heating, or a continuous operating rating.

A useful additional point is approximately **1500 V**, where the equal-temperature fit predicts **85.066 A at 124.9°C**. Keep the same variac, tap position and test arrangement where possible, wait for stabilization, and record input voltage, tap-to-common output voltage, current, temperature and position. These proposed measurements are research only; v15 protection uses the native live temperature API.

### Documentation supplied by the user

The user supplied the [Power Grid Variac wiki](https://powergrid.martatrovisco.dev/index.php?title=Variac) text. It describes a transformer T-equivalent circuit with primary stray, magnetizing, ideal-coupling and secondary stray branches, with heat generated from dissipated electrical losses. The supplied property table does not give a maximum sustained power. Live retrieval of the wiki was unavailable during the initial review. Upstream 0.6.2 source has since been inspected (see [THERMAL_MODEL.md](THERMAL_MODEL.md)); no installed server JAR/config is available here to confirm a match.

This description is consistent with the empirical squared-voltage/squared-current contour: resistive branch heating is proportional to branch-current squared, and a resistive magnetizing component can contribute a voltage-squared term. It does not establish the fitted coefficients as the mod's exact thermal formula. Transmitted load power is distinct from dissipated heat.

The relevant voltage/current are those in the actual internal branches. The primary/common voltage may differ substantially from tap/common voltage at reduced arm position, and primary current need not equal tap load current. The user confirmed that all thermal tests used maximum position. The fitted contour is therefore calibrated near 1:1 only and cannot yet be applied universally to all three stages at arbitrary ratios. In particular, substituting a reduced tap voltage into the voltage-squared term could underestimate primary-side heating and incorrectly increase the allowed current. A useful next comparison is the same primary voltage at approximately half arm position, recording primary/common voltage, tap/common voltage, source current, load current and stabilized temperature. Half arm position has a nominal ratio of 0.505 under the supplied position/ratio API, not exactly 0.5. Record actual readings rather than assuming ideal conversion. Continue detecting gearshift direction at startup: the wiki's shaft RPM sign is not proof of a particular gearshift command modifier in the installed drivetrain.

## Legacy per-variac 29 A cap (`protectionMode="current"`)

The user's observed point was 2794.067626953125 V at 30.973 A per variac. The chosen operating reference is **29 A at 2794.423583984375 V per variac**. In legacy current mode, keep `perVariacTripAmps=29`: this stays a current cap at lower voltage, not an 81.038 kW constant-power rating. The existing input-voltage ceiling remains independent.

In `protectionMode="current"`, estimated stage-current protection enables when both `sourceGauge` and `sourceCurrentGauge` are assigned and the per-variac limit is positive. Existing configurations without both gauges continue operating without this estimate; assign them through `configure` to enable it. Set `perVariacTripAmps=0` to explicitly disable it. Since v14, missing `protectionMode` defaults to `temperature`, including migrated configurations. Select `current` explicitly to retain the v13 stage-current policy. Temperature mode reports available current estimates for diagnostics without enforcing this estimated 29 A cap.

For each stage, calculate:

```text
bank current estimate = source voltage × |source current| / estimated stage output voltage
per-variac current estimate = bank current estimate / parallel member count
source-current ceiling = 29 × parallel member count × estimated stage output voltage / source voltage
```

All three stages are checked; the lowest source-current ceiling wins. Any lower configured fixed source-current limit also applies. At 1056 V and a 7200 V source:

| Parallel variacs in the limiting stage | Bank current cap | Equivalent source-current ceiling |
|---|---|---|
| 1 | 29 A | 4.253 A |
| 2 | 58 A | 8.507 A |
| 3 | 87 A | 12.760 A |

The controller estimates stage voltages from actual positions and the existing calibration. Measured pre-exit voltage reduces those estimates when there is voltage sag. Without a pre-exit gauge, final output divided by the configured exit multiplier provides that anchor. High voltage samples never raise the limit above the calibrated prediction. The entry ratio is not applied again to an already measured post-entry voltage.

The model enforces while closing and connected, including live shaft movement. Exceeding the calculated limit latches both breakers open and reports `stage_overcurrent_estimate` with the stage number and estimated per-variac current. Missing/stale model readings while enforcing latch with `stage_current_unavailable`. With both breakers open, excitation/loss current is not amplified into fictitious load current during startup or bank synchronisation; the separate fixed source limit still applies.

This estimate assumes forward source-to-load power and equal sharing between the configured parallel members. It cannot prove each winding/branch is below 29 A or detect every circulating current. Bank sharing still needs in-game verification; individual branch current measurements would be needed to enforce individual measured branch limits.

## Protection and recovery

- Grid samples expire after 2 seconds; the enabled dispatch lease expires after 3 seconds. Missing, stale or unhealthy grid information opens both breakers and waits for fresh healthy enable dispatches.
- Input below the calculated minimum opens both breakers. At 2640 V with 2.5× step-up the calibration gives approximately 1056.032 V before additional losses; `inputHeadroomVolts` can raise the threshold. The threshold follows the temporary matching/ramp target while joining.
- Default input ceiling: 2800 V, based on the user's observed variac limit. Breakers are downstream and cannot isolate variacs from excessive input voltage or prevent no-load overheating.
- Default output-overvoltage trip: 10% above the current active setpoint. It is separate from the regulation accuracy band.
- Native breaker overcurrent settings remain in effect. `breakerTripAmps=0` means PRESERVE existing settings, not disable protection. If the native setting is already Off, this option leaves it Off.
- Overvoltage/close failures allow three retries after the initial failure. Both contacts are opened and output is retuned from fresh stable readings before reclosing. Fault spikes are never retained as a model correction factor.
- Bank position spread beyond `positionToleranceDegrees` (default 1°) opens and verifies all configured input and output breakers. Alignment checks remain active during energized shaft movement. Startup verifies each bank before closing any input pole. Automatic endpoint synchronization requires configured input isolation breakers; without them it faults with `bank_sync_requires_input_isolation` and does not move the bank. With input and output contacts verified open, the controller waits for existing motion, detects the shared drive direction, then commands full travel plus 3° toward minimum. Zero post-entry voltage is expected during isolated homing and does not block it. All members must settle within 0.1° of minimum before retuning, charging and reconnecting; managed mode performs grid matching again. This is limited to one synchronisation attempt per bank per run/explicit reset. An interrupted attempt is not automatically repeated, and failed or repeated misalignment leaves the unit open. No routine startup homing is added. Members must share the same mechanical direction and full-travel gearing.
- Other hardware faults stay latched in managed mode. Disable, explicitly reset, wait for fault-free standby, then enable again. Normal enabled heartbeats cannot clear a hardware fault.
- Q or Ctrl+T stops the program and attempts to open and verify both contacts. An already-issued gearshift sequence may still finish.
- Log: `transformer-controller.log`. Capacity failures include voltage, positions, current and the estimated remaining output range.

Rednet ID/session/sequence checks are not cryptographic authentication. Use a trusted network. CC tasks are cooperative; computer shutdown or chunk unloading stops software protection.

## Optional start on computer boot

Only after configuring and testing, copy `startup_optional.lua` to the computer root. If no startup file exists, rename it to `startup.lua`. If one already exists, add the launch line to your existing boot process rather than overwriting it.

The launcher requires an existing configuration. In standalone mode it may automatically close the breakers once checks pass. In managed mode it waits for fresh master dispatches. Stop any competing controller first.

## Development checks

From the repository root, run `lua Powerplant/regulator/tests/config_banks.lua` for configuration, bank motion/recovery and master-interface mocks. Run `luac -p Powerplant/regulator/transformer_controller.lua` for syntax validation. These tests include a cooperative managed-mode simulation; they do not validate in-game mechanics or electrical current sharing.


## v16 bus roles, supply mode and temporary targets

A regulator can serve a generator, consumer-voltage circuit or transmission-voltage circuit. Configure its actual nominal output voltage and transformer conversion locally, and assign its master-side **output bus**. The main controller's roles do not change winding ratios or ratings.

`connectionMode="parallel"` remains the default. To energize an exclusively owned initially dead circuit, explicitly configure `connectionMode="supply"` on both controller and regulator with matching `deadBusVolts` (default 5 V). Never use this permission on an uncoordinated multi-source bus. Fresh measured dead-bus voltage permits charging/tuning to target before closure. A live bus still requires voltage matching. If the bus remains dead after closure longer than `gridMaxAgeSeconds`, the regulator opens and faults.

`remoteTargetPercent=0` disables temporary remote voltage targets by default. Set a positive commissioned limit smaller than `gridDeviationPercent` to accept shutdown-preparation targets within nominal ± that percentage. Targets expire within 30 seconds and use existing ramp speed/step limits. Omission, cancellation or expiry ramps back toward nominal; configured nominal is never rewritten. All local protection remains active. The master must report a fresh reference for this transformer's output bus.

The upstream controller calculates preparation targets using generators' separately reported maximum and delivered watts. The regulator only executes bounded voltage requests; voltage acceptance alone does not prove sufficient generation capacity or safe load sharing. See [PROTOCOL.txt](PROTOCOL.txt) and the [main controller protocol](../controller/PROTOCOL.md).


## Ender links and local peripherals

Use an **ender modem** for this computer's rednet link to its main controller. Configure its actual peripheral name/side. Discovery accepts wireless modems only; the runtime rejects wired modems for this link and retries an unavailable modem. The API cannot distinguish an ender modem from an ordinary wireless modem, so install the correct block. A separate wired modem may still provide local peripheral sharing for gauges, variacs and gearshifts. Ender modems do not expose another computer's peripherals.

Local protection runs independently of the upstream controller and generator computers. v17 defaults to single-mode fallback when supervision disappears, retaining local regulation and protection. Explicit disable remains persistent. Explicit `masterId=-1` remains available for standalone installations.


## v17 independent single-mode operation

`autonomousFallback=true` is now the default: network supervision is optional for keeping the transformer operating. With no fresh supervisor it uses the same local input/output readings and connection behavior as standalone/single mode. An enabled live transformer does not disconnect solely because its main computer or ender link disappeared. A pending temporary generator connect/disconnect adjustment is abandoned and the active setpoint ramps toward locally configured nominal. Normal voltage regulation still adjusts the variacs as needed to maintain that fixed nominal.

This intentionally uses existing single-mode behavior, without requiring an additional local grid gauge. Supervised external-bus matching checks are available only with fresh supervisory measurements; the isolated output gauge is not an external bus measurement. Set `autonomousFallback=false` to retain strict master-lease-required operation where that is needed.

Explicit disable and local fault inhibition take priority over fallback. The regulator stores enable/disable intent in `transformer-operation-state.json`; keep it (and any `.tmp` recovery file) during upgrades. Reset does not implicitly enable. To change intent locally while the supervisor is absent, stop the program and run `transformer_controller.lua enable` or `transformer_controller.lua disable`, then `transformer_controller.lua run`. These intent commands leave both breakers open. A fresh installation with no saved intent starts enabled in single mode. Stopping the regulator itself opens its breakers and records disabled intent; exiting only the main supervisor releases supervision and leaves autonomous units operating.

Remote target adjustment remains **optional and disabled by default** (`remoteTargetPercent=0`), for occasional generator connection/disconnection events only. It is not a normal load-following change to nominal voltage.


## v18 local screen, maintenance and emergency stop

Install `transformer_controller.lua`, `thermal_protection.lua` and `regulator_ui.lua` together. Run `transformer_controller.lua configure` again: existing saved settings are the defaults (Enter keeps them), including temporarily disconnected peripheral names. The discovery wizard now lets you select **all input isolation breakers**, separately from the two output breakers. Their native current-trip settings are preserved. Old configurations default to no input breakers; configure the installed ones before relying on input isolation.

`transformer_controller.lua run` uses the advanced computer's own screen when `uiEnabled=true` (default). The UI runs alongside regulation, protection and communication in cooperative tasks inside one program. Peripheral sampling runs separately from keyboard/mouse handling, with a one-second pause between completed display samples. Navigation uses the latest complete snapshot and repaints only changed rows. Display samples omit network-only calculations and reuse fresh temperatures from the protection task. Maintenance verifies contacts each pass and only repeats an open command if a contact has unexpectedly closed; protection polling and emergency handling retain their existing timing. Pressing Resume/reset while already running shows a status message without operating the breakers. Do not run another controller against the same hardware. Tabs show the power-path diagram, each stage's members with position and measured temperature, configured voltage/current/power gauges, and settings. Scroll long lists; click a setting, type its replacement, and press Enter to save or Escape to cancel. Lists use comma-separated peripheral names, booleans use `true`/`false`, and numeric settings use numbers (target also accepts `kV`).

Target voltage can change while regulating and uses the existing bounded ramp. Other settings require verified maintenance isolation and idle gearshifts; saving them reloads the program into maintenance with the new configuration. Saved target values always use the configured nominal voltage, never a temporary ramp setpoint. Press Enter without typing to retain the displayed setting.

**Maintenance** opens and verifies output and input breakers, blocks remote enable, and waits for gearshift sequences to stop. **Resume/reset** is local: it verifies open contacts and idle drives, requires acceptable thermal-reset readings, then allows the usual startup checks. Inputs close with outputs open before tuning and output reconnection. Maintenance survives reboot in `transformer-maintenance.json` (including its `.tmp` recovery file). Keep these files during updates. `transformer_controller.lua maintenance` can also request and save isolation from the shell. With the controller stopped, `transformer_controller.lua resume` clears the local latch after the same checks and leaves contacts open; run the controller afterward. `transformer_controller.lua emergency` trips and saves the emergency latch from the shell. These commands also allow recovery when the local UI is disabled.

**EMERGENCY STOP** (red button, or `E` when not editing) latches operation off, attempts every configured output and input breaker without any intentional grace delay, and verifies isolation. One peripheral failure does not skip the other breakers. The button remains available while editing. The latch survives restart and cannot be cleared by remote enable/reset; use local Resume/reset after resolving the cause. A failed or missing contact is shown as unverified isolation. Computer/peripheral calls are sequential, not a simultaneous physical trip, and an already-running sequenced gearshift can finish moving. Open contacts alone do not prove absence of voltage; inspect the gauges.

The diagram labels the existing **7,500 V source spark gap as generator protection**. This is an informational installation annotation, not a programmable transformer trip threshold or spark-gap actuator. Emergency stop disconnects this transformer; it does not send generator shutdown commands. `Q` / Quit opens all configured breakers and exits.

Verification:

```sh
lua Powerplant/regulator/tests/config_banks.lua
lua Powerplant/regulator/tests/thermal_protection.lua
lua Powerplant/regulator/tests/ui.lua
```

Synchronization compares members within each parallel bank. It does not force series stages A, B and C to the same position: those stages intentionally use different ratios to regulate the output. All parallel members must be assigned to their respective bank in configuration.


### Temperature polling across homing transitions

When a fault cancels a parallel worker group, the controller releases any abandoned temperature-scan lock before starting the next group. A timely first scan is allowed to finish without another worker marking its not-yet-read members missing; a blocked scan still trips at the configured freshness deadline. The UI checks freshness per member. Temperature-unavailable faults include the native failure reason or last-sample age when known. This does not increase `thermalMaxAgeSeconds`, change the trip curve, or clear saved thermal faults automatically. After updating, use local Resume/reset (or `reset_thermal` with the program stopped) once every member has a fresh reading at or below 125 C.
