# Custom series transformer controller

This is a standalone CC: Tweaked controller for three custom PowergridAddon
transformers connected in series. It uses their built-in telemetry and computer
controllers, with no external gearboxes, gauges or breakers required by the
program. It is separate from the existing regulator and distributed controller.

The manually specified chain is:

| Stage | Peripheral | Uncooled limit | Cooled limit |
| --- | --- | --- | --- |
| 1 | `powergrid_addon_variac_0` | 10 A | 40 A |
| 2 | `powergrid_addon_variac_1` | 10 A | 40 A |
| 3 | `powergrid_addon_variac_2` | 40 A | 200 A |

Source voltage is approximately 264,001 V before stage 1. The desired voltage
after stage 3 is approximately 240 V. Hardware ratings cannot be distinguished
through the computer and must be configured manually. Startup and unpowered
operation use the uncooled limits. A condition label in a probe report does
not verify cooling or authorize using a cooled rating.

## Install and run

After these files are published to `main`, run on the in-game computer:

```text
wget https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Powerplant/custom_transformer/controller.lua transformer.lua
transformer.lua run
```

The single file contains the controller, planner and terminal display. It creates
`transformer.lua.cfg` beside the program on first launch, with the names and
manual ratings above. To change them or any voltage/timing limit:

```text
transformer.lua configure
```

This opens the configuration in the in-game editor; save, close and launch
`transformer.lua run` again. Configuration editing does not start the chain.
`transformer.lua status` prints raw telemetry without changing hardware state.
Stop any other controller for this chain before running this one.

`run` starts the chain. **X** disables all stages and stays stopped; **S** makes
an explicit new start attempt; **Q** disables all stages and quits. Faults stay
stopped until S or another explicit run. The program attempts to disable every
configured stage, starting at the output, even if another stage cannot be
reached. A failed shutdown command is reported. Ctrl+T and ordinary Lua failures
inside the control runtime also run shutdown cleanup. No startup entry or
automatic updater is installed.

## Ratio planning and startup

The planner gives the largest voltage reduction to the final 200 A cabinet.
It places that cabinet near its configured minimum ratio at the **maximum**
allowed source voltage, with 10% ratio headroom by default (`finalRatioReserve`).
The two 40 A cabinets split the remaining reduction equally. This leaves stage
3 room to regulate a rising input without immediately hitting the minimum ratio.

With defaults and a 264,001 V source, the calculated plan is approximately:

| Cabinet | Ratio (output/input) | Output voltage |
| --- | --- | --- |
| `powergrid_addon_variac_0` (40 A) | 0.262431 | 69,282 V |
| `powergrid_addon_variac_1` (40 A) | 0.262431 | 18,182 V |
| `powergrid_addon_variac_2` (200 A) | 0.013200 | 240 V |

At an ideal 200 A final load, stage 1's output current is about 0.69 A and
stage 2's about 2.64 A; the final cabinet carries the high output current.
These are ratio-based estimates, excluding winding losses and fan consumption;
protection always checks actual measured currents on both windings.

Startup disables all three cabinets, calculates the ratios, requests them while
disabled and waits for `getRatio()` to confirm the actual positions. It enables
stage 1, waits for three stable readings, then stage 2. With stage 3 still
disabled, it corrects that stage's ratio from its measured input voltage and
waits for the actual ratio to settle before enabling it. Stage 3 must then reach
240 V +/-2 V for three readings. Each startup phase times out after 45 seconds.

In service the first two ratios stay fixed; stage 3 uses measured input voltage
and bounded feedback to compensate for source changes and small winding losses.
Feedback trim is limited to +/-5%. The controller trips if it cannot maintain
the voltage within 45 seconds. It does not keep raising the ratio to compensate
for a heavily overloaded, collapsed output. This plan prioritizes the final
cabinet's share of the reduction; it is not a calibrated thermal-loss optimizer.

The default configured source range is 132,000–316,802 V; the planned target must
fit the configured ratio range (0.01–1 by default). Final output above 264 V,
reversed output polarity, invalid/missing telemetry, native thermal or voltage
faults, an unexpected disabled stage, changed upstream ratios, and temperatures
at or above 95 C cause shutdown. These are manual controller settings, not
inferred server configuration values.

## Cooling and current protection

Each stage begins with its manually configured uncooled current limit. Its
cooled rating becomes available only after three powered-input samples confirming
all installed fan slots working and powered, no blocked fans, and full speed
and airflow. Losing any of those conditions immediately returns that stage to
the uncooled limit. During fan spin-up this deliberately uses the uncooled
rating rather than interpolating a higher rating. Fans can already be powered
while a winding is disabled; those confirmed readings count during startup too.
A load exceeding the uncooled limit before cooling is confirmed will trip;
starting this controller cannot actively throttle that load.

The applied limit is always the **lower** of that manual rating and the reported
`getCoolingStatus().capacity`, so native thermal derating also lowers the software
limit. Both input and output winding currents are checked by magnitude. Excess
current trips the chain; the program does **not** call `setCurrentLimit` or
`setTargetVoltage`. The addon advertises these methods on transformers, but the
local implementation rejects them for this hardware. Native thermal trips
must be cleared on the hardware before restarting; the controller does not
repeatedly call `setEnabled(true)` to reset a trip.

Reads are batched through CC's parallel API, followed by a 0.25-second polling
delay. They are not an atomic electrical snapshot. Software shutdown is reactive
and depends on the computer and peripheral connection remaining operational;
hardware winding protection remains necessary. Cutting computer power cannot
execute cleanup, and this API has no verified watchdog or external isolation
contact feedback. The controller is not a continuous load-current clamp.

## Deployed API evidence

The supplied server report captured all three transformer APIs and cooling
tables. Stage 0 was running at 264,001 V input / 55,020 V output; stage 1 was
disabled but cooled at 40 A, and stage 2 disabled/uncooled at 40 A. The report
label `unpowered` was descriptive, not proof of each cabinet's actual state.
The controller reads the deployed methods shown in that report, including
`getCoolingStatus`, `getRatio`, both winding voltages/currents, `getTemperature`
and string-valued `getStatus`. The two control calls are `setRatio` and
`setEnabled`. Ratio bounds and control arguments are based on the available
addon implementation; commissioned behavior still needs verification in game.

## Run the probe

Copy `probe.lua` to the in-game computer with wired access to the three
transformers and related peripherals, then run:

```text
probe.lua unpowered
```

This writes `custom-transformer-unpowered.txt`. If the hardware is already
operating in a powered/cooled condition, capture that separately with:

```text
probe.lua powered
```

The probe does not change the operating condition. It lists all connected
peripheral types and methods, requests advertised `help`/`methods`
documentation, and takes three samples of explicitly recognized read methods.
Unfamiliar methods are listed without being invoked; help output and the method
list are used to choose any additional calls needed for a second probe. Errors
and missing transformers are recorded. Reports are flushed progressively;
interruption closes the report and preserves what was captured. Repeated runs
automatically choose a new filename. An optional second argument sets an explicit
output filename, which must not already exist.

The local addon checkout at `/mnt/nvme2tb/minecraft/PowergridAddon/` is newer
than the deployed server. Its `ComputerIntegration.java` identifies candidate
reads such as `getInputVoltage`, `getOutputVoltage`, `getInputCurrent`,
`getOutputCurrent`, `getRatio`, `getTemperature`, and `getCoolingStatus`.
The probe calls each only when advertised by the deployed peripheral. API help
is optional: a peripheral without `help` still gets a method inventory and
recognized telemetry reads. The report does not assume server parity with the
local source, or call setters to discover their argument ranges.

In the newer local source, transformers use `setRatio` and `setEnabled`;
`setTargetVoltage` and `setCurrentLimit` explicitly reject transformer calls.
`getRatio` returns the actual ramped ratio, and cooling telemetry includes
effective capacity and fan state. These are implementation clues to verify
against deployed reports, not guarantees about the server API.

Additional probe reports can help diagnose server-version differences, cooling
state or readings during commissioning.

## Local checks

```text
lua Powerplant/custom_transformer/tests/probe.lua
lua Powerplant/custom_transformer/tests/controller.lua
lua Powerplant/custom_transformer/tests/runtime.lua
```

The simulation checks calculation, staged startup, source drift and small
winding losses, cooling transitions, both winding current limits, faults and
best-effort shutdown. It does not reproduce the Minecraft electrical solver.
