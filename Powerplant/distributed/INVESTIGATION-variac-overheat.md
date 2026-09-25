# Bank C destruction during movement: investigation

Status: cause not established. User confirms Power Grid 0.6.2 and believes the
failure occurred during live adjustment. No further energized experiment has
been performed. Controller simulations do not model Power Grid circuit/thermal
physics or prove that an energized movement is safe.

## Incident evidence

Cycle `2:1790348143082:1342743857:1`, distributed-1.1.23:

- Protection's thermal event `:2` records variac `powergrid:variac_0`, stage C,
  at 195.1752777 C. Its trip command began at 1790348180375.
- The missing-peripheral event `:3` began at 1790348180426, 51 ms later.
  This timestamps detection, not the precise destruction time.
- The thermal event records verified-open completion at 1790348180775,
  400 ms after the trip command began. This includes opening and verification;
  it does not identify when each contact physically opened.
- The regulation event “Protection is latched” is a subsequent interlock.
- Previous temperature, actual movement command, per-member positions during
  movement, internal currents and electrical solver state were not recorded.

The five-second warm-temperature allowance did not defer this trip: >=140 C
trips on the first qualifying sampled reading. A 195 C triggering reading does
not tell us how long the device was above 140 C before that sample.

## Parallel misalignment remains a plausible explanation

Different positions across the three *series stages* A/B/C are allowed. Unequal
ratios between members whose inputs and outputs are paralleled *within one
stage* can drive circulating current. Mechanical linkage does not prove equal
arm positions or equal electrical solver state throughout movement.

`common.lua:checkAlignment()` rejects position spread only when a bank is
stationary. `stationaryBanks()` takes sequential peripheral snapshots and
checks shaft speeds and gearbox state. During movement, exact comparison is
skipped because sequential reads can observe different game ticks. The existing
`tests/alignment.lua` explicitly exercises this behavior, including accepting a
moving-bank snapshot with unequal member positions. It rejects that mismatch
when stopped, and never clears a moving bank for connection.

Therefore, the absence of a bank_misaligned incident does NOT rule out dangerous
misalignment during motion. Faster polling cannot make separate native reads an
atomic snapshot. A 1-degree command also does not guarantee protection if a
mismatch can heat the block faster than detection and source isolation.

## Confirmed upstream resistance-update inconsistency

Inspected Power Grid tag v0.6.2, commit
`d681ac986adb92553ed4177c57e2e02bedb01672`.

The variac uses the four-terminal `TransformerCoupling` factory with the common
node shared between primary and secondary. Its `Tr2P2S.couple()` stamps the
coupling diagonal as **-resistance**. It inherits `setResistance()`, which adds
**newResistance - oldResistance** to that diagonal. The network method applies
that change additively. For this subtype, the required delta has the opposite
sign. The base method's sign is appropriate for the other positive-stamp
subtypes, so changing the base sign globally would be incorrect.

Compiled the unmodified upstream TransformerCoupling.java against minimal
recording-matrix stubs (not a Minecraft world or full network solver):

| State | Incrementally updated diagonal | Fresh stamp at same resistance |
|---|---:|---:|
| R changes from 0.06 to 0.08 | -0.04 | -0.08 |
| R then changes to 0.13 | +0.01 | -0.13 |

The two-terminal subtype serves as a control and agrees after updating.
This confirms a source-level matrix update defect: history can affect the
matrix, and sufficiently large changes can reverse the effective diagonal sign.
It does **not** prove this defect caused the user's explosion. The actual
resistances, last matrix rebuild and currents are absent from the incident.
A mod-level fix should make Tr2P2S incremental updates match its negative fresh
stamp, then test actual solver behavior and all coupling subtypes.

Reproduce using a checkout of the pinned upstream source and a JDK:

```
python3 Powerplant/regulator/analysis/check_coupling_update_v062.py /path/to/PowerGrid
```

Primary sources:

- [Coupling stamps and resistance setter](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/electricity/sim/node/TransformerCoupling.java)
- [Additive matrix update](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/electricity/sim/ElectricalNetwork.java)
- [Variac circuit and heat calculation](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/kinetics/variac/VariacBlockEntity.java)

## Other checked mechanisms

The initial construction and refresh paths use different magnetizing/stray
parameters, documented in `../regulator/THERMAL_MODEL.md`. This is another
source-observed discrepancy, not a demonstrated cause here.

A suspected missed final arm-position refresh was ruled out against the examined
Catnip implementation: `settled()` tests both previous/current value and target,
so the final moving tick still refreshes parameters. Catnip source examined:
https://github.com/Creators-of-Create/Ponder/blob/mc1.21.1/dev/common/src/main/java/net/createmod/catnip/animation/LerpedFloat.java
The exact installed Catnip artifact has not been independently inspected.

Power Grid defaults have thermal mass 4, overheat temperature 175 C, and destruction
after the third qualifying rising-temperature overheated tick. Tick scheduling
and configuration affect elapsed time. These defaults permit destruction faster
than a complete multi-peripheral Lua scan and sequential breaker operation.
The native heat calculation uses internal branch I-squared-R losses; a single
source gauge cannot establish every parallel member's internal current.

[Native thermal behavior](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/electricity/base/ThermalBehaviour.java)

## Next evidence needed

Prefer a mod/addon diagnostic captured on the server thread in one operation:

- All members of a bank: arm position, shaft speed, configured ratio AND actual
  coupling ratio/resistance used by the electrical simulation.
- Internal primary/magnetizing currents and resistances, calculated heating
  power, temperature, and server tick number.
- Movement command, source/output contact states and matrix rebuild/update time.

An atomic bank snapshot can establish mechanical mismatch; internal circuit
readings can distinguish equal arms with inconsistent electrical state. A
native per-tick trip that disconnects the source can reduce detection latency;
its timing still needs validation against the solver/thermal tick order.

The 1.1.24 input-first opening change reduces command latency. It is not a
validated fix for this destruction. Keep the affected installation isolated;
validate suspected mod defects in an isolated test world before another
energized production movement test. No runtime tuning or protection thresholds
were changed as part of this investigation.

## Existing-peripheral inspection

The operator prefers existing peripherals; no addon method is required by this
check. `tools/inspect-variac-bank.lua` is a standalone, read-only preliminary
inspection. On the master, enter maintenance, quit the UI to its shell, and run:

```
wget https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Powerplant/distributed/tools/inspect-variac-bank.lua inspect-variac-bank.lua
inspect-variac-bank C
```

Keep the workers running in maintenance. The script requires all configured
breakers open and gearboxes idle before collecting samples, checks again between
sample rounds, and issues no opening, closing or movement commands. It captures
three position/thermal samples per configured bank member and method names.
Missing members are recorded without skipping healthy members. Report:
`/config/variac-bank-inspection.json` (overwritten by the next inspection).
This does not establish alignment during energized motion or expose internal
solver state. It is a baseline for deciding whether an isolated mechanical test
is appropriate, not a request to repeat the destructive energized test.


## Isolated movement test (isolated-bank-4)

Replace missing members and update their configured names first. Enter maintenance,
quit the master UI, and leave workers stopped/in maintenance. Run the standalone
`tools/test-isolated-bank.lua ALL` to exercise all three banks together; A, B or C
selects just one bank. The script never closes contacts. It verifies all configured
breakers are open throughout, checks measured temperatures, and verifies any
unselected banks remain still. Selected banks may start misaligned while isolated;
independent direction probes and a full minimum homing command establish an
aligned baseline. It aborts if any selected bank does not home and align.

For the configured 315-degree range, each bank receives the same **91 test moves**
after direction probing and homing:

- Short reversals of 1, 2 and 4 degrees around 10%, 50% and 90% travel.
- Medium reversals of 8, 16, 32 and 64 degrees around mid travel.
- Long moves including both full-range directions and intermediate destinations.
- Two repetitions of a mixed sequence with short/medium moves and reversals.
- A final return to minimum; original operating positions are not restored.

Commands to selected gearboxes are dispatched consecutively, then their movements
are monitored together. This is overlapping motion, not guaranteed same-tick starts.
Every bank's command timestamp and direction is logged. No next movement starts
until every selected bank stops, passes two unchanged snapshots, is exactly aligned
within its own parallel members, and passes direction/distance/endpoint checks.
One bank's failure aborts the entire run. All input openings are attempted before
outputs on completion or abort, including Ctrl+T. An already-issued native sequence
may finish after abort; no further movement is issued.

Selected-member position reads are prioritized immediately after commands and run
back-to-back before temperature/other-bank checks. Read order alternates to help
identify sampling skew. Per-bank summaries record observed shaft-motion sample
counts and maximum apparent spread. Absence of moving samples is reported explicitly;
sequential peripheral reads cannot establish exact same-tick alignment. This test
does not reproduce the energized electrical solver or its heating behavior.

`/config/isolated-bank-test.json` is replaced after each completed move and on exit.
It contains all planned destinations and compact movement endpoints, initial/home/final
snapshots, per-bank sampling coverage and a bounded history retaining the first plus
most recent samples (32 total) to limit disk usage. Full-report serialization is
preflighted before movement. Temperatures must be <=125 C initially and remain below
140 C during the test. Missing peripherals, lost isolation, movement timeout, incorrect
travel or settled mismatch abort and save a partial report. Keep the transformer in
maintenance for report review after the test.
