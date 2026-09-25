# Distributed transformer controller

This is the new three-computer system on `main`. The standalone v18 snapshot is preserved at [`backup/standalone-regulator-v18`](https://github.com/chilla55/Computercraft-programs/tree/backup/standalone-regulator-v18), commit `929f894`. Keep that version available while commissioning this one. The distributed version has simulated peripheral/network tests; it has not yet been commissioned on the Minecraft server.

## Ownership

| Computer | Responsibility |
|---|---|
| UI/master | Configuration provider, local screen, target requests, incident history, GitHub updates |
| Regulation | Variac direction detection, bank homing, voltage planning and movement |
| Protection/breaker master | Direct temperature/current/voltage/alignment checks; **the only role permitted to close breakers** |

All three have direct wired-peripheral access and can immediately open every configured input/output breaker. Computer-to-computer messages use ender modems. Ender modems do not replace the wired connections needed to access peripherals. Run exactly one role per computer and stop the old regulator before commissioning.

Trips happen before network reporting or disk writes. Every breaker receives an opening attempt even if another fails. Each computer stores a bounded persistent history and merges peer reports; multiple causes are retained, including explicit unknown openings. A delayed report can explain an unknown observation in the same operating cycle when its breaker-open command preceded the observation by at most two seconds. The original observation and every reported cause remain in the audit history; later trips are not assumed to have caused an earlier opening. Native contact commands remain sequential; this is not an atomic hardware safety interlock. Computers and peripherals must remain loaded to provide software protection.

The workers retain configuration without the UI. Losing or restarting the UI does not disable their regulation. Losing a worker's fresh heartbeat while energized opens the breakers. Rebooted workers start isolated and latched; they need a new explicit reset/start. An active trip cannot be cleared by a heartbeat or a repeated old start cycle.

## Installation

On **each** computer, from the computer root:

```text
wget https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Powerplant/distributed/install.lua install-transformer.lua
install-transformer.lua
```

The installer creates `transformer/` and verifies every file against the GitHub release manifest. It does not replace an existing installation or alter startup scripts. HTTP must be enabled and GitHub accessible. Alternatively, copy all top-level `.lua` files from this directory into `transformer/` using a disk.

Leave your existing `dual-variac-config.json` in the **UI computer's root**. The initial master wizard imports that configuration, displays available peripherals and lets you assign the gauges, bank members, drives and input/output breakers. Enter keeps the saved default. An input breaker is mandatory. All contacts must be open and drives idle during commissioning. Choose the two worker computer IDs before starting them.

On the UI computer:

```text
transformer/transformer.lua configure master
transformer/transformer.lua run
```

With the UI running, on the regulation computer:

```text
transformer/transformer.lua configure regulation
transformer/transformer.lua run
```

On the protection computer:

```text
transformer/transformer.lua configure protection
transformer/transformer.lua run
```

Workers ask for the configured master ID and their own ender-modem peripheral name, then fetch their configuration over rednet. Each validates its assigned ID. Role settings and cached configuration are saved in `distributed-node.json` in the computer root. Each computer must see the configured peripheral names. Do not run these commands from different working directories later.

Use **Resume/reset** on the UI or protection computer once temperatures are fresh and every variac is at or below 125 C. It verifies open contacts and idle drives, clears the thermal latch without replenishing curve credits, and creates a new operating cycle. Regulation then:

1. Verifies input/output isolation and waits for any old sequence to finish.
2. Checks directions and homes misaligned parallel banks to minimum with no input supply.
3. Verifies every member's alignment and idle drives, then requests input connection.
4. Tunes the output while output breakers remain open.
5. Requests output connection; protection independently checks readiness and measured output voltage.
6. Regulates using bounded target ramps while protection continues independently.

A jammed member, inconsistent bank, unavailable sensor, missing worker, or unexpected breaker opening latches the installation off. A later Resume/reset starts a fresh alignment/tuning sequence. Series stages A/B/C may have different positions; members within a parallel bank must stay aligned.

This first distributed release uses local single-mode regulation. The older plant-wide controller's optional grid-joining/generator-transition protocol is not connected to this new cluster yet. Do not use a plant-wide enable command as a substitute for its local reset/start handshake.

## UI and configuration

No monitor is required. Every advanced computer can show its local status; configuration edits belong to the master. The screen uses cached readings and changed-row rendering. Tabs show the diagram, member positions/temperatures, gauges, supported settings and incident history. The source spark gap is labelled as **7,500 V generator protection**, not a software trip setting.

- **Emergency stop / E:** trip directly from this computer, then report it. The button works while editing; the shortcut works outside text editing.
- **Maintenance:** trip/latch all breakers open.
- **Resume/reset:** request protection-authorized startup. Regulation cannot authorize closure.
- **Quit:** explicit stop/trip and exit. A UI crash or missing UI computer does not otherwise stop the workers.
- **Target:** request a live nominal-target change from protection; regulation ramps toward it. Protection persists the accepted target.
- **Other settings:** require both workers stopped, open contacts and idle drives. Save a new revision on the master; stopped workers validate and cache it, then reboot isolated. Changing computer identities requires local recommissioning.

The temperature curve is the tested standalone policy: 125–126 C allows five seconds at the default scale, 130 C two seconds, 135 C half a second, and 140 C trips on the first measurement. One confirmed cooling recovery per level and five seconds at/below 125 C retain their previous behavior. Only protection samples temperatures for enforcement, in a dedicated task so breaker/position reads cannot stall its thermal scan. Native breaker current trips are preserved; an optional source-current gauge can enforce `sourceCurrentTripAmps`. The screen hides legacy settings that this runtime does not use.

## Automatic updates

The master checks GitHub every five minutes when `autoUpdate` in its local `distributed-node.json` is not `false`. The manifest is on `main`; program files are fetched from its immutable, versioned tag. Version numbers are compared numerically. A disk drive is not required.

Updates only install while the master verifies physical isolation and both workers report stopped. They never interrupt an operating transformer to force an update. A release is downloaded into a staging directory, checked for SHA-256 digest, exact byte length, approved filenames and Lua syntax, then sent to workers in **4 KiB chunks**. Each chunk/file operation has an acknowledgement and bounded retries; identical retransmissions are accepted. Missing/conflicting chunks or bad hashes cannot activate.

All participants must stage the full release before activation starts. Each recipient checks open contacts and idle drives again before changing `active-release.json`. The old files are retained. Reboots start latched, requiring explicit Resume/reset. Mixed versions cannot authorize breaker closure; the updater can retry a partially completed rollout, skipping workers already running the desired version.

For offline recovery, isolate the transformer and run:

```text
transformer/transformer.lua rollback
transformer/transformer.lua run
```

This selects the previous retained release, or the original bundled files, and disables automatic update checks locally. Roll back all three computers to matching versions before restarting. To hold a rollback, keep `autoUpdate=false` on the master; re-enable it deliberately when ready. It does not clear thermal faults, configuration, incidents or operator state. Automatic updates never downgrade. A disk copy of the installation/configuration is still useful if HTTP/modems are unavailable.

Keep `distributed-node.json`, `distributed-state.json`, `distributed-thermal.json`, their `.tmp` recovery files, and the `transformer/releases/` directories. Do not delete thermal state to bypass a fault. Rednet IDs and protocol/session checks prevent accidental cross-talk/replays but are **not cryptographic authentication**; commission this on a trusted server/network. A hostile sender can impersonate IDs on plain rednet. SHA-256 verifies bytes against the trusted manifest, not the sender's identity.

## Tests and release process

From the repository root:

```sh
lua Powerplant/distributed/tests/core.lua
lua Powerplant/distributed/tests/updates.lua
lua Powerplant/distributed/tests/integration.lua
```

The integration fixture runs all three roles in separate Lua environments, with shared simulated peripherals, yielding native calls and CC-style event routing. It covers isolated bank homing, protection-only closure, UI loss, a hot follower, reset/restart, unknown contact opening and heartbeat loss even while hello messages still arrive. It does not model Minecraft's electrical or thermal physics.

To publish the next release, increment `release` in `common.lua`, regenerate `release.json` with `python3 Powerplant/distributed/tools/build_release.py`, test the exact files, commit, and create the matching `distributed-X.Y.Z` tag at that commit. Push the tag before publishing the updated manifest on `main`. Never rewrite an existing release tag.
