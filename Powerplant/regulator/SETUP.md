# Power plant regulator — setup (v10)

This package contains the three-variac controller and its rednet protocol. The controller has been checked with 29 simulated scenarios; the new master integration still needs in-game testing. An existing plant master must implement the protocol in `PROTOCOL.txt`; a plant-master program is not included.

## Files

- `transformer_controller.lua` — complete controller, unchanged from the latest delivered v10.
- `startup_optional.lua` — optional boot launcher. It does not run automatically under this name.
- `PROTOCOL.txt` — message schema, timestamps, session/sequence handling, telemetry, enable/disable and fault reset.
- `SETUP.md` — these instructions.

## Electrical layout

Generator → optional input step-down → input gauge → variac A → variac B → variac C → fixed output step-up → output gauge → plus/minus breakers → grid.

Both gauges measure across the appropriate circuit terminals, not across the length of a wire. The output gauge must be after the output transformer and on the transformer side of BOTH breakers, so it remains readable while disconnected. For managed joining, the master needs a separate grid-side measurement that remains live when this unit is disconnected.

For the approximately 7.14–7.25 kV generator discussed, use the input 5:1 step-down before the input gauge (200 primary / 40 secondary turns, if using the 240-turn allowance). The output transformer remains 2.5× step-up (68 primary / 170 secondary). The controller's multiplier is the OUTPUT transformer's 2.5, not the combined ratio of both fixed transformers.

These ratios address voltage, not the current capacity of the variacs or transformers. Parallel banks are not commissioned by this script: it reads one variac per stage. Other mechanically linked members are not individually monitored for position or current sharing.

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

4. Configure:

   ```lua
   transformer_controller.lua configure
   ```

5. Keep the nominal target at **2640 V** and the output multiplier at **2.5**. Defaults aim for ±0.1 V with a ±1 V fallback. Exact accuracy depends on actuator resolution and source/load stability.
6. Choose the master mode described below, then start:

   ```lua
   transformer_controller.lua run
   ```

The saved configuration is `dual-variac-config.json` for compatibility with older versions, despite there now being three stages. Configuration versions 7–9 are accepted and migrated in memory; `configure` saves version 10. Version 7 peripheral mappings are migrated to the three-stage mapping above. An old default 8° coarse limit is upgraded to direct full-travel correction. Custom coarse limits are retained.

## Standalone mode

Set master ID to **-1**. The controller opens both breakers, checks each shaft direction with a small movement, positions from actual readback and measured output, then connects and regulates directly to the configured nominal target. There is no homing rotation.

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

## Protection and recovery

- Grid samples expire after 2 seconds; the enabled dispatch lease expires after 3 seconds. Missing, stale or unhealthy grid information opens both breakers and waits for fresh healthy enable dispatches.
- Input below the calculated minimum opens both breakers. At 2640 V with 2.5× step-up the calibration gives approximately 1056.032 V before additional losses; `inputHeadroomVolts` can raise the threshold. The threshold follows the temporary matching/ramp target while joining.
- Default input ceiling: 2800 V, based on the user's observed variac limit. Breakers are downstream and cannot isolate variacs from excessive input voltage or prevent no-load overheating.
- Default output-overvoltage trip: 10% above the current active setpoint. It is separate from the regulation accuracy band.
- Native breaker overcurrent settings remain in effect. `breakerTripAmps=0` means PRESERVE existing settings, not disable protection. If the native setting is already Off, this option leaves it Off.
- Overvoltage/close failures allow three retries after the initial failure. Both contacts are opened and output is retuned from fresh stable readings before reclosing. Fault spikes are never retained as a model correction factor.
- Other hardware faults stay latched in managed mode. Disable, explicitly reset, wait for fault-free standby, then enable again. Normal enabled heartbeats cannot clear a hardware fault.
- Q or Ctrl+T stops the program and attempts to open and verify both contacts. An already-issued gearshift sequence may still finish.
- Log: `transformer-controller.log`. Capacity failures include voltage, positions, current and the estimated remaining output range.

Rednet ID/session/sequence checks are not cryptographic authentication. Use a trusted network. CC tasks are cooperative; computer shutdown or chunk unloading stops software protection.

## Optional start on computer boot

Only after configuring and testing, copy `startup_optional.lua` to the computer root. If no startup file exists, rename it to `startup.lua`. If one already exists, add the launch line to your existing boot process rather than overwriting it.

The launcher requires an existing configuration. In standalone mode it may automatically close the breakers once checks pass. In managed mode it waits for fresh master dispatches. Stop any competing controller first.
