-- Ground identification only. Space advances; Left Shift aborts.
-- Only gearshift setOutputs is written. Thrusters and spring limits are untouched.
local args = { ... }
assert(#args <= 2 and (args[2] == nil or args[2] == "refresh"),
    "Usage: test_wings [pulse-seconds] [refresh]")
local refresh = args[2] == "refresh"
local pulse = args[1] and tonumber(args[1]) or 0.6
assert(pulse and pulse >= 0.1 and pulse <= 1, "Pulse must be 0.1..1 seconds")
local gears = { "directional_gearshift_2", "directional_gearshift_3" }
local springs = { "torsion_spring_0", "torsion_spring_1" }
local phases = {
    { gear = gears[1], side = "RIGHT wing", left = true, right = false },
    { gear = gears[1], side = "RIGHT wing", left = false, right = true },
    { gear = gears[2], side = "LEFT wing", left = true, right = false },
    { gear = gears[2], side = "LEFT wing", left = false, right = true },
}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function call(name, method, ...) return peripheral.call(name, method, ...) end
local function keys()
    local values = call("top", "getPressedKeyCodes")
    assert(type(values) == "table", "Invalid typewriter key data")
    local held = {}
    for _, code in ipairs(values) do held[code] = true end
    if held[340] then error("Aborted with Left Shift", 0) end
    return held
end
local function stopAll()
    local errors = {}
    for _, gear in ipairs(gears) do
        local ok, err = pcall(call, gear, "setOutputs", false, false)
        if not ok then errors[#errors + 1] = gear .. ": " .. tostring(err) end
    end
    return errors
end
-- Complete preflight before any actuator writes.
for _, name in ipairs({ "top", gears[1], gears[2], springs[1], springs[2],
    "thruster_8", "thruster_9", "thruster_10", "thruster_11" }) do
    assert(peripheral.isPresent(name), "Missing peripheral: " .. name)
end
keys()
for i = 8, 11 do
    local name = "thruster_" .. i
    assert(call(name, "getThrottle") == 0 and not call(name, "isActive"),
        name .. " must be off before testing wings")
end
for _, gear in ipairs(gears) do
    assert(not call(gear, "isLeftPowered") and not call(gear, "isRightPowered"),
        gear .. " already has an active command; stop existing controls first")
end
for _, spring in ipairs(springs) do
    assert(finite(call(spring, "getAngle")), "Invalid angle: " .. spring)
end
local path, index = "fighter-wings.txt", 0
while fs.exists(path) do
    index = index + 1
    path = "fighter-wings-" .. index .. ".txt"
end
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local started = os.clock()
local function emit(line)
    file.writeLine(line)
    file.flush()
end
local function waitForSpace()
    -- Require release before accepting each press, including the first one.
    repeat sleep(0.1) until not keys()[32]
    repeat sleep(0.1) until keys()[32]
end
local ok, err = pcall(function()
    emit("Fighter wing test v3: nominal pulse " .. pulse .. " seconds")
    emit("Command refresh: " .. (refresh and "every 0.05s requested during pulse" or "off (single write)"))
    emit("Samples read angles, running flags, then active gear flags sequentially; times bracket reads.")
    emit("Side labels use the recorded positions and west-facing nose.")
    for _, spring in ipairs(springs) do
        emit(spring .. " initial limit: " .. textutils.serialize(call(spring, "getLimit")))
    end
    print("Move to the typewriter with the craft on the ground.")
    print("Space: next pulse. Left Shift: abort.")
    print("Order: RIGHT command-left, RIGHT command-right,")
    print("       LEFT command-left, LEFT command-right.")
    print("Release Space after each pulse. Wait for the surface to settle.")
    for number, phase in ipairs(phases) do
        print("Ready for test " .. number .. ": " .. phase.side)
        waitForSpace()
        local baseline, low, high = {}, {}, {}
        for i, spring in ipairs(springs) do
            local angle = call(spring, "getAngle")
            assert(finite(angle), "Invalid spring angle")
            baseline[i], low[i], high[i] = angle, angle, angle
        end
        local label = phase.left and "setOutputs(true,false)" or "setOutputs(false,true)"
        emit("TEST " .. number .. " " .. phase.side .. " " .. phase.gear .. " " .. label)
        emit("Baseline: " .. textutils.serialize(baseline, { compact = true }))
        local function sample(stage)
            keys()
            local readStarted = os.clock() - started
            local angles, running = {}, {}
            for i, spring in ipairs(springs) do
                local angle = call(spring, "getAngle")
                assert(finite(angle), "Invalid angle: " .. spring)
                angles[i] = angle
                low[i], high[i] = math.min(low[i], angle), math.max(high[i], angle)
            end
            for i, spring in ipairs(springs) do running[i] = call(spring, "isRunning") end
            local status = call(phase.gear, "getStatus")
            assert(type(status) == "table", "Invalid gearshift status")
            emit(string.format("%.2f..%.2f %s angles=%s running=%s gearLeft=%s gearRight=%s",
                readStarted, os.clock() - started, stage,
                textutils.serialize(angles, { compact = true }),
                textutils.serialize(running, { compact = true }),
                tostring(status.leftPowered), tostring(status.rightPowered)))
        end
        keys()
        call(phase.gear, "setOutputs", phase.left, phase.right)
        local deadline, stopping, refreshes = os.clock() + pulse, false, 0
        -- The cutoff runs independently of telemetry reads and file writes.
        parallel.waitForAny(function()
            while true do sample("pulse"); sleep(0.05) end
        end, function()
            sleep(pulse)
            stopping = true
            local errors = stopAll()
            assert(#errors == 0, table.concat(errors, "; "))
        end, function()
            -- Independent of telemetry; do not let sample reads slow renewal.
            while true do
                sleep(0.05)
                if refresh and not stopping and os.clock() < deadline then
                    call(phase.gear, "setOutputs", phase.left, phase.right)
                    refreshes = refreshes + 1
                end
            end
        end)
        stopping = true
        local errors = stopAll()
        assert(#errors == 0, table.concat(errors, "; "))
        emit("Commands released; refresh writes: " .. refreshes)
        local released = os.clock()
        repeat sample("released"); sleep(0.1) until os.clock() - released >= 3
        for i, spring in ipairs(springs) do
            emit(string.format("%s delta range: %.4f .. %.4f", spring,
                low[i] - baseline[i], high[i] - baseline[i]))
        end
        print("Test " .. number .. " finished. Note which surface moved and its direction.")
    end
    emit("All four tests completed")
end)
-- Best effort on normal completion, Ctrl+T, Shift, or a read/write failure.
local cleanupErrors = stopAll()
if not ok then pcall(emit, "Stopped: " .. tostring(err)) end
for _, message in ipairs(cleanupErrors) do
    print("RELEASE FAILED: " .. message)
    pcall(emit, "RELEASE FAILED: " .. message)
end
file.close()
print("Saved " .. path)
if not ok then error(err, 0) end
assert(#cleanupErrors == 0, "Could not release every gearshift; see report")
