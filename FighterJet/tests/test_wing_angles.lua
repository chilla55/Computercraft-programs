-- Mocked ground-test regression checks; no Minecraft connection.
local function run(mode)
    local savedPrint, savedClock = print, os.clock
    local clock, writes, lines, closed = 0, {}, {}, false
    local active = { directional_gearshift_2 = 0, directional_gearshift_3 = 0 }
    local limits = { torsion_spring_0 = 40, torsion_spring_1 = 40 }
    local gears = { torsion_spring_0 = "directional_gearshift_2", torsion_spring_1 = "directional_gearshift_3" }
    local sampling, injected, sets = false, false, 0
    os.clock = function() return clock end
    _G.print = function() end
    _G.sleep = function(seconds)
        if sampling then coroutine.yield() else clock = clock + seconds end
    end
    _G.fs = { exists = function() return false end, open = function()
        return { writeLine = function(line) lines[#lines + 1] = line end,
            flush = function() end, close = function() closed = true end }
    end }
    _G.peripheral = { call = function(name, method, a, b)
        if method == "getPressedKeyCodes" then
            return (mode == "shift" and sampling) and {340} or {}
        end
        if method == "getThrottle" then return mode == "powered" and 1 or 0 end
        if method == "isActive" then return false end
        if method == "isLeftPowered" then return (active[name] or 0) < 0 end
        if method == "isRightPowered" then return (active[name] or 0) > 0 end
        if method == "isRunning" then return false end
        if method == "getLimit" then return limits[name] end
        if method == "getAngle" then
            if mode == "sensor_failure" and sampling then error("sensor lost") end
            if mode == "excess_angle" and sampling then return 25 end
            if mode == "no_return" and sets > 0 and (active[gears[name]] or 0) == 0 then return 5 end
            return (active[gears[name]] or 0) * limits[name]
        end
        if method == "getStatus" then
            return { leftPowered = active[name] < 0, rightPowered = active[name] > 0 }
        end
        writes[#writes + 1] = { name, method, a, b }
        if method == "setLimit" then
            assert(gears[name], "Unexpected spring")
            assert(a == 5 or a == 10 or a == 40, "Unplanned limit")
            assert(active[gears[name]] == 0, "Changed limit while gear active")
            if mode == "rejected_limit" and a ~= 40 then return end
            limits[name] = a
        elseif method == "setOutputs" then
            assert(active[name] ~= nil, "Unexpected actuator write")
            active[name] = a and -1 or b and 1 or 0
            if a or b then sets = sets + 1 end
            if mode == "setter_failure" and (a or b) and not injected then
                injected = true; error("setter failed after applying")
            end
        else error("Unexpected device write: " .. method) end
    end }
    _G.parallel = { waitForAny = function(reader, watchdog, writer)
        local r, w = coroutine.create(reader), coroutine.create(writer)
        local function step(co)
            sampling = true
            local ok, err = coroutine.resume(co)
            sampling = false
            assert(ok, err)
        end
        step(w)
        for _ = 1, 4 do step(r); step(w); clock = clock + 0.5 end
        watchdog()
        local count = #writes
        step(w)
        assert(#writes == count, "Command renewal continued after cutoff")
    end }
    local ok = pcall(assert(loadfile("FighterJet/test_wing_angles.lua")), "0")
    _G.print, os.clock = savedPrint, savedClock
    if mode == "powered" then assert(not ok and #writes == 0); return end
    assert(closed)
    assert(active.directional_gearshift_2 == 0 and active.directional_gearshift_3 == 0)
    if mode == "no_return" then
        assert(not ok and table.concat(lines, "\n"):find("restore failed", 1, true))
    else assert(limits.torsion_spring_0 == 40 and limits.torsion_spring_1 == 40) end
    if mode == "normal" then
        assert(ok)
        local phases = {}
        for _, line in ipairs(lines) do
            if line:match("^TEST ") then phases[#phases + 1] = line end
        end
        assert(#phases == 8)
        local expected = { -5, -10, 5, 10, 5, 10, -5, -10 }
        for i, line in ipairs(phases) do
            assert(tonumber(line:match("target=(-?%d+)")) == expected[i])
        end
        assert(table.concat(lines, "\n"):find("All eight tests completed", 1, true))
    else assert(not ok, "Expected failure: " .. mode) end
end
for _, mode in ipairs({ "normal", "powered", "shift", "sensor_failure", "setter_failure",
    "rejected_limit", "excess_angle", "no_return" }) do run(mode) end
print("Automated wing-angle checks passed")
