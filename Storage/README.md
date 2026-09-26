# Create stock network monitor

`stock_monitor.lua` shows network item counts, current vault items, maximum
capacity, and a horizontal fill gauge from **0** to **maximum capacity**.
It runs on a CC: Tweaked computer terminal or monitor and only reads storage.

## Installer and automatic updates

After the `Storage` files are published to this repository's `main` branch, run
these commands in the in-game computer (HTTP must be enabled):

```text
wget https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Storage/install.lua install_storage.lua
install_storage.lua storage
storage/start.lua --run
```

The installer creates a new `storage` directory and adds
`/startup/stock_monitor.lua` by default, so the monitor and updater launch on boot.
It does not replace an existing startup entry. Use
`install_storage.lua storage --no-startup` to opt out. `--startup` remains accepted
for compatibility.
If you already launch the old monitor from another startup script, remove that
old launch call to avoid running two copies.
[CC: Tweaked startup directories](https://tweaked.cc/guide/startup.html).

Always use **`storage/start.lua --run`** for automatic and manual update checks.
The launcher checks after configuration is ready and every five minutes thereafter.
It downloads newer monitor releases from this repository's `main` branch, verifies
SHA-256, size, version, and Lua syntax, stages the complete file, then restarts the
monitor automatically. HTTP/check failures leave the installed program running.
Updates pause while the configuration wizard is open. A prior program is retained
as `stock_monitor.lua.bak`; an uncaught application error restores it automatically.
A rejected build's checksum is recorded so it is not immediately installed again.
The updater does not repair configuration errors by rolling back configuration.

Configuration and history files are preserved. Recent history survives automatic
restarts. `update-status.txt` contains the latest check result. The installer is
also the stable launcher; automatic releases replace the monitor program, not the
launcher itself. To upgrade the launcher later, stop the program and replace
`storage/start.lua` with the latest `Storage/install.lua`.

To migrate a standalone installation, stop it and copy its existing
`stock_monitor.lua.cfg` and `stock_monitor.lua.history` (if present) into `storage/`
before launching. Adjust names if the old program used a different filename.

## Computer control panel

With the external monitor selected, the computer terminal shows configuration
and update controls while the monitor displays the storage dashboard:

- **C:** choose the ticker, vaults, and display again on the computer terminal.
  The monitor keeps its last screen during configuration.
- **U:** immediately check for and automatically install a newer release.
  Results appear on the terminal; requires the launcher.
- **N:** toggle the monitor between summary and full losses list.
- **Q:** stop both the dashboard and updater.

You can also run `storage/start.lua --run --configure` or
`storage/start.lua --run --list` for configuration or peripheral diagnostics.

## Manual setup

1. Copy `stock_monitor.lua` to the in-game computer.
2. Connect the Stock Ticker, optional monitor, and vaults using wired modems
   and cable. Right-click the modems to enable peripheral access. Connect each
   physical multiblock vault **once**, otherwise it may be counted twice.
3. Run `stock_monitor`. Select the ticker, display, and vaults by number.
   The inventory list may contain chests or machines: select only the vaults
   belonging to your network. Enter vault numbers separated by spaces: `1 2 3`.

Settings are saved beside the program in `<program-name>.cfg`. Run
`stock_monitor --configure` after adding/removing vaults or changing networks.
Run `stock_monitor --list` to inspect peripheral names and methods.
Press **N** on the computer to switch between the summary and the full losses
list; press **C** to configure again and **Q** to quit. Use the installer and
launcher above for automatic startup and update checks.

The ticker must expose `stock()`. If your installed Create integration lacks
this method, choose 0 for the ticker to use the vault display alone.
Vaults must expose `size()`, `list()`, and `getItemLimit()`.
A **3-block-wide by 2-block-high monitor** is supported: the program uses compact
text so totals, the capacity gauge, and the five-minute losses appear together.
Long loss lists automatically cycle pages. Larger monitors use text scale 1 when
at least 38 columns and 18 rows fit, otherwise scale 0.5. Layout uses the actual
character dimensions reported by the monitor. The minimum is 26 columns by 10 rows.
Refreshes occur five seconds after each scan; large inventories can take longer.

## Meaning of the readings

- **Network:** all item counts from the ticker's `stock()`. This can include
  storage outside the selected vaults. The ticker's `list()` is its payment
  inventory and is not used.
- **Items:** current items inside the selected vaults.
- **Maximum:** sum of the reported limits of every vault slot, including empty
  ones. Uses actual reported limits rather than a hardcoded capacity per block.
- **Vault fill:** vault items divided by maximum items. The gauge runs from
  0 to maximum, green below 75%, orange from 75%, red from 90%.
- **Slots used:** occupied slots divided by total slots. Tools, items that stack
  to 16, and partial stacks can exhaust slots before the item gauge reaches 100%.
  Maximum is nominal full-size-stack capacity, not guaranteed free space for
  every item type.

The standard ticker API exposes neither storage capacity nor its vault list.
Select all relevant vaults to cover the whole vault network. Stock Links alone
are insufficient: the computer also needs wired peripheral access to the vaults.

If any selected vault becomes unavailable, the gauge is replaced by an error
and retries automatically instead of displaying partial totals. Ticker failure
leaves the vault gauge running. A disconnected monitor falls back to the terminal
and is reused when reattached with the same name. Sequential reads may briefly
differ while items are moving.

API references: [Create Stock Ticker](https://wiki.createmod.net/users/cc-tweaked-integration/logistics/stock-ticker)
and [CC: Tweaked inventory](https://tweaked.cc/generic_peripheral/inventory.html).

## Five-minute decreases

The **NET LOSSES / LAST 5 MIN** list shows items whose current stock is lower
than it was approximately five minutes ago, sorted by largest loss first.
For example, `minecraft:iron_ingot -240` means there are 240 fewer ingots than
at the start of the window. Production and consumption offset each other:
this is net stock change, not a measurement of gross consumption.

Trends use the Stock Ticker's entire network when configured, otherwise the
selected vaults. Counts are grouped by registry item name (NBT variants are
combined). Items that disappear completely are counted as zero. Positive or
unchanged items are omitted.

The first result requires five minutes of successful readings. The rolling
per-item snapshots are saved after each scan in `<program-name>.history`, beside
the configuration. Writes use a temporary file and retain a `.bak` copy for
interrupted-write recovery. This is the recent five-minute window, not an
unbounded lifetime log. The program reports history write failures on the monitor.

Recent history is reloaded after a restart or automatic update. History resets
when the latest saved reading is more than 60 seconds old, the stock source or
vault selection changes, the clock moves backwards, or a storage/ticker read
fails. A failed ticker never silently switches the trend to vault-only data. The rolling
baseline is the latest sample at or before five minutes ago; scan timing means
the actual window may be slightly longer and is shown alongside the page number.

Screens with at least 14 rows show losses below the gauge. Press **N** for a
full-screen list on any supported screen. Long lists cycle pages every roughly
10 seconds, advancing on refresh. Missing data and the initial collection period
are labeled explicitly.

## Local checks

Run these from the repository root:

```text
lua Storage/tests/stock_monitor.lua
lua Storage/tests/updates.lua
```

Tests use simulated peripherals, screens, HTTP downloads, and filesystems;
verification inside Minecraft is still needed.

## Publishing a monitor update

Increase the `stock-monitor-version` header in `stock_monitor.lua`, then run:

```text
python3 Storage/tools/build_release.py
```

Publish the monitor and generated `Storage/release.json` together to `main`.
Clients install strictly newer versions. A transient mismatch during publication
is rejected and retried later. Same-version changes and downgrades are ignored.
The installer, monitor, and manifest must be published before the install command
can work; editing local files alone does not publish a release.
