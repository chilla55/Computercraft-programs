-- Automated ground test: changing both surface targets without forced centering.
-- Starts after a delay. Left Shift or Ctrl+T aborts; no thruster writes.
local args = { ... }
assert(#args <= 1, "Usage: test_wing_mix [start-delay-seconds]")
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
local path, index = "fighter-wing-mix.txt", 0
while fs.exists(path) do
    index = index + 1
    path = "fighter-wing-mix-" .. index .. ".txt"
end
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local started, touched = os.clock(), false
local function emit(line) file.writeLine(line); file.flush() end
-- Positive surface demand means trailing edge UP. This is a mechanical mixer,
-- not yet a verified aerodynamic pitch/roll sign convention.
local stages = {
    { common = 5, differential = 0 }, { common = 10, differential = 0 },
    { common = 5, differential = 0 }, { common = 5, differential = 3 },
    { common = 5, differential = -3 }, { common = 0, differential = 5 },
    { common = 0, differential = -5 }, { common = -5, differential = 0 },
    { common = -10, differential = 0 }, { common = -5, differential = 0 },
    { common = 0, differential = 0 },
}
for _, wing in ipairs(wings) do
    wing.command, wing.requested, wing.appliedLimit = 0, 0, wing.originalLimit
end
local ok, err = pcall(function()
    emit("Automated wing mixing test v2: four seconds per stage, max 10 degrees")
    emit("Positive surface demand = trailing edge UP; raw angles use spring signs.")
    emit("Limits updated only when static; refresh continues during updates.")
    emit("Refresh cycle aims for 0.05 seconds INCLUDING peripheral call time.")
    for _, wing in ipairs(wings) do
        emit(wing.side .. " " .. wing.spring .. " originalLimit=" .. wing.originalLimit)
    end
    print("Automated mixed-wing test starts in " .. delay .. " seconds.")
    print("Watch from the typewriter. Left Shift aborts. Keep thrusters off.")
    local readyAt = os.clock() + delay
    while os.clock() < readyAt do checkAbort(); sleep(0.1) end
    thrustersOff()
    touched = true
    requireStopped()
    for _, wing in ipairs(wings) do waitNeutral(wing, true) end
    local stopping = false
    local function refresh(wing)
        while true do
            local cycleStarted = os.clock()
            if not stopping then
                local command = wing.command
                call(wing.gear, "setOutputs", command < 0, command > 0)
                wing.refreshes = (wing.refreshes or 0) + 1
            end
            -- A main-thread peripheral call may already consume a game tick.
            -- Do not add another full tick; still yield when a call is immediate.
            local remaining = 0.05 - (os.clock() - cycleStarted)
            if remaining > 0.001 then sleep(remaining) end
        end
    end
    parallel.waitForAny(function()
        for number, stage in ipairs(stages) do
            checkAbort()
            thrustersOff()
            -- Publish the two new targets together; do not center between stages.
            wings[1].requested = (stage.common - stage.differential) * wings[1].upSign
            wings[2].requested = (stage.common + stage.differential) * wings[2].upSign
            emit(string.format("STAGE %d common=%d differential=%d rawTargets(right,left)=%d,%d",
                number, stage.common, stage.differential, wings[1].requested, wings[2].requested))
            print("Stage " .. number .. "/" .. #stages)
            local refreshBefore = { wings[1].refreshes or 0, wings[2].refreshes or 0 }
            local stageStarted = os.clock()
            local deadline, settled = stageStarted + 4, 0
            repeat
                checkAbort()
                local readStart, allReached = os.clock(), true
                local fields = {}
                for _, wing in ipairs(wings) do
                    local angle = call(wing.spring, "getAngle")
                    assert(finite(angle), "Invalid angle")
                    assert(math.abs(angle) <= 20, "Unexpected angle over 20 degrees")
                    local running = call(wing.spring, "isRunning")
                    local limit = call(wing.spring, "getLimit")
                    local status = call(wing.gear, "getStatus")
                    assert(type(status) == "table", "Invalid gearshift status")
                    if math.abs(angle - wing.requested) > 1 or running
                        or wing.command ~= wing.requested then allReached = false end
                    fields[#fields + 1] = string.format("%s angle=%.3f limit=%s running=%s gear=%s,%s",
                        wing.side, angle, tostring(limit), tostring(running),
                        tostring(status.leftPowered), tostring(status.rightPowered))
                end
                settled = allReached and settled + 1 or 0
                emit(string.format("%.2f..%.2f %s", readStart - started, os.clock() - started,
                    table.concat(fields, " | ")))
                sleep(0.1)
            until os.clock() >= deadline
            assert(settled >= 3, "Targets did not settle for the final three samples at stage " .. number)
            emit("Stage settled for final " .. settled .. " consecutive samples")
            emit(string.format("Refresh counts right=%d left=%d over %.2f seconds",
                (wings[1].refreshes or 0) - refreshBefore[1],
                (wings[2].refreshes or 0) - refreshBefore[2], os.clock() - stageStarted))
        end
        stopping = true
        requireStopped()
        emit("All eleven stages completed")
    end, function() refresh(wings[1]) end, function() refresh(wings[2]) end, function()
        while true do
            for _, wing in ipairs(wings) do
                local target = wing.requested
                if target == 0 then
                    wing.command = 0
                elseif wing.command ~= target then
                    local magnitude = math.abs(target)
                    if magnitude == wing.appliedLimit then
                        wing.command = target
                    elseif not call(wing.spring, "isRunning") then
                        -- Keep refreshing the previous command throughout this read/write.
                        wing.limitTouched = true
                        call(wing.spring, "setLimit", magnitude)
                        local applied = call(wing.spring, "getLimit")
                        if applied == magnitude then
                            wing.appliedLimit = applied
                            wing.command = target
                        end
                        -- If movement raced the write, retry while retaining the latest target.
                    end
                end
            end
            sleep(0.05)
        end
    end)
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
