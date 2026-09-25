# Distributed transformer controller

This is the new three-computer system on `main`. The standalone v18 snapshot is preserved at [`backup/standalone-regulator-v18`](https://github.com/chilla55/Computercraft-programs/tree/backup/standalone-regulator-v18), commit `929f894`. Keep that version available while commissioning this one. The distributed version has simulated peripheral/network tests; it has not yet been commissioned on the Minecraft server.

## Ownership

| Computer | Responsibility |
|---|---|
| UI/master | Configuration provider, portrait monitor, target requests, incident history, GitHub updates |
| Regulation | Variac direction detection, bank homing, voltage planning and movement |
| Protection/breaker master | Direct temperature/current/voltage/alignment checks; **the only role permitted to close breakers** |

All three have direct wired-peripheral access and can immediately open every configured input/output breaker. Local computer-to-computer messages use the same wired modem network as the gauges and components. Only the UI computer needs an optional ender modem, reserved for future external-network communication; this release does not open it for local rednet. Run exactly one role per computer and stop the old regulator before commissioning.

Trips happen before network reporting or disk writes. Every breaker receives an opening attempt even if another fails. Each computer stores a bounded persistent history and merges peer reports; multiple causes are retained, including explicit unknown openings. A delayed report can explain an unknown observation in the same operating cycle when its breaker-open command preceded the observation by at most two seconds. The original observation and every reported cause remain in the audit history; later trips are not assumed to have caused an earlier opening. Native contact commands remain sequential; this is not an atomic hardware safety interlock. Computers and peripherals must remain loaded to provide software protection.

The workers retain configuration without the UI. Losing or restarting the UI does not disable their regulation. Losing a worker's fresh heartbeat while energized opens the breakers. Rebooted workers first isolate the transformer. If both workers persisted a running state, protection automatically starts a fresh cycle after checking fresh temperatures, absence of thermal faults, open contacts and idle drives. Regulation then repeats direction checks, homing/alignment and output tuning before protection closes the output. This also works while the UI is offline. A stopped, maintenance or faulted state stays stopped; an alignment-only fault may complete its isolated automatic recovery described below. Other trips cancel automatic restart. A worker restart while its counterpart is still operating can cause a protection trip, which requires manual reset. An active trip cannot be cleared by a heartbeat or a repeated old start cycle.

## Installation

On **each** computer, from the computer root:

```text
wget https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Powerplant/distributed/install.lua install-transformer.lua
install-transformer.lua
```

To select an exact release, use `install-transformer.lua transformer distributed-1.1.11` with the current installer. The optional second argument reads the manifest from that immutable tag and rejects a different version. Without it, the installer checks the latest manifest using a timestamped URL to avoid stale caches. Choose an unused folder; existing installations are never overwritten.

The default installation folder is `transformer/`, which holds the original fallback and stable launcher and verifies every file against the GitHub release manifest. It does not replace an existing installation or alter startup scripts. HTTP must be enabled and GitHub accessible. Alternatively, copy all top-level `.lua` files from this directory into `transformer/` using a disk.

No existing configuration file is required. The master wizard starts with operating defaults, displays available peripherals and asks you to assign the gauges, bank members, drives and input/output breakers. It also prompts for the entry/exit ratios, target voltage and operating limits. Prompts use descriptive names, units, required/optional guidance and explanations of each component location. For example, “Voltage entering variacs” means the gauge after the entry transformer and before stage A; “Final output voltage” means the gauge after the exit transformer, before the output breakers. Existing settings in `/config/distributed-node.json` supply the defaults. Legacy files from the computer root are imported into `/config/` on first access if no new file exists; originals remain as backups. Enter (including spaces) keeps the shown value. Percentage prompts accept `10` or `10%`; invalid numeric input asks again without discarding the setup. Peripheral assignments are left blank on a fresh install and must be supplied before validation succeeds. An input breaker is mandatory. All contacts must be open and drives idle during commissioning. Use a unique cluster name for each transformer. Start the configuration wizard on all three computers together, selecting that same name. Each advertises its role over wired rednet; the master discovers the workers and the workers discover the master. IDs are saved after commissioning; runtime does not silently replace a missing worker with another ID.

The commands below use the default fallback folder, `transformer/`. Use your chosen folder if you supplied a different name.

On the UI computer:

```text
transformer/transformer.lua configure master
transformer/transformer.lua run
```

On the regulation computer (start its wizard while the master wizard is discovering):

```text
transformer/transformer.lua configure regulation
transformer/transformer.lua run
```

On the protection computer:

```text
transformer/transformer.lua configure protection
transformer/transformer.lua run
```

Once the master wizard finishes, start its `run` command so the waiting worker wizards can fetch their configuration. The workers discover the master ID and use their selected wired modem. Each validates its assigned ID. Successful configuration creates `/startup.lua` to launch that role automatically at boot, using the stable release launcher. If `/startup` or `/startup.lua` already exists, setup offers to move it to a numbered `/transformer-startup-backup-N/` folder before replacing it. Declining leaves startup unchanged. You can create or repair autostart later using `transformer/transformer.lua startup`, without repeating the configuration wizard. Autostart restores the saved operating intent through the precheck/startup sequence described above; it never simply closes contacts at boot. New installations remain stopped until the first Resume/reset. Configuration, operating state and thermal checkpoints live in `/config/distributed-node.json`, `/config/distributed-state.json` and `/config/distributed-thermal.json`. Each computer must see the configured peripheral names.

Use **Resume/reset** on the UI or protection computer once temperatures are fresh and every variac is at or below 125 C. It verifies open contacts and idle drives, clears the thermal latch without replenishing curve credits, and creates a new operating cycle. Regulation then:

1. Verifies input/output isolation and waits for any old sequence to finish.
2. Checks directions and homes misaligned parallel banks to minimum with no input supply.
3. Verifies every member's alignment and idle drives, then requests input connection. Protection closes the input contacts sequentially; regulation keeps shafts idle and outputs open until the entire input group is confirmed closed. Partial connection during this bounded wait is not treated as a homing fault.
4. Calculates absolute startup destinations for all three banks from one input/position snapshot, accounting for the exit ratio and whole-degree movement resolution. It starts all required bank drives together, using full-travel commands (for example, 200 degrees to 1 degree is one 199-degree move). Output breakers remain open. It then waits for every shaft to stop, verifies exact bank alignment and destination accuracy, and checks measured output voltage. After the full-travel preset, measured corrections use up to 8 degrees per bank, or 1 degree within 2% of target (widened to 8 only when the fine search cannot improve). Startup allows at most 12 plans in total and requires three consecutive readings within the configured acceptable error before requesting connection. Failure retains measured/predicted values for each completed plan and includes the output history when the plan budget is exhausted. It never connects merely because the budget expires. No further plan starts before the entire previous one is checked. The separate protection computer continues sampling every variac temperature during planning and motion; neither a full-travel command nor waiting for shafts to stop suspends the thermal trip curve.
5. Requests output connection; protection independently checks readiness and measured output voltage.
6. Regulates using bounded target ramps while protection continues independently.

During live regulation, each movement is followed by a check of every member in all three banks before another movement can begin. Startup instead executes one calculated three-bank movement batch and checks the entire batch before continuing. `getStatus().shaftSpeed` must be zero for every member and the gearboxes must be idle. Two unchanged consecutive position snapshots prevent comparing samples taken on opposite sides of a movement. Position spread is evaluated only for stopped banks; temperature, current and voltage protection continue while shafts move. Missing/invalid shaft speed or a movement timeout trips.

A stopped bank mismatch immediately trips the breakers. For this fault alone, protection automatically waits for the workers to stop and verifies isolation, idle drives and thermal readiness, then starts a new homing/tuning cycle. The affected bank is homed to minimum with all input/output contacts open. Exact alignment across all banks is required before reconnection. A jammed member, failed homing, unavailable sensor, temperature fault, missing worker, operator stop or unexplained contact opening remains latched for manual reset.

Series stages A/B/C may have different positions; members within a parallel bank must report exactly matching positions once stopped. The alignment check is independent of the movement verification tolerance. That separate setting only compares measured travel with the commanded destination; its internal configuration key remains `positionToleranceDegrees` for compatibility.

This first distributed release uses local single-mode regulation. The older plant-wide controller's optional grid-joining/generator-transition protocol is not connected to this new cluster yet. Do not use a plant-wide enable command as a substitute for its local reset/start handshake.

## UI and configuration

The master wizard selects the connected UI monitor, or `-` for its computer screen. Use an **advanced monitor one block wide and two blocks high**, attached to the same wired network or directly to the UI computer. The program selects 0.5 text scale and a portrait layout automatically. Touch the left/right arrows to change pages and Up/Down to scroll. Emergency stop remains at the top; maintenance and reset remain at the bottom. Touch a setting, then type its value on the computer keyboard (Enter saves; Escape cancels). The full field name/value appears on the computer during editing. If the monitor disconnects, the UI falls back to the computer screen and returns when it reconnects. Worker computers retain their local status screens; configuration edits belong to the master. The screen uses cached readings and changed-row rendering. Long status messages, incident reasons and peripheral names scroll horizontally with a pause at each end; buttons remain fixed. Faults show a red `TRIP:` label and scrolling reason instead of maintenance. An unexplained opening initially shows `TRIP: Checking reason...` while controller reports arrive. After two seconds without a cause it shows `TRIP: Unknown breaker opening`; later reports remain available in incident history. Operator-requested maintenance retains its separate maintenance display. Tabs show the diagram, member positions/temperatures, gauges, supported settings, incident history and updates. The source spark gap is labelled as **7,500 V generator protection**, not a software trip setting.

- **Emergency stop / E:** trip directly from this computer, then report it. The button works while editing; the shortcut works outside text editing.
- **Maintenance:** trip/latch all breakers open.
- **Resume/reset:** request protection-authorized startup. Regulation cannot authorize closure.
- **Quit:** explicit stop/trip and exit. A UI crash or missing UI computer does not otherwise stop the workers.
- **Target:** request a live nominal-target change from protection; regulation ramps toward it. Protection persists the accepted target.
- **Other settings:** require both workers stopped, open contacts and idle drives. Save a new revision on the master; stopped workers validate and cache it, then reboot isolated. Changing computer identities requires local recommissioning.

The temperature curve is the tested standalone policy: 125–126 C allows five seconds at the default scale, 130 C two seconds, 135 C half a second, and 140 C trips on the first measurement. One confirmed cooling recovery per level and five seconds at/below 125 C retain their previous behavior. Only protection samples temperatures for enforcement, in a dedicated task so breaker/position reads cannot stall its thermal scan. Native breaker current trips are preserved; an optional source-current gauge can enforce `sourceCurrentTripAmps`. The screen hides legacy settings that this runtime does not use.

## Automatic updates

Open the **Updates** page on the master and tap **Check now** for an immediate background check. This works even when automatic checks are disabled. The page shows the running, latest and staged versions, worker versions/staging status, and the check result. Apply/Later remain in the footer once a release is staged. Checking downloads and transfers files but never approves activation. Duplicate checks are disabled while a check or activation is in progress.

The master checks GitHub every five minutes when `autoUpdate` in its local `distributed-node.json` is not `false`. The approval-capable manifest is `approved-release.json` on `main`; program files are fetched from its immutable, versioned tag. Version numbers are compared numerically. A disk drive is not required.

Updates download and stage on all three computers while the current programs continue running. They never activate automatically. The UI displays **Ready**, with **Apply** and **Later** controls. Later retains the staged files; restarting also retains them but never retains approval. Apply requires maintenance, physically open contacts, idle drives and both workers stopped. A failed attempt consumes approval: press Apply again after resolving the reason. A release is downloaded into a staging directory, checked for SHA-256 digest, exact byte length, approved filenames and Lua syntax, then sent to workers in **4 KiB chunks**. Each chunk/file operation has an acknowledgement and bounded retries; identical retransmissions are accepted. Missing/conflicting chunks or bad hashes cannot activate.

All participants must stage the full release before the operator can successfully activate it. Each recipient checks open contacts and idle drives again before changing `active-release.json`. The first installed version is retained as the fixed fallback. Since applying updates requires maintenance, an update reboot remains stopped until Resume/reset. Mixed versions cannot authorize breaker closure; the operator can approve a retry of a partially completed rollout; workers already running the desired version acknowledge it without replacing their rollback pointer.

Storage is bounded to the original fallback, the current version and **one pending update**. Update directories end with their version (`releases/distributed-1.1.3`, for example). Downloading another release removes older pending releases; once the new runtime starts, it removes the superseded running release. It never deletes the original bundled fallback, running files, configuration or unrelated files. The outer installation folder and startup path remain stable across updates. Separately installed folders and startup backups are not automatically deleted.

### First deployment

No distributed 1.0.0 installation has been deployed on this setup. Install the current version directly on all three computers using the installation steps above; no migration or intermediate version is needed. Stop the old standalone regulator and isolate the transformer before commissioning the new workers.

The unused legacy `release.json` channel stays pinned to 1.0.0. The new installer and updater use `approved-release.json`, which requires operator approval for activation.

For offline recovery, isolate the transformer and run:

```text
transformer/transformer.lua rollback
transformer/transformer.lua run
```

This selects the original bundled fallback, and disables automatic update checks locally. Roll back all three computers to matching versions before restarting. To hold a rollback, keep `autoUpdate=false` on the master; re-enable it deliberately when ready. It does not clear thermal faults, configuration, incidents or operator state. Automatic updates never downgrade. A disk copy of the installation/configuration is still useful if HTTP/modems are unavailable.

Keep `distributed-node.json`, `distributed-state.json`, `distributed-thermal.json`, their `.tmp` recovery files, and the installation release folders directories. Do not delete thermal state to bypass a fault. Rednet IDs and protocol/session checks prevent accidental cross-talk/replays but are **not cryptographic authentication**; commission this on a trusted server/network. A hostile sender can impersonate IDs on plain rednet. SHA-256 verifies bytes against the trusted manifest, not the sender's identity.

## Tests and release process

From the repository root:

```sh
lua Powerplant/distributed/tests/core.lua
lua Powerplant/distributed/tests/updates.lua
lua Powerplant/distributed/tests/integration.lua
lua Powerplant/distributed/tests/ui.lua
lua Powerplant/distributed/tests/discovery.lua
lua Powerplant/distributed/tests/configure.lua
lua Powerplant/distributed/tests/install.lua
lua Powerplant/distributed/tests/config_storage.lua
lua Powerplant/distributed/tests/alignment.lua
lua Powerplant/distributed/tests/launcher.lua
lua Powerplant/distributed/tests/planner.lua
```

The startup planner tests verify reachable whole-degree destinations, measured-voltage corrections, unreachable targets, and the supplied 316-point single-variac calibration. Integration tests also cover nonlinear feedback requiring more than three corrections, nonconverging feedback, transient in-band readings, and an input opening between the contact and voltage reads. The integration fixture runs all three roles in separate Lua environments, with shared simulated peripherals, yielding native calls and CC-style event routing. It covers isolated bank homing, protection-only closure, UI loss, a hot follower, reset/restart, unknown contact opening and heartbeat loss even while hello messages still arrive, automatic restart from persisted running state without the UI, refusal to automatically clear stopped or thermal-tripped states, shafts moving despite an idle gearbox, automatic isolated realignment, and jammed recovery without repeated retries, concurrent full-travel startup, bounded correction plans and refusal to connect an unverified output, and both immediate 140 C trips and timed overheating trips during a long startup move. It does not model Minecraft's electrical or thermal physics.

To publish the next release, increment `release` in `common.lua`, regenerate `approved-release.json` with `python3 Powerplant/distributed/tools/build_release.py`, test the exact files, commit, and create the matching `distributed-X.Y.Z` tag at that commit. Push the tag before publishing the updated manifest on `main`. Never rewrite an existing release tag.
