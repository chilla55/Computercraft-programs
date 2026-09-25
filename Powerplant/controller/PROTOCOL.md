# Main controller interfaces

## Local transformers

The main controller implements the existing [`powerplant.regulator.v1`](../regulator/PROTOCOL.txt) protocol without modifying it. Only configured transformer IDs are accepted. Their `node` must match the rednet sender ID. Status supplies the session and `lastSeq`; outgoing sequences resume above it, including after master restart. A v17 autonomous regulator session is observed without unsolicited enable/disable; its reported local intent is adopted, while an explicit pending disable is retained. Legacy sessions clear enable intent. Previously seen retired sessions cannot replace the new one.

Transformer messages are checked against the configured telemetry timeout and at most 250 ms future clock skew. A fresh accepted `status` is required to mark a node online; ACKs do not refresh status or establish contact state. Non-recoverable fault/stopped events immediately clear enable intent. A recoverable bank-synchronisation event preserves existing enable intent so the regulator can perform its own bounded, isolated recovery; stale grid/node data still inhibits it. A reset disables first and waits for acknowledged disable plus both actual contacts open before sending `reset`. It completes only on later fault-free standby status. Reset request timeout is five seconds.

Each regulator receives the measured reference for its configured output `bus` and role (`generator`, `consumer`, `transmission`). Their individual source, internal and output gauge values remain telemetry and do not replace the main grid measurement.

## Future network link: `powerplant.controller.v1`

The schema remains version 1 with additive role/bus, generator-power and scoped control fields. Timestamps below use `os.epoch('utc')` **milliseconds**. Transformer thermal internals retain their existing seconds-based timestamps, as specified by the regulator protocol. Computer clocks must agree within the freshness/skew limits.

Main → configured upstream controller, every 0.5 s:

```lua
{
  schema=1, type="plant_status", node=MAIN_COMPUTER_ID,
  session="main-id:boot-epoch:nonce", sentAt=EPOCH_MS,
  grid={available=true, healthy=true, voltage=2640, sampledAt=EPOCH_MS},
  current={configured=true, available=true, amps=42, sampledAt=EPOCH_MS},
  measurements={2640,42}, -- [voltage,current], only when BOTH local readings are fresh
  transmission={
    configured=true, ratio=10, -- output/input; ratio omitted if unknown
    input={configured=true,available=true,volts=2640,sampledAt=EPOCH_MS},
    output={configured=true,available=true,volts=26400,sampledAt=EPOCH_MS},
    measuredRatio=10, expectedOutputVoltage=26400
  },
  transformers={
    {id=7,name="Transformer A",online=true,desired=false,resetPending=false,
     status=LAST_REGULATOR_STATUS,notice="...",ack=LAST_ACK,event=LAST_FAULT_OR_STOP}
  },
  generators={
    {id=12,name="Generator A",available=true,voltage=7200,current=8,
     measurements={7200,8},sampledAt=EPOCH_MS,sentAt=EPOCH_MS}
  }
}
```

`grid.reason` explains an inhibition. `available=false` means a reading must not be used, even if a historical value remains present. `healthy` additionally applies local voltage range and any configured aggregate current limit. For transformers, `online=false` marks the entire cached `status` stale. `desired` is the operator's current request, **not proof of closed breakers**. Historical fault events can remain after newer fault-free status; use the latest status for current faults. Diagnostic ratio values require usable inputs; they do not imply efficiency or synchronised sampling.

Generator → main, from an explicitly configured generator ID:

```lua
rednet.send(MAIN_ID, {
  schema=1, type="generator_status", node=os.getComputerID(),
  sentAt=os.epoch("utc"), sampledAt=ACTUAL_MEASUREMENT_TIME_MS,
  measurements={voltage,current} -- volts, signed amps
}, "powerplant.controller.v1")
```

Alternatively supply named `voltage=...` and `current=...`. If both forms are present, they must agree. Both values must be finite numbers. Pair entries are always **voltage first, current second**; do not mix electrical locations or different generators into one pair. Both readings should belong to the same sampling cycle; use the older sample timestamp. Missing values must not be encoded as zero.

Generator `sentAt` must be fresh within the node timeout and strictly increase for that sender. `sampledAt` must be within the local sample-age limit, with at most 250 ms future skew. Stale generator samples become unavailable rather than being treated as current draw of zero. Other-generator telemetry is diagnostic: it does not presently control transformer joining or add to the local meter value.

Raw two-element messages without IDs/timestamps, unknown senders, conflicting values and unrecognised commands are rejected. Physical generator actuation belongs to a separate rednet generator controller.

## Generator power and control capability

Add both `maxPowerWatts` (finite, non-negative) and `currentPowerWatts` (finite, signed according to the sender's orientation) to `generator_status`. They are reported watts, not calculated from V×I. If either is supplied, both are required. Current watts may exceed reported maximum during overload; the main controller preserves this observation. Older voltage/current-only senders remain compatible but produce `powerAvailable=false`. Stale data also clears `powerAvailable`. The main sends these fields upstream for the upstream's generation/voltage planning algorithm.

A generator controller which supports commands additionally advertises:

```lua
controlSession="generator-id:boot-epoch:nonce",
lastCommandSeq=LAST_APPLIED_SEQUENCE, -- integer >= -1
supportedCommands={start=true,stop=true},
running=true -- actual machine feedback, not command intent
```

Commands sent to that generator use the same rednet protocol:

```lua
{schema=1,type="generator_command",node=GENERATOR_ID,session=CONTROL_SESSION,
 seq=NEXT_COMMAND_SEQUENCE,sentAt=EPOCH_MS,command="stop"} -- or "start"
```

The generator implementation must restrict senders to its configured main-controller ID, reject stale/session-mismatched/non-increasing commands, implement idempotent start/stop (not a clutch toggle), and retain its own interlocks. It replies with `{schema=1,type="generator_ack",node=GENERATOR_ID,session=CONTROL_SESSION,seq=N,sentAt=EPOCH_MS,accepted=BOOLEAN,reason=OPTIONAL}`. An accepted ACK is only intent acceptance. Subsequent status with `lastCommandSeq>=N` and actual `running` matching the command clears `commandPending`. Restarting the generator changes its session and invalidates pending command state. The main never directly operates its clutch.

## Upstream requests

Only the configured `upstreamId` is accepted. First read `plant_status.session` and `lastUpstreamSeq`; send a strictly increasing integer sequence for this main-controller session. Restarting the main changes its session and clears temporary transition intent. It adopts autonomous regulators' reported operating state without stopping them. Commands use:

```lua
{schema=1,type=COMMAND,node=UPSTREAM_ID,session=MAIN_SESSION,
 seq=NEXT_UPSTREAM_SEQUENCE,sentAt=EPOCH_MS, ...}
```

Reply: `{schema=1,type="upstream_ack",node=MAIN_ID,session=MAIN_SESSION,sentAt=EPOCH_MS,seq=N,accepted=BOOLEAN,reason=OPTIONAL}`. Acceptance is not evidence of achieved voltage, open contacts or stopped machinery. Normal sender timestamp freshness/skew checks apply; stale/misaddressed envelopes are discarded.

**`generator_transition`** adds `direction="connect"` or `direction="disconnect"` plus the fields below. Legacy **`shutdown_prepare`** is the disconnect alias:

```lua
generator=GENERATOR_ID,
eventId="shutdown-plan-42",
expiresAt=EPOCH_MS_PLUS_AT_MOST_30000,
targets={{node=GENERATOR_TRANSFORMER_ID,voltage=2638},
         {node=CONSUMER_TRANSFORMER_ID,voltage=239}}
```

Every target must be fresh, live, already enabled, fault-free and on a ready bus, with regulator temporary-target capability enabled. The target must fit its bus limits and regulator-advertised limits. Validate all targets atomically: an invalid entry changes none. A different active event on an affected node is rejected. Updating an event replaces its target membership; removed nodes return toward nominal. No transformer is implicitly enabled. Event IDs identify a preparation, not an electrical safety guarantee. The upstream chooses targets; this controller does not calculate load sharing from generator capacity.

**`shutdown_cancel` / `shutdown_complete`** adds `eventId` and removes that event's temporary targets. Expiry likewise removes them. The regulator ramps back to nominal; it does not abruptly reset its setpoint. Cancellation cannot clear a local fault or re-enable a unit.

**`generator_isolate`** adds `generator=ID`, requests disable on every associated transformer, and leaves them disabled. Inspect subsequent transformer feedback; the ACK is not isolation confirmation.

**`generator_command`** adds `generator=ID, command="start"` or `"stop"`. The generator must have fresh telemetry and advertise that command and a valid control session. Stop additionally requires an association and fresh status from *every* associated transformer acknowledging its latest explicit disable sequence, `enabled=false`, and both `breakers[].closed=false`. Then the command is forwarded to the generator's advertised control session. Start does not enable any transformer.

There is no generic upstream transformer-enable/reset command; those remain local monitor actions. In-flight generator requests are not automatically retried or treated as completed on send; an upstream retry must use a new sequence and generator commands must be idempotent.

## Additional plant telemetry

`buses[]` includes each bus's ID, label, nominal voltage, measured `grid` and optional `current`. The legacy top-level `grid/current/measurements` still describe `local`. Each `transformers[]` item additionally reports `role`, `bus`, `connectionMode`, `generatorId`, its own dispatch-grid record, `transition` and `transitionAtTarget`. Generator items add reported watts, `powerAvailable`, control capabilities/session, `running`, `commandPending` and `commandAck`.

`transitionAtTarget` requires fresh live status, matching event ID, no fault, both contacts closed, and active target/output within the regulator's advertised `targetToleranceVolts`. It is not an assessment of remaining generation capacity. The upstream must decide how long to observe it and whether to proceed with isolation.


## Transport and independence

All inter-computer messages use rednet over the configured ender modem. Local peripheral sharing may use a separate wired modem, but the program opens rednet only on its selected wireless modem. The runtime can verify wireless versus wired, not ender versus ordinary wireless hardware. Computer IDs, sessions and timestamps are unchanged. Main telemetry adds `network={available,reason?,modem}` describing the local modem, not proof that any peer received a packet.

Upstream communication and generator telemetry are optional for local regulation. Their loss does not disable unrelated transformer control. Modem/monitor absence is retried without terminating main supervision. v17 autonomous regulators continue in local single mode when supervisory data expires. Explicit disable remains persistent; local protections continue to apply. A locally configured `autonomousFallback=false` retains legacy lease-required isolation.


## Independent local operation (regulator v17)

Regulator status adds `autonomousFallback`, `controlMode="single"|"supervised"` and `supervisionAvailable`. `enabled` is effective local operating intent, including autonomous operation, rather than merely the last received dispatch flag. The main observes a newly discovered autonomous unit without sending a startup disable. It begins active supervision only for an explicit operator request or temporary generator-transition plan. Loss of telemetry or supervisory measurements relinquishes supervision, never implicitly requests shutdown. During active supervision, confirmed bus/current-protection violations may still request an explicit disable.

MASTER → regulator `release` uses the usual regulator envelope/session/sequence; it discards temporary targets and grid supervision but **never changes persistent enable/disable intent**. Supervisor exit sends this to autonomous units. Explicit **DISABLE ALL** still sends `dispatch enabled=false`. Legacy regulators without autonomous capability retain their old lease behavior.

An operator enable with unavailable supervisory measurements can use `dispatch enabled=true, autonomous=true`, supported only when locally opted into autonomous operation. This starts the single-mode algorithm; it does not invent a grid reading. Normal supervised dispatch still includes a real fresh output-bus measurement. Fault reset always requires effective operation disabled first.

The main's per-transformer telemetry adds `autonomous` (capability) and `supervising` (whether this main is actively issuing dispatches). `transitionAtTarget` cannot be true for an autonomous unit which has already returned to single mode. Temporary target requests remain optional, locally disabled by default and bounded to generator connection/disconnection preparations. No load-based target changes are generated by normal local regulation.
