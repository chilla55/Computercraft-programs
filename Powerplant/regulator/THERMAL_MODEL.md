# Variac thermal algorithm: inspected Power Grid 0.6.2 source

This is source analysis, not a change to the controller's protection policy. The fixed 29 A per-variac cap remains in place. The installed server JAR, configuration, biome and cooling arrangement have not been supplied.

## Source provenance

Inspected public repository `patryk3211/PowerGrid`, tag `v0.6.2`, commit `d681ac986adb92553ed4177c57e2e02bedb01672`. Its `gradle.properties` specifies Power Grid 0.6.2 / Minecraft 1.20.1. Also compared Minecraft 1.21.1 branch commit `0938be067fb71f311b3e5fd6c5f7cdaed722e241`, which also specifies 0.6.2: the variac class is identical, the relevant thermal calculations are identical, and the constants below match. The thermal class differs in Minecraft serialization signatures.

Primary references, pinned to the inspected 1.20.1 commit:

- [Variac electrical parameters and heat generation](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/kinetics/variac/VariacBlockEntity.java#L64-L116)
- [Thermal update, cooling and thresholds](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/electricity/base/ThermalBehaviour.java)
- [Variac default thermal power and mass](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/collections/ModdedBlocks.java#L682-L690)
- [Magnetizing resistance multiplier](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/config/CElectricity.java#L41)
- [Transformer coupling equations](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/electricity/sim/node/TransformerCoupling.java)
- [Parameter-refresh lifecycle](https://github.com/patryk3211/PowerGrid/blob/d681ac986adb92553ed4177c57e2e02bedb01672/src/main/java/org/patryk3211/powergrid/kinetics/base/TunedBlockEntity.java)

## Actual heat source

On each server tick, the variac adds the losses of two converged internal branches:

```text
P_heat = I_primary_stray² × R_primary_stray
       + I_magnetizing² × R_magnetizing
```

The heat routine does **not** directly add transmitted output power (`Vout × Iout`), nor does it explicitly add a separate secondary-coupling loss term. Branches without a converged solution are skipped for that tick. `lastCurrent` is the sum of the absolute primary-stray and magnetizing currents for sound; it should not be mistaken for an independent tap-current measurement.

For refreshed parameters, at full position and the default magnetizing multiplier of 10, Java float arithmetic gives:

```text
ratio = 1
R_primary_stray = 0.09375 ohm
R_magnetizing = 9374.0625 ohm
R_coupling = 0.09375 ohm
```

For steady forward DC operation, let `Vtap` and `Itap` be tap-to-common output voltage and outgoing load current. The coupling equation gives:

```text
V_internal = (Vtap + R_coupling × Itap) / ratio
I_magnetizing = V_internal / R_magnetizing
I_primary = ratio × Itap + I_magnetizing
V_primary = V_internal + R_primary_stray × I_primary
P_heat = R_primary_stray × I_primary² + V_internal² / R_magnetizing
```

This explains the approximate voltage-squared/current-squared contour from the tests, with small cross terms and terminal-voltage corrections. For arbitrary positions, use `refreshParameters()`'s actual ratio-dependent, float-rounded resistances rather than treating the full-position contour as universal. In algebra without rounding, the refreshed primary and magnetizing resistances are constant and coupling resistance scales approximately with ratio to the fourth power.

## Temperature update and defaults

The variac's thermal configuration defaults are **1000 W of internal dissipation** and thermal mass **4**. That 1000 W is not a transmitted-power rating.

Default overheat temperature is 175°C. Dissipation factor is:

```text
D = 1000 / ((175 - 25) - 22) = 7.8125 W/°C
ambient = 13.65 × biome_base_temperature + 7.1
```

Fan cooling multiplies D. The heat call precedes the superclass tick, which performs the thermal cooling update. Away from initialization/clamping and with no temperature tracking, the per-tick recurrence is:

```text
T_hot  = T_previous + P_heat / (20 × thermal_mass)
T_next = T_hot - D × cooling_multiplier × (T_hot - ambient) / (20 × thermal_mass)
```

With constant heat, no fan cooling and these defaults, the steady post-cooling temperature is:

```text
T_steady = ambient + P_heat × (1/D - 1/(20 × thermal_mass))
         = ambient + 0.1155 × P_heat
```

The discrete heating/cooling order matters: using only the continuous approximation `ambient + P_heat / D` does not reproduce these readings as closely. The analysis script checks the closed form against repeated discrete ticks; it is not an in-game test.

Smoke starts at **125°C** (`175 - 50`) when thermal particles are enabled. `isOverheated()` starts at **175°C**. An overheated block whose temperature keeps rising can be destroyed after the counter reaches the third qualifying tick; falling/non-rising temperature resets the counter while overheated. Disabling explosive deconstruction changes destruction into block removal rather than making overheating harmless. Overheating can also be globally disabled.

Consequently, the user's 124.9°C readings match a **just-below-smoke** operating contour under these defaults, not the default destruction threshold. This does not authorize increasing the controller's limit.

## Comparison with the user's measurements

Assumptions: full arm position; reported voltage/current are tap-side readings; refreshed parameters; default thermal settings; no extra cooling; ambient **18.02°C** (the code's value for biome base temperature 0.8). The ambient value is an assumption, not a measured server fact.

| Tap voltage | Tap current | Calculated internal heat | Predicted steady temperature | Reported temperature |
|---|---|---|---|---|
| 2794.067626953125 V | 30.973 A | 926.220 W | 125.00°C | Not reported |
| 981.9259033203125 V | 93.303 A | 922.682 W | 124.59°C | Not reported |
| 1985.8565673828125 V | 72.945 A | 925.351 W | 124.90°C | 124.9°C |
| 2793.994873046875 V | 30.864 A | 925.532 W | 124.92°C | 124.9°C |

The two equal-temperature measurements closely match the independently retrieved source model. The small differences can reflect reported precision, stabilization and model/measurement details; they are not proof of the installed configuration.

Reproduce the calculation:

```sh
python3 Powerplant/regulator/analysis/variac_thermal_v062.py
```

## Initial construction differs from refresh

There is a material discrepancy in the inspected source:

- `buildCircuit()` derives the mutual branch directly from secondary inductance and does not apply the configurable magnetizing-resistance multiplier.
- `refreshParameters()` divides secondary inductance by ratio squared before applying coupling, then applies that multiplier.
- At full ratio with multiplier 10, the initial magnetizing resistance is 937.40625 ohm, while the refreshed value is 9374.0625 ohm.
- `TunedBlockEntity` refreshes during arm motion and after reading arm state. Circuit rebuilding calls `buildCircuit()` again.

This is a source-observed discrepancy, not a demonstrated explanation for any particular in-game explosion. Do not assume the refreshed model always applies immediately after construction or a circuit rebuild. A robust thermal controller should preferably obtain actual temperature, branch currents/resistances or internal heat directly from the addon, or explicitly validate the active circuit state and installed implementation. The addon 1.2.0 API now supplies native measured temperature via `getThermalStatus()`. Controller v15 uses that reading directly for protection.

Before adopting thermal-model protection, confirm installed version, magnetizing multiplier, variac thermal power/mass, biome/cooling, and which circuit-parameter state is active. The controller does not use this model to authorize loading or calculate trip temperatures. Its default policy uses measured temperature: the v15 inverse-time curve with per-level cooling credits, or at least 140°C on the first reading. The former 29 A estimate is available only as an explicitly selected legacy protection mode.
