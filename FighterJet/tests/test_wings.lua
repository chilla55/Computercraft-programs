-- Host Lua tests: mock all CraftOS I/O; no real peripherals are used.
local savedPrint = print
local function run(mode, refresh)
    local clock, keyReads, writes, files = 0, 0, {}, {}
    local active = {}
    local failed = false
    local sampling = false
    local oldClock = os.clock
    os.clock = function() return clock end
    _G.print = function() end
    _G.sleep = function(seconds)
        if sampling then return coroutine.yield() end
        clock = clock + seconds
    end
    _G.textutils = { serialize = function(value)
        if type(value) ~= "table" then return tostring(value) end
        local out = {}
        for i, v in ipairs(value) do out[i] = tostring(v) end
        return "{" .. table.concat(out, ",") .. "}"
    end }
    local closed = false
    _G.fs = { exists = function() return false end, open = function()
        return { writeLine = function(line) files[#files + 1] = line end,
            flush = function() end, close = function() closed = true end }
    end }
    _G.peripheral = { isPresent = function() return true end, call = function(name, method, a, b)
        if method == "getThrottle" then return mode == "powered" and 1 or 0 end
        if method == "isActive" or method == "isLeftPowered" or method == "isRightPowered" then return false end
        if method == "getLimit" then return 40 end
        if method == "getPressedKeyCodes" then
            keyReads = keyReads + 1
            if sampling and mode == "shift" then return {340} end
            return keyReads % 4 == 0 and {32} or {}
        end
        if method == "getStatus" then
            return { leftPowered = (active[name] or 0) > 0,
                rightPowered = (active[name] or 0) < 0 }
        end
        if method == "isRunning" then
            local gear = name == "torsion_spring_0" and "directional_gearshift_2" or "directional_gearshift_3"
            return (active[gear] or 0) ~= 0
        end
        if method == "getAngle" then
            if sampling and mode == "sensor_failure" then error("sensor disconnected") end
            local gear = name == "torsion_spring_0" and "directional_gearshift_2" or "directional_gearshift_3"
            return active[gear] or 0
        end
        assert(method == "setOutputs", "Unexpected device write/read: " .. method)
        assert(name:match("^directional_gearshift_"), "Wrong actuator")
        writes[#writes + 1] = {name, a, b}
        active[name] = a and 4 or b and -4 or 0
        if ((mode == "setter_failure") or (mode == "refresh_failure" and #writes == 2))
            and (a or b) and not failed then
            failed = true
            error("injected setter failure")
        end
    end }
    _G.parallel = { waitForAny = function(reader, watchdog, renew)
        local co = coroutine.create(reader)
        sampling = true
        local ok, err = coroutine.resume(co)
        sampling = false
        assert(ok, err)
        local writer = coroutine.create(renew)
        sampling = true
        local first, firstErr = coroutine.resume(writer) -- wait before renewal
        local second, secondErr = coroutine.resume(writer) -- one renewal
        sampling = false
        assert(first, firstErr); assert(second, secondErr)
        watchdog()
        local count = #writes
        sampling = true
        local late, lateErr = coroutine.resume(writer)
        sampling = false
        assert(late, lateErr)
        assert(#writes == count, "Renewal wrote after cutoff")
    end }
    local ok = pcall(assert(loadfile("FighterJet/test_wings.lua")), "0.6", refresh and "refresh" or nil)
    os.clock = oldClock
    _G.print = savedPrint
    if mode == "powered" then
        assert(not ok and #writes == 0)
        return
    end
    assert(closed and #writes >= 2)
    for _, gear in ipairs({ "directional_gearshift_2", "directional_gearshift_3" }) do
        assert(active[gear] == 0, "Gearshift not released after " .. mode)
    end
    if mode == "normal" then
        assert(ok)
        local pulses = {}
        for _, write in ipairs(writes) do
            if write[2] or write[3] then pulses[#pulses + 1] = write end
        end
        assert(#pulses == (refresh and 8 or 4))
        for i, write in ipairs(pulses) do
            local phase = refresh and math.ceil(i / 2) or i
            assert(write[1] == (phase <= 2 and "directional_gearshift_2" or "directional_gearshift_3"))
            assert(write[2] == (phase % 2 == 1) and write[3] == (phase % 2 == 0))
        end
        assert(table.concat(files, "\n"):find("All four tests completed", 1, true))
    else
        assert(not ok, "Expected abort/failure in " .. mode)
    end
end
for _, mode in ipairs({ "normal", "powered", "sensor_failure", "setter_failure", "shift" }) do run(mode) end
run("normal", true)
run("sensor_failure", true)
run("shift", true)
run("refresh_failure", true)
print("Wing test checks passed")
