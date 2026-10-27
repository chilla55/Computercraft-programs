# Custom series transformer controller commissioning

This is a new controller project, separate from the existing regulator and
distributed controller. Start with the API probe; controller implementation
requires the report and the actual gauge, isolation and cooling wiring.

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

Return the full report, the deployed addon version if known, and how cooling
receives power. Include any external gauges or isolation breakers and their
locations in the chain.
This establishes the API and wiring needed for startup, regulation, and current
protection in the controller.

Local probe checks: `lua Powerplant/custom_transformer/tests/probe.lua`.
