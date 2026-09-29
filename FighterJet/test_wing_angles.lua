-- Automated ground test: limit magnitude + sustained gearshift direction.
-- Starts after a delay. Left Shift or Ctrl+T aborts; no thruster writes.
local args = { ... }
assert(#args <= 1, "Usage: test_wing_angles [start-delay-seconds]")
local delay = args[1] and tonumber(args[1]) or 20
assert(delay and delay >= 0 and delay <= 300, "Delay must be 0..300 seconds")
local wings = {
    { side = "right", gear = "directional_gearshift_2", spring = "torsion_spring_0", upSign = -1 },
    { side = "left", gear = "directional_gearshift_3", spring = "torsion_spring_1", upSign = 1 },
}
local function call(name, method, ...) return peripheral.call(name, method, ...) end
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function checkAbort()
    local held = call("top", "getPressedKeyCodes")
    assert(type(held) == "table", "Invalid typewriter data")
    for _, code in ipairs(held) do
        if code == 340 then error("Aborted with Left Shift", 0) end
    end
end
local function stopAll()
    local failures = {}
    for _, wing in ipairs(wings) do
        local ok, err = pcall(call, wing.gear, "setOutputs", false, false)
        if not ok then failures[#failures + 1] = wing.gear .. ": " .. tostring(err) end
    end
    return failures
end
local function requireStopped()
    local failures = stopAll()
    assert(#failures == 0, table.concat(failures, "; "))
end
local function waitNeutral(wing, abortable)
    local deadline, stable = os.clock() + 5, 0
    repeat
        if abortable then checkAbort() end
        local angle = call(wing.spring, "getAngle")
        assert(finite(angle), "Invalid spring angle")
        local running = call(wing.spring, "isRunning")
        stable = not running and math.abs(angle) <= 0.5 and stable + 1 or 0
        if stable >= 3 then return end
        sleep(0.1)
    until os.clock() >= deadline
    error(wing.spring .. " did not settle at neutral", 0)
end
local function thrustersOff()
    for i = 8, 11 do
        local name = "thruster_" .. i
        assert(call(name, "getThrottle") == 0 and not call(name, "isActive"),
            name .. " must be off for this ground test")
    end
end
-- Preflight is read-only. Do not take over an already-active mechanism.
checkAbort()
thrustersOff()
for _, wing in ipairs(wings) do
    assert(not call(wing.gear, "isLeftPowered") and not call(wing.gear, "isRightPowered"),
        wing.gear .. " already active; stop existing controls first")
    assert(not call(wing.spring, "isRunning"), wing.spring .. " already moving")
    local angle = call(wing.spring, "getAngle")
    assert(finite(angle) and math.abs(angle) <= 0.5, wing.spring .. " must start at neutral")
    wing.originalLimit = call(wing.spring, "getLimit")
    assert(finite(wing.originalLimit) and wing.originalLimit % 1 == 0
        and wing.originalLimit >= 1 and wing.originalLimit <= 360, "Invalid original limit")
end
local path, index = "fighter-wing-angles.txt", 0
while fs.exists(path) do
    index = index + 1
    path = "fighter-wing-angles-" .. index .. ".txt"
end
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local started, touched = os.clock(), false
local function emit(line) file.writeLine(line); file.flush() end
local ok, err = pcall(function()
    emit("Automated wing angle test v1: hold 2 seconds; requested command refresh 0.05 seconds")
    emit("Limits change only at neutral; thrusters untouched. Sequential telemetry, not atomic.")
    for _, wing in ipairs(wings) do
        emit(wing.side .. " " .. wing.gear .. " " .. wing.spring .. " originalLimit=" .. wing.originalLimit)
    end
    print("Ground test starts in " .. delay .. " seconds. Move where you can see the surfaces.")
    print("Automatic: RIGHT up 5/10, down 5/10; LEFT up 5/10, down 5/10.")
    print("Left Shift aborts. Do not run other controls during this test.")
    local readyAt = os.clock() + delay
    while os.clock() < readyAt do checkAbort(); sleep(0.1) end
    thrustersOff()
    -- From here on, always release commands and restore changed limits on exit.
    touched = true
    requireStopped()
    local number = 0
    for _, wing in ipairs(wings) do
        for _, direction in ipairs({ "up", "down" }) do
            for _, magnitude in ipairs({ 5, 10 }) do
                number = number + 1
                for _, other in ipairs(wings) do waitNeutral(other, true) end
                thrustersOff()
                checkAbort()
                wing.limitTouched = true
                call(wing.spring, "setLimit", magnitude)
                assert(call(wing.spring, "getLimit") == magnitude,
                    wing.spring .. " rejected limit change; stopping")
                local target = magnitude * wing.upSign * (direction == "up" and 1 or -1)
                local left, right = target < 0, target > 0
                emit(string.format("TEST %d %s %s target=%d limit=%d", number, wing.side, direction, target, magnitude))
                print("Test " .. number .. ": " .. wing.side .. " " .. direction .. " " .. magnitude .. " degrees")
                local stopping, refreshes, tailSamples, tailWithin = false, 0, 0, 0
                local minAngle, maxAngle = math.huge, -math.huge
                call(wing.gear, "setOutputs", left, right)
                local holdStart = os.clock()
                local deadline = holdStart + 2
                parallel.waitForAny(function()
                    while true do
                        checkAbort()
                        local readStart = os.clock()
                        local angle = call(wing.spring, "getAngle")
                        assert(finite(angle), "Invalid angle during hold")
                        assert(math.abs(angle) <= 20, "Unexpected angle over 20 degrees; stopping")
                        local running = call(wing.spring, "isRunning")
                        local status = call(wing.gear, "getStatus")
                        assert(type(status) == "table", "Invalid gearshift status")
                        minAngle, maxAngle = math.min(minAngle, angle), math.max(maxAngle, angle)
                        if readStart >= deadline - 0.5 and readStart < deadline then
                            tailSamples = tailSamples + 1
                            if math.abs(angle - target) <= 1 then tailWithin = tailWithin + 1 end
                        end
                        emit(string.format("%.2f..%.2f angle=%.3f running=%s gearLeft=%s gearRight=%s",
                            readStart - started, os.clock() - started, angle, tostring(running),
                            tostring(status.leftPowered), tostring(status.rightPowered)))
                        sleep(0.05)
                    end
                end, function()
                    sleep(2)
                    stopping = true
                    requireStopped()
                end, function()
                    while true do
                        sleep(0.05)
                        if not stopping and os.clock() < deadline then
                            call(wing.gear, "setOutputs", left, right)
                            refreshes = refreshes + 1
                        end
                    end
                end)
                stopping = true
                requireStopped()
                emit(string.format("Released: range=%.3f..%.3f refreshes=%d final-half-second within1degree=%d/%d",
                    minAngle, maxAngle, refreshes, tailWithin, tailSamples))
                waitNeutral(wing, true)
                emit("Returned to neutral")
                sleep(2)
            end
        end
    end
    emit("All eight tests completed")
end)
local cleanup = {}
if touched then
    cleanup = stopAll()
    for _, wing in ipairs(wings) do
        if wing.limitTouched then
            local restored, restoreErr = pcall(function()
                waitNeutral(wing, false)
                call(wing.spring, "setLimit", wing.originalLimit)
                assert(call(wing.spring, "getLimit") == wing.originalLimit, "Restore readback mismatch")
            end)
            if not restored then cleanup[#cleanup + 1] = wing.spring .. " restore failed: " .. tostring(restoreErr) end
        end
    end
end
if not ok then pcall(emit, "Stopped: " .. tostring(err)) end
if #cleanup == 0 then
    pcall(emit, touched and "Cleanup: commands released; changed limits restored" or "No actuator changes made")
else
    for _, message in ipairs(cleanup) do print(message); pcall(emit, message) end
end
file.close()
print("Saved " .. path)
if not ok then error(err, 0) end
assert(#cleanup == 0, "Cleanup incomplete; see report")
