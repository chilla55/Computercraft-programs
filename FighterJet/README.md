# Fighter cockpit and flight controller

Computer **5** owns flight controls, mixed wing actuation and autopilot.
Computer **6** owns the colour HUD, radar, home/autopilot configuration and
manual flight-computer restart. This implementation has host-side tests;
its aerodynamic gains and sensor signs have **not** been flight-tested.

## One-command install

On **both computer 5 and computer 6**, run:

```
wget run https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/FighterJet/install.lua
```

HTTP must be enabled. The installer detects the computer ID, verifies every
file against the versioned release's SHA-256 manifest, and installs into
`/fighter`. It sets `/startup.lua` to launch the appropriate program and
backs up an existing startup as `/startup.before-fighter.lua` (numbered if
needed). It does not reboot or start flight during installation.

Start with `/fighter/run`, or reboot manually when ready. Computer 5 starts
in **ASSIST with thrust off**; computer 6 starts the HUD. Use the explicit
`/fighter/run preview` command on 5 for no actuator writes. Normal startup now
always selects assistance, including on installations with an old saved
`startup_mode.lua`; that legacy file is retained but no longer selects the mode.
Explicit diagnostic commands and calibrated `/fighter/run live` remain available.

Persistent files live directly under `/fighter`:

- `jet_config.lua`: calibration, peripheral names, flight tuning, recovery.
- `hardware.lua`: mechanical wing mapping.
- `startup_mode.lua`: legacy compatibility file, no longer used for mode selection.
- `jet_state.a` / `.b`: saved home and cruise altitude.

Updates preserve these files exactly. A first install also imports these
files from an existing flat installation in the computer root, if present.
Startup selection follows the default described above. Defaults for a new release remain
available inside `/fighter/releases/fighter-X.Y.Z/` for comparison; new
configuration fields are not silently merged into your calibrated settings.

## Default active stabilization and manual selector (0.1.5)

Stop both programs while parked, then run `/fighter/update apply` on both computers.
Start the HUD on **6** with `/fighter/run`, and the controller on **5** with:

```
/fighter/run
```

This default assisted mode works with the existing configuration and saved thruster
remap. It leaves saved calibration flags unchanged. The terminal says
**ASSIST - TUNING** and the HUD shows **ASSIST TUNING** on the artificial horizon.

- W/S request pitch rotation, up to 25 degrees/second; A/D request bank rotation,
  up to 40 degrees/second. These are controller requests, not guaranteed limits.
- Releasing either axis captures its current attitude. Feedback opposes further
  rotation and returns toward that captured angle. It does not automatically level
  the plane or hold altitude.
- Wings mix pitch and roll continuously, with up to 40 degrees of deflection.
  Space latches full base thrust; Shift turns all engines off. Pitch feedback also
  modulates top/bottom thrust using the configured authority (default 25%). Bank
  control uses the wings; this mode adds no open-loop differential yaw thrust.
- HUD loss does not stop assistance. Computer 5 retains its output watchdogs and
  may restart computer 6 under the existing recovery policy. Autopilot/configuration
  requests other than the assisted/direct control selector are rejected during assist tuning; computer 5 is never auto-rebooted.

On the HUD **Flight Data** page (one PAGE press from the horizon):

- Tap **DIRECT MANUAL**, then **CONFIRM MANUAL** within four seconds to disable
  stabilization. The first tap sends no control command. Leaving the page or
  losing/re-establishing the flight link cancels confirmation.
- Tap **ENABLE ASSIST** to restore stabilization immediately, capturing the current
  pitch and bank. Release flight keys before switching; active pilot input rejects
  the request. Both transitions preserve the existing throttle setting.
- Direct manual mode uses up to 40-degree mixed surface commands and the existing
  direct differential-thrust mixer. Release centers the surfaces; attitude is not
  held. The HUD labels it **DIRECT MANUAL** / **NO STABILIZER**.
- Link loss preserves the selected mode. Restarting computer 5 always returns to
  assisted control with thrust off. The selected direct mode is not persisted.

The provisional profile uses pitch **+GZ**, bank **-GX**, based on the pilot's
observations and commissioning traces. It overrides the old saved axis/gain values
in memory only. Optional `assist = {...}` overrides in `/fighter/jet_config.lua`
allow tuning `pitchKp`, `pitchKd`, `bankKp`, `bankKd`, `pitchRateLimit`,
`bankRateLimit`, `rateFilter`, `maxSurface`, axis indices, signs and offsets.
The HUD uses the active profile supplied by computer 5 with its direct gimbal read.
These gains are tested in software, not yet verified in flight. The two tilt
readings are coupled at extreme attitudes; this is not validated inverted-flight
recovery. Begin upright and use small inputs for the first assisted trace.

`/fighter/assist.csv` is overwritten each assisted run and capped at 128 KiB.
It includes raw angles, mapped angles, targets, filtered rotation rates, requested
surfaces, measured spring angles with their sample ages, and last written engine
commands. Measured spring angles use positive trailing-edge-UP on both sides.
Engine columns are command acknowledgements, not measured thrust. During a held
key the rate request controls that axis; attitude targets matter after release.
Logging failure stops the trace, not the flight controller. Send this log to tune
real response and check for reversed corrections or oscillation.

## Relocated thrusters (0.1.3)

Rear view looking toward the nose: **bottom 12, top 13, left 15, right 14**.
New installs use that layout. Existing installations retain their config, so
stop both programs while parked, update both, and run on **each computer**:

```
/fighter/update apply
/fighter/run remap 12 13 15 14
```

The order is **BOTTOM TOP LEFT RIGHT**. Full peripheral names are also accepted.
The command checks presence and thruster methods without firing any engine.
It saves a small two-slot mapping (`thruster_map.a` / `.b`) that overrides just
the thruster list and vectoring positions in the loaded config/hardware.
Other settings, tuning, assist authority/signs, saved home, and startup mode
are preserved. A disabled thrust assist remains disabled. To change the mapping
again, rerun `remap`; this saved mapping takes precedence over IDs written in
`jet_config.lua`. A rejected mapping leaves the previous one available.

Restart computer 6's HUD with `/fighter/run`. On computer 5 first run
`/fighter/run thruster` to check the relocated engines, then use
`/fighter/run commission 20` for another flight trace. Do not enable calibrated
live flight just because peripheral IDs have been updated.

## Manual updates and rollback

Nothing checks for or installs updates at boot or in the background.
Run these commands yourself:

```
/fighter/update check
/fighter/update apply
```

`check` reports availability; `apply` downloads and verifies a whole release
before selecting it for the **next launch**. Neither command reboots either
computer. The currently running program keeps its loaded version.

For updates, park the aircraft, stop computer 5 with Ctrl+T first, then stop
the HUD (`quit`). This also prevents the flight computer's HUD recovery from
rebooting computer 6 during maintenance. Apply on **both** computers, then
run `/fighter/run` on computer 6 and computer 5. Never update in flight.

To select the previous code version manually, including without internet:

```
/fighter/update rollback
```

Restart manually afterward. Rollback preserves your settings and saved home;
it changes program code only. One previous complete version is kept. Partial
downloads never become active, two selection files tolerate an interrupted
selection write, and inactive downloads are cleaned on the next apply.

The managed directory is reserved for this program. A pre-existing unmanaged
`/fighter` is left untouched. Rerunning the installer repairs the startup
launcher but does not silently update an existing managed installation.

A manual-copy ZIP can also be generated with `python3 FighterJet/tools/build_release.py`.
For that layout, keep all Lua files together and run `flight preview` on 5
and `hud` on 6. The managed installer is recommended for manual updates.

Before live operation, configure `jet_config.lua` on **both** computers:

- `flight.pitchAxis`, `bankAxis`, their signs and offsets: positive pitch
  means nose up; positive bank means right wing down. The horizon page shows
  raw GX/GZ until `flight.calibrated=true`. The axis defaults are provisional.
- `pitchSurfaceSign` and `bankSurfaceSign`: positive common demand must raise
  the nose; positive differential demand must bank right. Mechanical surface
  directions are established, but aerodynamic torque signs are not.
- Check all four thrusters push forward, then set `thrustersVerified=true`.
  Space/Shift select base thrust on/off; differential assist can reduce
  individual engines while base thrust is on.
- Set `calibrated=true` only after those sensor/control signs are checked.
  Flight refuses live mode if either verification flag is false.

Start with the proven ground wing tests, then short manual flight checks
before relying on attitude hold or autopilot. Gains are starting values.
The gimbal supplies two tilt angles, not yaw or a full attitude quaternion;
sustained inverted/aerobatic flight is not validated.

## Commissioning when the computer is the only control

Release `fighter-0.1.1` adds explicit test modes that work with both verification
flags still false. They write actuators, but **never run attitude stabilization
or autopilot**. Calibration flags are not changed automatically.

For the first upgrade from 0.1.0, stop both programs while parked and use this
manual command on both computers. It updates the launcher to accept test modes
as well as installing the new release:

```
wget run https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/FighterJet/install.lua apply
```

If you already used `/fighter/update apply`, rerun the regular installer command
without `apply` once to refresh the launcher. Subsequent updates use the normal
manual update utility. Saved home, configuration, and startup mode remain intact.

Start the HUD on computer 6 with `/fighter/run`. On computer 5, choose a test:

### Individual thruster test

```
/fighter/run thruster
```

Release all flight keys initially. Use **S** to select the next thruster and
**W** the previous one; selection happens once per press. The horizon page
shows the selected name. **Space** starts a nominal 0.3-second full-thrust pulse
on that thruster only. Releasing Space ends it early; holding Space does not
repeat it. **Shift** cancels it and requires Space release before another pulse.
Actual stop timing includes server/peripheral latency. Wings stay neutral.
Observe whether each thruster pushes forward, backward, upward, etc. This test
is for identifying hardware, not flying the aircraft. Ctrl+T on 5 ends it.

### Direct flight/surface test

After identifying the thrusters, stop the individual test and run on 5:

```
/fighter/run commission 20
```

`20` is the maximum surface deflection in degrees (0..40 accepted). The default
is 20. Release 0.1.2 reverses A/D based on the pilot's observed bank direction. Typewriter control uses the established *mechanical* wing directions:

| Key | Direct command |
| --- | --- |
| S | Both trailing edges UP |
| W | Both trailing edges DOWN |
| D | Left trailing edge DOWN, right UP |
| A | Left trailing edge UP, right DOWN |
| Space | Latch full base thrust; differential assist may reduce individual engines |
| Left Shift | Latch thrust off |
| Release W/S/A/D | Surfaces return to neutral; no attitude hold |

If 20 degrees is still insufficient, explicitly select 30 or 40. Forty degrees
is the original spring limit observed in the hardware tests, not a proven
aerodynamic optimum. Live stabilization keeps its separate configured limit
and calibration signs; commissioning does not change those settings. The
observed roll response requires `bankSurfaceSign=-1` once the bank sensor
is mapped to positive-right-wing-down. New configs use that sign; existing
config files are preserved, so update that field before enabling live mode.

Pitch/roll inputs can be combined; the mixture is scaled to the selected
maximum angle. Wing pitch direction remains unverified; A/D was reversed
after the pilot reported the original bank direction was inverted. Engine
assist uses the rear-view thruster layout described below. Keep initial test inputs brief. Once the aircraft has flying
speed, observe the actual nose/bank response to S and D separately and compare
with the raw GX/GZ readings on the HUD. For example, report “S raised the nose,
GZ increased” or “D lowered the left wing, GX decreased.” That establishes the
sensor axis/sign and the corresponding correction direction. With engine assist active this is the
combined aircraft response, not an isolated measurement of wing torque. To
verify the wing correction signs independently, set `vectoring=false` in
`/fighter/jet_config.lua`, restart the test, and repeat with wings alone. Reverse
commands remain available throughout; there is no computer-imposed attitude
correction during this mode. Never enable live stabilization merely to make
these tests available.

The controller writes `/fighter/commission.csv`, overwriting the previous test
trace. It records raw gimbal angles, pilot common/differential input, commanded
surface angles, applied thrust, selected thruster, altitude and position at up
to 4 Hz, capped at 128 KiB. A full disk stops recording without stopping direct
control. The trace alone cannot identify which end is the nose: your visual
observation supplies that reference. Resting trim is not automatically treated
as a physically level attitude.

The HUD shows DIRECT TEST or THRUSTER TEST with **NO ATTITUDE HOLD**. Autopilot
requests are rejected, HUD auto-reboot is disabled during tests, and Ctrl+T
releases outputs. Tests do not become a saved startup mode. After testing,
normal `/fighter/run` starts assisted control again.

## Differential thrust assist (0.1.2)

The confirmed rear-view layout is top=13, bottom=12, left=15, right=14. With
all engines pointing forward, unequal thrust supplies **pitch and yaw** torque.
Wing surfaces still supply roll; this software does not physically swivel
thrusters or provide direct roll torque from them.

Assist is enabled by default at **25% maximum engine reduction**, including
existing configurations without a `vectoring` field. At full base thrust:

- Nose-up demand reduces top thruster 13 toward 75%; bottom 12 stays at 100%.
- Nose-down demand reduces bottom 12; top 13 stays at 100%.
- Right-yaw demand reduces right thruster 14; left 15 stays at 100%.
- Left-yaw demand reduces left thruster 15; right 14 stays at 100%.

Commands can combine pitch and yaw. Neutral inputs restore equal engine power
in commissioning, and Shift always makes every engine zero. This loses some
forward thrust during a correction because engines already at 100% cannot be
increased further. Torque magnitude depends on each engine's offset from the
craft's centre of mass and still requires physical testing.

In commissioning, S/W command nose-up/down thrust assist and D/A command
right/left yaw assist, alongside the direct surfaces. There is no attitude
feedback. To test differential thrust **with wings kept neutral**, use:

```
/fighter/run commission 0
```

For combined control at larger surface angles:

```
/fighter/run commission 20
```

In calibrated live operation, pitch assist follows pitch error/rate correction.
Yaw assist follows A/D input, or the HOME turn demand. It is feedforward turn
assistance, not yaw-angle or sideslip stabilization; the gimbal has no heading
measurement. The individual `thruster` pulse test bypasses all mixing.

To override defaults, add this top-level field to `/fighter/jet_config.lua`
(do not replace the rest of your config):

```lua
vectoring = {
    enabled = true,
    authority = 0.25, -- 0..1 maximum opposing-engine reduction
    pitchSign = 1, yawSign = 1,
    top = "thruster_13", bottom = "thruster_12",
    left = "thruster_15", right = "thruster_14",
},
```

Set `vectoring=false` to test wings alone. Changing the configuration requires
restarting the controller. Config files are preserved by updates; the runtime
uses the documented defaults for this newly added optional field. The HUD's
commissioning title shows V25 for 25% authority, and the trace records each
individual engine command as well as the surface commands. The engine test
names remain mapped as the user reported; calibration flags stay unchanged.

## Pilot controls

| Input | Action |
| --- | --- |
| W / S | Nose down / nose up |
| A / D | Bank left / right |
| Space | Latch full base thrust (individual engines may be reduced by assist) |
| Left Shift | Latch thrust off; wins if Space is also held |
| Release W/S/A/D | Capture current pitch/bank on that axis and hold it |

Computer 5 reads `linked_typewriter_1` directly. Any of these six keys,
including opposing keys held together, overrides autopilot into MANUAL.
MANUAL retains attitude assistance. Startup waits for all six keys to be
released. Restarting computer 5 starts ASSIST with thrust off; saved home
and cruise altitude are restored, but an old autopilot engagement is not.

Pitch and bank corrections mix simultaneously into both surfaces. The
controller keeps gearshift commands refreshed while changing torsion limits
only when the spring is static. Nonzero target changes do not insert an
explicit neutral stage. Demand is scaled to the maximum surface angle while
preserving the pitch/roll mixture. Angle updates use integer degrees.
The earlier brief zero telemetry during limit changes did not correspond
to visible centering in the user's ground test.

Established mechanical mapping (positive surface = trailing edge UP):

| Side | Gearshift | Spring | Raw spring sign for UP |
| --- | --- | --- | --- |
| Right | directional_gearshift_2 | torsion_spring_0 | -1 |
| Left | directional_gearshift_3 | torsion_spring_1 | +1 |

## Home with or without the navigation table

The aircraft position defaults to `directional_gearshift_2.getPosition()`.
Its probe returned projected world X/Y/Z and dimension, so a navigation
table is **not required** for coordinates or return-home. `position.name`
and `position.method` select a different peripheral if needed; it must
return world coordinates, not local/sublevel block coordinates. Check the
NAVIGATION page's position while moving the aircraft before removing the table.

On computer 6, the HOME page lets you select X/Y/Z, increment/decrement by
1, 10, 100 or 1000, and touch SAVE HOME XYZ. Alternatively, use its console:

```
home 178 90 684 minecraft:overworld
altitude 150
mode HOME
```

`homeDimension` sets the default dimension for entered coordinates. `here`
saves the current aircraft position. `marker` imports the current target
from `navigation_table_0`; a missing/unset marker is rejected. Neither
saving home nor changing altitude engages autopilot. If you remove the
table, set `navigation=nil` in both configs to disable marker reads.
No GPS infrastructure or extra position block is required by this default.

Home and cruise altitude are acknowledged only after computer 5 saves them.
Two alternating files (`jet_state.a` / `.b`) preserve the previous valid
configuration if a write is interrupted. Each is bounded to 4 KiB. There
is no continuous disk logging, inventory transfer or refuelling logic.
Refuelling remains handled by the existing automatic system.

## Autopilot and navigation

| Mode | Behavior |
| --- | --- |
| MANUAL | Pilot commands with current-attitude hold on release |
| HOLD | Hold attitude captured when selected |
| ALT | Hold selected altitude with bank target zero |
| HOME | Steer toward saved X/Z while holding selected cruise altitude |

Autopilot preserves the current latched thrust; it does not start the engines
or manage airspeed. Engage at a suitable flying speed after applying thrust.
HOME uses **course over ground**, computed from successive world positions,
not compass heading or the gimbal's tilt angles. HOME requires a valid course
(default minimum 2 blocks/second) and matching dimensions. It cannot steer
from a stationary start. Velocity sensor output remains labelled `Vraw`
because its units/airspeed semantics have not been verified.

Within 40 horizontal blocks of home, HOME switches to ALT with wings level.
It continues flying: it does not land or orbit. Home Y is the recorded location;
the independently selected cruise altitude is the flight target. There is no
terrain avoidance. A navigation failure switches HOME to ALT; an altitude
sensor failure switches ALT/HOME to attitude HOLD and displays a warning.
These sensor failures are distinct from losing the cockpit connection.

## Cockpit pages

Touch PAGE to cycle HORIZON, FLIGHT, RADAR, AUTOPILOT, HOME, SYSTEM and
NAVIGATION. The advanced 1x1 monitor is set to text scale 0.5; at least 13x9
characters are needed. Rendering uses changed rows at up to 4 Hz.

- Horizon uses verified pitch/bank; missing readings show no false level line.
- Flight shows altitude, raw velocity, applied average thrust, engine/reserve
  coal, selected altitude and sensor read-error count. Coal is inventory,
  not remaining runtime.
- Radar is north-up, with selectable 50/100/250 range and ALL/NO ANIM/PLAYERS
  filters. Cyan=P player, red=H hostile, lime=A passive, magenta=S structure,
  yellow=? unknown. Set exact `entityKinds` overrides for structure entity
  IDs absent from the radar's category data. It cannot identify a category
  the radar does not supply without that mapping.
- Autopilot offers altitude +/-10, APPLY ALTITUDE, HOLD ATTITUDE, HOLD ALTITUDE,
  RETURN HOME, and ENABLE ASSIST. Mode changes require acknowledgement from 5.
- System shows controller state and RESTART FC5. Tap twice within four seconds
  for a manual restart through the adjacent computer peripheral.
- Navigation shows direct world position, horizontal home distance, course
  from computer 5 and whether home has been saved.

The computer-6 terminal also accepts `here`, `marker`, `home X Y Z [dimension]`,
`altitude N`, `mode MANUAL|HOLD|ALT|HOME`, `status`, `restart5`, and `quit`.
`status` prints full fault/ack details which may be clipped on the tiny monitor.
Typing `restart5` is itself an explicit manual restart. Pilot typewriter keys
are reserved for computer 5 and do not edit the HUD configuration.

## Link loss and recovery

Both computers read sensors directly. Wired Rednet through `bottom` carries
only cockpit configuration, accepted state and health information.
Loss of that link **does not change computer 5's flight mode or targets**.
The HUD displays FLIGHT LINK LOST on every page and disables new flight
requests until it receives fresh state. Sensor instruments can continue.

Requests include controller boot identity, state revision, a recent status
ticket and monotonic sequence. Old/repeated requests are rejected. Pilot
override invalidates previously offered mode commands. Reconnection reloads
accepted settings and never replays queued commands or automatically engages AP.
These checks prevent accidental stale command application, not hostile Rednet
impersonation.

Only an explicit HUD/system/console action reboots computer 5. Computer 5
can automatically reboot HUD-only computer 6 through adjacent `left`, after
checking ID 6. Defaults: 30-second startup grace, 10-second HUD-heartbeat
failure timeout, 60-second cooldown, at most three attempts per flight-program
run. The HUD heartbeat is tied to successful display updates. Failed wired
communication is also indistinguishable from a stopped HUD via heartbeat,
so persistent network faults exhaust that bounded retry budget. Adjacent
computer power methods work independently of the wired Rednet connection.

Manual FC5 restart uses adjacent `right`, checking ID 5 first. Its failure
cannot cause an automatic FC5 reboot. Make sure startup files are installed
before relying on either recovery action. Quitting HUD while live auto-recovery
is enabled will eventually cause computer 5 to restart it.

Missing critical flight sensors, a setter exception or a surface not following
its command latches a flight fault. Cleanup attempts zero thrust and released
gear outputs; the HUD can show the fault and offer manual reboot. Stale control
calculations also stop refreshing nonzero actuator demands. Detached or hung
hardware may prevent those cleanup writes from taking effect; a computer
reboot itself is not evidence that actuators reset. Test restart behavior on
the ground. Ctrl+T exits and attempts cleanup and original spring-limit restore.

## Tests and diagnostics

From the repository root:

```
lua FighterJet/tests/install.lua
lua FighterJet/tests/flight.lua
lua FighterJet/tests/runtime.lua
lua FighterJet/tests/hud_runtime.lua
lua FighterJet/tests/store.lua
lua FighterJet/tests/hud.lua
```

These cover attitude capture/mixing, binary thrust, pilot override, home
validation/navigation, sensor fallbacks, link loss, stale/replayed commands,
HUD restart limits, real flight runtime with mocked peripherals, cleanup,
interrupted configuration writes and colour/compact rendering. They do not
establish physical stability of the real modded aircraft.

Discovery/probes and earlier `test_wings`, `test_wing_angles`, `test_wing_mix`
remain available. The old tests were written before moving the typewriter;
change their `top` binding to `linked_typewriter_1` before using them again.

API references: [computer peripherals](https://tweaked.cc/peripheral/computer.html),
[Rednet](https://tweaked.cc/module/rednet.html),
[colour monitors](https://tweaked.cc/peripheral/monitor.html).

## Publishing a release

After code/test changes, generate a new manifest with
`python3 FighterJet/tools/build_release.py fighter-X.Y.Z`, run the tests,
commit the changes, tag that commit `fighter-X.Y.Z`, then push main and the
tag together. Never modify an already published tag: downloads are pinned
to that tag, with `main/FighterJet/release.json` only selecting the version.
The generated ZIP is a local convenience artifact and is ignored by Git.
