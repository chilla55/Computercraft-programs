# Flight controller

The original manual controller supports eight forward-facing thrusters and two
hot-air burners. The new configurable stabilizer supports four burner sections
and gyroscope feedback; see the four-section leveling setup below.
The device API was confirmed using the supplied in-game API version 2 probe.

## Hardware

| Position, bottom to top | Thrusters |
| --- | --- |
| Right stack | thruster_0, thruster_1, thruster_2, thruster_3 |
| Left stack | thruster_4, thruster_5, thruster_6, thruster_7 |

Burner 0 is left; burner 1 is right. Every thruster pushes the craft forward.
The controller uses equal output within each stack and differential output
between stacks to turn. Upper/lower thrust mixing and roll are not implemented.
Forward thrust alone cannot provide independent roll control.

| Relay | Side | Key | Action |
| --- | --- | --- | --- |
| redstone_relay_2 | top | W | Forward thrust |
| redstone_relay_2 | bottom | Shift | Decrease both burner settings |
| redstone_relay_2 | back | Space | Increase both burner settings |
| redstone_relay_3 | top | D | Turn right |
| redstone_relay_3 | bottom | S | Reserved, ignored until reverse thrusters are installed |
| redstone_relay_3 | back | A | Turn left |

The pilot keys must produce signals on these relay faces. The program reads
the relays; it does not read W/A/D/Space/Shift from the computer keyboard.

## Run

Copy `controller.lua` onto the craft's computer. It is self-contained.

```text
controller --preview
controller --run
```

Preview is also the default with no arguments. It reads inputs and displays
calculated outputs without actuator writes. Live mode takes control of all
eight thrusters, zeros their throttle, enables them, and waits until all
assigned inputs are released before accepting commands.

Thrusters use only full thrust (100%) or zero thrust:
- W: 100% on both sides.
- W+A: left off, right 100%; W+D: left 100%, right off.
- A alone: right 100%, left off; D alone: left 100%, right off. This also moves the craft forward.
- Neither W nor a turn command: zero thrust.
- Simultaneous A+D: cancel the turn, keeping W's forward command if held.

Space increases each burner's signal by two steps per second; Shift decreases
it, clamped to 0–15. Releasing the keys holds the current setting; pressing
both cancels adjustment. Initial burner settings are read from the hardware,
and any existing left/right offset is preserved until a limit is reached.
These are manual burner adjustments, not a target climb speed or altitude
hold. Heating and cooling response must be calibrated in game.

Q on the computer or Ctrl+T exits. A required relay/actuator call failure also
exits. On exit from live operation, the program attempts zero throttle and
disable on every thruster, even if another device fails. It keeps the last
burner signals to avoid suddenly cutting lift, and reports failed thruster
stop calls. It does not restore redstone throttle control. Re-running live
mode enables the thrusters again. Computer power loss cannot execute cleanup.

Altitude and the raw scalar velocity value are displayed as telemetry.
Telemetry read failures display unavailable and do not stop manual control.
The velocity sensor's axis/units are not established, so it is not used for
feedback. The first probe showed empty thrusters. The latest probe shows fuel in all
eight, with throttles zero and devices disabled after stopping the controller;
live startup enables them again. Charcoal is available in the barrel. Automatic refueling is not implemented: the thrusters did not
advertise inventory methods. Fuel them through a supported in-game mechanism.

## Discovery tools

`dump_peripherals.lua` lists all connected names and their methods, including
newly connected gyroscopes, using the
[CC: Tweaked peripheral API](https://tweaked.cc/module/peripheral.html).
It saves `flight-peripherals.txt`.

`probe_api.lua` queries built-in help, device status, sensor values, barrel
contents, and a snapshot of relay inputs. It saves `flight-api.txt`. It passes
setter names as text to help without invoking setters. Unsupported queries
are recorded as errors. Both tools preserve earlier reports with numbered
filenames, or accept an explicit output filename which must not already exist.

The supplied help documents `setThrottle(0..1)` as selecting computer control,
`setEnabled(boolean)`, and burner `setSignal(0..15)`. The generic burner help
says signal control applies when supported by the target block. Actual burner
response and successful in-game flight are still unverified.

## Validation

From the repository root:

```sh
lua FlightController/tests/controller.lua
```

Mock tests cover steering, opposing inputs, burner limits and retained settings,
preview with no actuator writes, input release at startup, preflight failure,
termination, and cleanup after relay or actuator failure. In-game commissioning
is still required; there is no automatic attitude stabilization or roll input.

## Inputs present but devices inactive

Run `controller --run` and release all assigned pilot inputs once. The screen
must say LIVE and Controls ready. PREVIEW intentionally does not write outputs.
The input row should show W:1 when the relay 2 top face is powered and Up:1
when its back face is powered. If those remain zero, check the relay signals
and face orientation. An input stuck on also blocks the initial release step.

The screen distinguishes requested outputs from hardware readings. Throttle
readback is shown for thruster 4 (left) and 0 (right); active, empty, and disabled
counts cover all eight. Burner signal and gas-output readbacks are shown for
both burners. Missing status values appear as question marks. Hold Space long
enough for the commanded burner signal to rise; W controls only the thrusters.

Press P on the computer while the failing input is held to save the latest
hardware snapshot to `flight-status.txt` (numbered if it already exists).
The snapshot includes operating mode, readiness, inputs, commands, all eight
thruster statuses, both burner statuses, and sensor values. Readbacks refresh
every half second. Share this report to distinguish input, fuel, and actuator
API problems. Signal readback alone does not prove the burner is producing gas.

## Four-section leveling setup

The new `stabilizer.lua` uses the confirmed thruster stacks plus four independent
burners: left-front, left-back, right-front, and right-back. Place it alongside
`controller.lua` and `aircraft_config.lua` on the computer. The manual controller
remains a two-burner program; the stabilizer is the new four-burner entry point.

`aircraft_config.lua` now contains the installed mapping:

| Corner | Peripheral | Local X | Local Z |
| --- | --- | --- | --- |
| Left front | hot_air_burner_5 | 20481037 | 20485116 |
| Left back | hot_air_burner_4 | 20481035 | 20485116 |
| Right front | hot_air_burner_3 | 20481037 | 20485124 |
| Right back | hot_air_burner_2 | 20481035 | 20485124 |

All four share local Y 127 and the same sub-level. From the user-confirmed
left/right labels, local +Z is right. Taking local +Y as the craft's up axis,
forward is +X, which places burners 3 and 5 at the front. This uses local
coordinates rather than world cardinal directions, so craft yaw does not
change the corner assignment.

The installed `gimbal_sensor_0` exposes `getAngles()` and `getAnglesRad()`.
Its degree table in the supplied report was `{0.0000047193, 10.3046944347}`.
The adapter maps this to pitch `-angles[2]` and roll `angles[1]`, where positive
pitch is nose up and positive roll is right side down.

This conversion was cross-checked against burner geometry: the front is
0.357765655 blocks below the rear over a two-block spacing, giving pitch
-10.3046944347 degrees. The world-space right and up vectors give roll
+0.0000047193 degrees, matching the first gimbal value. This is evidence from
one snapshot; verify response through larger pitch/roll changes and turns
when commissioning, especially if the gimbal mounting changes.

Discovery tools remain available after hardware changes. The probe reads
burners 2–5 and advertised attitude methods on gyro/gimbal peripherals.

Copy the updated config and both controller files, then run:

```text
stabilizer --preview
stabilizer --run
```

Unfilled configuration fails before any actuator writes. Preview computes
corrections without writing them. Live mode zeros/enables the thrusters, waits
for pilot inputs to be released, and then continually targets pitch 0 and roll 0.
The attitude loop remains active during forward movement, turning, and idle.

The controller combines proportional attitude error and filtered angular rate
estimated from successive gyro readings. Initial gains in the config are trial
values, not calibrated flight settings. Each corner gets a common lift setting
plus pitch/roll corrections and optional trim. Pitch uses front/back burner
differences; roll uses left/right differences. This assumes greater burner
signal produces greater lift, which still needs verification on these blocks.

W requests full forward thrust. A/D select differential steering as before.
For pitch correction, the controller reduces selected thrusters according to
their vertical position (bottom, lower middle, upper middle, top). Nose-up error
reduces lower thrusters; nose-down error reduces upper thrusters. This supersedes
the manual controller's strict full-or-zero rule for stabilization. A bank that
the pilot leaves off remains off, so idle leveling relies on the burners.
Forward-facing thrusters cannot independently correct roll.

Space/Shift adjust the common burner setting rather than the level target.
The initial common setting is the average of all four current burner signals;
configured trims replace any initial per-corner offsets once the loop starts.
Burners clamp to integer 0–15; thrusters clamp to 0–1. At either burner limit,
correction authority is reduced and corrections can change total lift.
Altitude hold is not implemented. The scalar velocity sensor is not used for
attitude feedback. Gyro failure/invalid readings stop the loop and attempt to
stop every thruster, retaining the last burner settings as in manual mode.

Level flight throughout the flight envelope is an objective, not yet verified.
Burner lag, fuel supply, gyro axes, available torque, and gains must be tested
in game. Preview should show rear burner lift increasing for nose-up attitude
and right burner lift increasing when the right side is down. Sensor freshness
cannot be checked until the actual gyro API exposes its update/timestamp behavior.

Run the additional mock tests with:

```sh
lua FlightController/tests/stabilizer.lua
```

These cover pitch/roll correction signs, pitch thrust mixing, output saturation,
manual steering, invalid gyro readings, missing/duplicate configuration,
preview with no writes, startup input release, and cleanup after device failure.

## Leveling moves farther from level

The correction signs match the original position sample, but that does not
verify actuator response or flight dynamics. Do not infer a polarity fix from
a growing angle alone: shared balloon volumes, inadequate torque, and response
lag can also prevent leveling. Check that each burner actually feeds its own
separate enclosed balloon section.

Record the failing behavior with:

```text
stabilizer --run --record
```

After startup input release, capture a few seconds with W released and then a
short forward-thrust input if practical. Press Q and share `flight-leveling.jsonl`
The recording captures
commands, normalized and raw gimbal angles, all thruster statuses, and each
burner's status including world positions, reported signal and gas output in a
separate recording coroutine, targeting a sample about every half second. It reports actual API read errors rather than replacing them with
zero. Starting a recording replaces previous flight-leveling JSONL logs. `--preview --record` is also available
for observation without actuator writes. Independent reads are batched, but a sample is not an atomic physics snapshot.
`time` is the control sample time, `controlDt` is its measured interval, and
`readStarted`/`readFinished` bracket the hardware telemetry reads. The following
sample is useful for actuator response checks. A recorder write failure is
shown on screen and does not cancel the control loop.

Upstream source confirms that the gimbal returns XAngle then ZAngle in degrees,
computed from world down transformed into the craft's local coordinates. For
this craft's +X forward/+Z right orientation, pitch is -ZAngle and roll is XAngle.
The burner source computes gas output proportional to signal strength; the
location of resulting lift depends on the connected balloon volume. These are
upstream references; installed versions and integrations may differ.

- [Gimbal peripheral](https://github.com/Creators-of-Aeronautics/Simulated-Project/blob/main/simulated/common/src/main/java/dev/simulated_team/simulated/compat/computercraft/peripherals/GimbalSensorPeripheral.java)
- [Gimbal angle calculation](https://github.com/Creators-of-Aeronautics/Simulated-Project/blob/main/simulated/common/src/main/java/dev/simulated_team/simulated/content/blocks/gimbal_sensor/GimbalSensorBlockEntity.java)
- [Burner signal and gas output](https://github.com/Creators-of-Aeronautics/Simulated-Project/blob/main/aeronautics/common/src/main/java/dev/eriksonn/aeronautics/content/blocks/hot_air/hot_air_burner/HotAirBurnerBlockEntity.java)

## Timing correction from the first flight recording

The 55-sample recording spans 69.5 seconds. Every recorded thruster throttle and
real-thrust value is zero. The craft initially approaches level, then overshoots
in both axes and rolls onto its side. It does not demonstrate a simple reversal
of every correction sign, and cannot establish the thruster response.

The old recorder ran inside the controller loop; sample intervals were usually
1.3 seconds. The control code also capped elapsed time at 0.25 seconds before
computing angular rate, exaggerating estimated rate for slow updates. That
same cap slowed manual lift adjustments during stalls. The fix uses actual
elapsed sample time, batches independent relay/gyro reads and actuator writes,
starts the next timer before peripheral work, and moves recording into a separate
coroutine. The screen shows the measured control interval.

Update BOTH `controller.lua` (batched relay input support) and `stabilizer.lua`.
The existing `aircraft_config.lua` mapping and gains are retained. Start from a
level craft and record another run to verify the fix in Minecraft; offline tests
verify timing math and behavior, not the actual craft's stability.

## Bounded recording storage

Recordings now keep compact status fields instead of repeating class names,
local coordinates, capacities, and other static metadata in every sample.
Numbers are rounded to four decimals. A single `schema: 3` header lists
peripheral names, corner order, and array column definitions. Subsequent samples
use indexed arrays rather than repeating device names and field names. Keep
the header when sharing a recording so each value can be identified.
Commands, inputs, attitude, timing, burner signals/gas output/world positions,
and thruster throttle/real thrust/fuel/enabled/active state remain available.

Each new recording stops at 900 KiB or before available space falls below a
32 KiB reserve plus allocation margin. Disk checks use the
[CC filesystem free-space API](https://tweaked.cc/module/fs.html#v:getFreeSpace).
An exhausted disk or failed log creation stops recording without preventing
flight control. The screen shows why recording stopped. Starting with `--record`
deletes only root-level `flight-leveling.jsonl` and numbered
`flight-leveling-N.jsonl` files, then writes a new `flight-leveling.jsonl`.
Lua programs, configuration, probe reports, other filenames, and directories
are preserved. Starting without `--record` performs no log cleanup. Save any
recording you want to retain before starting the next one.

The second supplied recording confirms a 0.1-second control interval. It starts
at approximately 90 degrees of roll; reset the craft upright for a level-flight
commissioning test. A level-hold controller has not been validated for recovering
from a craft already lying on its side.

If recording immediately reports insufficient space after log cleanup, run
`stabilizer --disk`. This read-only command prints actual capacity/free bytes
and the 15 largest files on the computer's drive, including nested directories
but excluding other mounted drives. It works without loading aircraft config
or connecting peripherals. The recorder's message now includes actual free
bytes and the required amount, and does not repeat the stop message on exit.
Do not delete Lua programs to make room without first identifying what uses it.

## Findings from the compact flight recording

The 148-sample schema-3 recording is about 87 KB. Control intervals remain
0.1 seconds. It starts at about -50 degrees roll, rather than an upright start.
After settling near level and increasing collective to 7.6, the craft pitches
nose-down to about -42 degrees before forward thrust is used. Front burner
commands exceed rear commands, and signal/gas readbacks respond. Pitch reverses
after collective is reduced and the rear burners reach zero.

This is consistent with limited effective differential lift (for example,
balloon saturation or shared air spaces), but does not establish the cause.
Upstream ServerBalloon sums connected heater outputs and caps target volume at
balloon capacity. A burner gasOutput reading is a requested volume, not measured
balloon lift. The recorded scaling is about 33.33 volume units per signal step,
consistent with a 500-unit burner amount at full signal. Compare each burner
setting with the actual section capacity before changing feedback signs/gains:
[balloon fill implementation](https://github.com/Creators-of-Aeronautics/Simulated-Project/blob/main/aeronautics/common/src/main/java/dev/eriksonn/aeronautics/content/blocks/hot_air/balloon/ServerBalloon.java).

The recording also exposed nonzero burner commands at zero collective. This is
fixed: reaching zero collective turns all four burners off, including attitude
corrections. Raising collective resumes correction. Leveling authority from the
burners is therefore unavailable at zero. This fixes that command behavior; it
does not establish that the remaining flight instability is resolved.

## Tuning pass 2 (controller 0.2.0)

The recording with 115 m³ burner settings confirms signal 1 produces about
7.6667 m³, and the controller continues at 0.1-second intervals. Pitch oscillation
still grows before thrust is used: approximately +16, -24, +27, then -44 degrees.
This supports earlier braking for delayed burner response rather than reversing
correction signs. The trial pitch derivative gain is now 0.15 (was 0.015), and
roll derivative gain is 0.06 (was 0.015); proportional gains remain 0.025.
This is an initial damping adjustment based on the trace, not a validated model.

When a requested burner signal exceeds 15, the mixer lowers all four requested
signals by the same overflow before clamping/rounding. This preserves the lift
difference at full collective, at the cost of lower average lift while correcting.
Zero collective, including positive numerical residue below 0.000001, keeps all
burners off. The previous exact-zero test could miss floating-point residue
which appeared as zero in rounded logs.

Update both `aircraft_config.lua` and `stabilizer.lua` for this tuning pass.
The screen and recording header identify controller 0.2.0; the header records
active gains, and samples include filtered angular rates. Test upright without
forward thrust before assessing thruster behavior. Offline regression tests
verify early braking direction, full-collective differential output, and the
near-zero cutoff. Stability and final gains still require another in-game run.

## Powered-flight tuning trial (controller 0.2.0, authority 0.70)

The next hover recording held settled pitch between -1.90 and -1.37 degrees
and roll between -1.31 and +1.55 degrees. The subsequent powered recording
contained approximately eight seconds of forward input: pitch reached +12.28
degrees, then -5.33 after release. During the rising-pitch response, the bottom
thrusters were reduced to about 75% while the top thrusters stayed at 100%.
This shows correction was being commanded, but does not establish the craft's
physical torque response or final required gain.

For the next trial, only `thrusterPitchAuthority` changes, from 0.35 to 0.70.
This doubles the existing throttle differential for a given feedback output.
Burner gains, roll control, input mapping, and off-bank behavior are unchanged.
Only `aircraft_config.lua` needs replacing; the controller version remains
0.2.0 and the log header identifies the new authority. This is a trial setting,
not a validated stability fix. Keep the burner output setting at 115 m³.
Take off, settle, then apply W for 1–2 seconds and release; record the recovery
for at least 15 seconds before changing lift or applying another input.

## Roll damping trial (controller 0.2.0, roll kd 0.12)

The isolated short W pulse at collective 12.4 was followed by pitch extrema
of +2.94 and -4.76 degrees over the next approximately 17 seconds. Pitch was
already moving before the pulse, so these extrema are not solely attributable
to thrust. In the later hands-off window (recording time 1465–1500.25), pitch
settled between -2.20 and -1.14 degrees, but roll continued between -3.95 and
+4.86 degrees with all thrusters commanded off. Reducing collective later
produced a roll excursion up to +7.56 degrees before landing. This run does
not demonstrate stable level flight across lift settings.

Only roll derivative gain changes for this trial: 0.06 to 0.12, to request
earlier braking of roll motion. Pitch gains and thruster authority 0.70 remain
unchanged. Replace only `aircraft_config.lua` and restart the controller.
Keep burner output at 115 m³. Record at least 45 seconds airborne at unchanged
collective without W/A/D, to compare roll amplitude over time. The stronger
damping is an empirical trial; its effectiveness requires in-game validation.

## Hover pitch trim trial (roll kd 0.12 retained)

The next recording confirmed roll kd 0.12. In the hands-off window from
4790 to 4922.2 seconds, at collective 13, roll stayed between -0.90 and
+1.42 degrees. Pitch stayed between -3.77 and -2.90 degrees, averaging
-3.32. This supports retaining the damping while addressing the steady
nose-down bias separately. These measurements apply to this hover setting.

The next trial adds +0.25 signal trim at both front burners and -0.25 at
both rear burners. The magnitude corresponds to the existing proportional
pitch correction at about 3.3 degrees (3.3 * 0.025 * 3). These are offsets
before integer rounding; actual burner changes depend on collective and
feedback. They do not guarantee a particular lift or zero pitch.
Pitch/roll gains and thruster authority are unchanged.

Replace `aircraft_config.lua` and `stabilizer.lua`: the latter now includes
`burnerTrim` in the recording header. Controller version remains 0.2.0.
Repeat a hands-off airborne hover at collective 13 for at least 45 seconds,
keeping burner output at 115 m³. This trim is a trial needing flight validation.

## Powered pitch trim trial (controller 0.2.1)

With the successful hover burner trim installed, a roughly 2.5-second W pulse
was followed by +10.74 degrees pitch at recording time 5400.3 and -6.18 at
5405.8. Recorded thruster throttle was zero after release, so the continuing
pitch excursion does not indicate stuck thrust. The trace does not identify
the exact contribution of balloon delay, inertia, or other physical effects.

A new optional `thrusterPitchTrim` adds a constant throttle differential to
the existing pitch feedback while a bank is commanded on. The trial value
is -0.15. At level with zero pitch rate, each active stack receives 85%, 95%,
100%, 100% throttle from bottom to top. This aims to counter the recurring
nose-up response earlier. Off banks remain off, including on W release.
The trim also applies to the selected bank during turns. Hover burner trim
and all feedback gains are unchanged. Missing thruster trim defaults to zero.

Replace both `stabilizer.lua` and `aircraft_config.lua`. The screen identifies
0.2.1 and the recording header includes the new trim. Regression checks cover
level throttle distribution, off/turn behavior, unchanged burner commands,
and compatibility with older configs. Physical effectiveness is unverified.
After settling at collective 13, record a two-second W pulse and at least
25 seconds of recovery without other inputs. Keep burner output at 115 m³.

## Stronger powered trim trial (0.2.1, thruster trim -0.30)

The -0.15 trim recording contained a roughly 2.6-second forward pulse at
collective 13. Pitch was +2.10 degrees at the first released-input sample,
then peaked at +8.90 approximately 3.3 seconds later and reached -4.45
during recovery. The previous untrimmed pulse peaked at +10.74 and -6.18.
Initial attitude/rates differed, so the reduction cannot be attributed solely
to trim. The delayed excursion remains substantial despite confirmed zero
throttle after release. By the later hands-off window (5765–5794), pitch
was between -0.07 and +0.87 degrees.

The next trial changes only `thrusterPitchTrim` to -0.30. At level and zero
pitch rate, active stacks receive 70%, 90%, 100%, 100% from bottom to top.
Feedback remains active. Burner trim, damping, and hover settings stay as
before. Replace only `aircraft_config.lua` and restart; controller version
remains 0.2.1, and the header identifies the new trim. This remains an
empirical trial rather than a verified solution to the delayed recovery.
Repeat a two-second forward pulse at settled collective 13, then allow
45 seconds without other inputs to capture the full recovery.

## Independent thruster feedback trial (controller 0.2.2)

The eight-second W recording reached +6.36 degrees before release, then
+11.56 and -6.00 during recovery. Thrust began while burner height was still
rising (about 107 m), rather than at settled hover (about 117 m); it is not
a controlled comparison of peak size with the earlier short pulses. It does
show pitch developing under sustained power, not only after release.

Thrusters now accept optional `thrusterPitch = { kp, kd }` gains. Without
this setting they retain the previous shared pitch gains. The trial uses
kp 0.075 and kd 0.15, compared with burner kp 0.025 and kd 0.15. The existing
filtered pitch rate is reused without a second filter update. Trim -0.30
and authority 0.70 remain. At +6 degrees with zero pitch rate, bottom
throttle is 38.5%, versus 59.5% with the old gains. At level with zero rate
the existing 70/90/100/100 distribution remains. Off banks stay off.

Burner feedback and hover trim are unchanged. These independent gains aim
to reduce the error while thrust is active, and are not a verified fix for
post-release recovery. Replace both config and stabilizer, check version
0.2.2, settle at collective 13 until height stops rising, then record a
two-second W pulse followed by 45 seconds without other inputs. The log
header includes both burner and thruster gains. Regression tests cover
stronger thrust correction, unchanged burner output and rate filtering,
command bounds, off banks, invalid gains, and older-config fallback.

## Zero burner trim comparison (0.2.2 diagnostic)

The first 0.2.2 recording retained front +0.25 / rear -0.25 burner trim.
After a roughly 1.7-second W pulse from settled hover, pitch reached +7.34
then -2.15 degrees. During the pulse it remained close to level. The pulse
was shorter than previous tests, so this does not isolate the benefit of
separate thruster gains or the contribution of burner trim.

For the next diagnostic only, all four `burnerTrim` values are zero. All
other settings remain identical to that recording. Replace only config and
restart. Expect the earlier nose-down hover bias to return. At collective
13, allow pitch and altitude to settle, then repeat a roughly two-second W
pulse and record 45 seconds hands off. Compare pitch change from its
pre-pulse baseline as well as absolute peaks. This disables only constant
burner trim; automatic burner pitch/roll feedback remains active.
The established hover trim to restore after the experiment is front +0.25
and rear -0.25. Zero trim is not being adopted as the final flight setting.
