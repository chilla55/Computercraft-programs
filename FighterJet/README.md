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
in **preview**, computer 6 starts the HUD. Preview calculates demands,
accepts configuration and sends status, but writes no flight actuators and
does not automatically reboot the HUD. Explicit manual FC5 restart is still
available on the HUD.

Persistent files live directly under `/fighter`:

- `jet_config.lua`: calibration, peripheral names, flight tuning, recovery.
- `hardware.lua`: mechanical wing mapping.
- `startup_mode.lua`: `return "preview"` initially; set to `return "live"`
  only after calibration. Both verification flags in config must also be true.
- `jet_state.a` / `.b`: saved home and cruise altitude.

Updates preserve these files exactly. A first install also imports these
files from an existing flat installation in the computer root, if present.
That includes its selected startup mode. Defaults for a new release remain
available inside `/fighter/releases/fighter-X.Y.Z/` for comparison; new
configuration fields are not silently merged into your calibrated settings.

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
  They operate together at 0 or 1; there is no differential engine steering.
- Set `calibrated=true` only after those sensor/control signs are checked.
  Flight refuses live mode if either verification flag is false.

Start with the proven ground wing tests, then short manual flight checks
before relying on attitude hold or autopilot. Gains are starting values.
The gimbal supplies two tilt angles, not yaw or a full attitude quaternion;
sustained inverted/aerobatic flight is not validated.

## Pilot controls

| Input | Action |
| --- | --- |
| W / S | Nose down / nose up |
| A / D | Bank left / right |
| Space | Latch full thrust |
| Left Shift | Latch thrust off; wins if Space is also held |
| Release W/S/A/D | Capture current pitch/bank on that axis and hold it |

Computer 5 reads `linked_typewriter_1` directly. Any of these six keys,
including opposing keys held together, overrides autopilot into MANUAL.
MANUAL retains attitude assistance. Startup waits for all six keys to be
released. Restarting computer 5 starts MANUAL with thrust off; saved home
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
  RETURN HOME, and MANUAL. Mode changes require acknowledgement from 5.
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
