-- Cooperative scheduler and fake actuators exercise in-place target updates.
local function run(mode)
    local oldClock, oldPrint = os.clock, print
    local clock, scheduling, stage, closed, limitUpdatesWhileHeld = 0, false, 0, false, 0
    local limits = { torsion_spring_0 = 40, torsion_spring_1 = 40 }
    local commands = { directional_gearshift_2 = 0, directional_gearshift_3 = 0 }
    local movingUntil = { torsion_spring_0 = 0, torsion_spring_1 = 0 }
    local gearFor = { torsion_spring_0 = "directional_gearshift_2", torsion_spring_1 = "directional_gearshift_3" }
    local springFor = { directional_gearshift_2 = "torsion_spring_0", directional_gearshift_3 = "torsion_spring_1" }
    local lines, writes, failed = {}, {}, false
    os.clock = function() return clock end
    _G.print = function() end
    _G.sleep = function(seconds)
        if scheduling then return coroutine.yield(seconds) end
        clock = clock + seconds
    end
    _G.fs = { exists = function() return false end, open = function()
        return { writeLine = function(line)
            lines[#lines + 1] = line
            stage = tonumber(line:match("^STAGE (%d+)")) or stage
        end, flush = function() end, close = function() closed = true end }
    end }
    _G.peripheral = { call = function(name, method, a, b)
        if method == "getPressedKeyCodes" then return mode == "shift" and stage >= 2 and {340} or {} end
        if method == "getThrottle" then return mode == "powered" and 1 or 0 end
        if method == "isActive" then return false end
        if method == "isLeftPowered" then return commands[name] < 0 end
        if method == "isRightPowered" then return commands[name] > 0 end
        if method == "getStatus" then return { leftPowered = commands[name] < 0, rightPowered = commands[name] > 0 } end
        if method == "isRunning" then return clock < movingUntil[name] end
        if method == "getLimit" then return limits[name] end
        if method == "getAngle" then
            if scheduling and mode == "sensor_failure" and stage >= 2 then error("sensor lost") end
            return commands[gearFor[name]] * limits[name]
        end
        writes[#writes + 1] = { name, method, a, b }
        if method == "setLimit" then
            assert(a >= 1 and a <= 40)
            assert(clock >= movingUntil[name], "Attempted update while moving")
            if mode == "rejected_limit" and a ~= 40 then return end
            if commands[gearFor[name]] ~= 0 and limits[name] ~= a then limitUpdatesWhileHeld = limitUpdatesWhileHeld + 1 end
            if limits[name] ~= a then movingUntil[name] = clock + 0.15 end
            limits[name] = a
        elseif method == "setOutputs" then
            assert(springFor[name], "Unexpected actuator")
            local command = a and -1 or b and 1 or 0
            if (mode == "normal" or mode == "normal_latency") and scheduling and stage >= 2 and stage <= 10 then
                assert(command ~= 0, "Unnecessary neutral command between nonzero targets")
            end
            if commands[name] ~= command then movingUntil[springFor[name]] = clock + 0.15 end
            commands[name] = command
            if mode == "setter_failure" and command ~= 0 and not failed then
                failed = true; error("failed setter after side effect")
            end
        else error("Unexpected method " .. method) end
        if mode == "normal_latency" and scheduling and method == "setOutputs" then
            coroutine.yield(0.05) -- Simulate a setter yielding for one server tick.
        end
    end }
    _G.parallel = { waitForAny = function(...)
        local tasks = {}
        for _, fn in ipairs({...}) do tasks[#tasks + 1] = { co = coroutine.create(fn), at = clock } end
        scheduling = true
        for _ = 1, 30000 do
            local chosen = tasks[1]
            for _, task in ipairs(tasks) do if task.at < chosen.at then chosen = task end end
            clock = math.max(clock, chosen.at)
            local ok, value = coroutine.resume(chosen.co)
            if not ok then scheduling = false; error(value, 0) end
            if coroutine.status(chosen.co) == "dead" then scheduling = false; return end
            chosen.at = clock + value
        end
        scheduling = false
        error("Scheduler iteration limit")
    end }
    local ok = pcall(assert(loadfile("FighterJet/test_wing_mix.lua")), "0")
    os.clock, print = oldClock, oldPrint
    if mode == "powered" then assert(not ok and #writes == 0); return end
    assert(closed)
    assert(commands.directional_gearshift_2 == 0 and commands.directional_gearshift_3 == 0)
    assert(limits.torsion_spring_0 == 40 and limits.torsion_spring_1 == 40)
    if mode == "normal" or mode == "normal_latency" then
        assert(ok, table.concat(lines, "\n"))
        assert(stage == 11 and limitUpdatesWhileHeld >= 8)
        if mode == "normal_latency" then
            local count = 0
            for _, line in ipairs(lines) do
                local right, left = line:match("Refresh counts right=(%d+) left=(%d+)")
                if right then
                    assert(tonumber(right) >= 65 and tonumber(left) >= 65,
                        "Added an unnecessary sleep after a tick-long peripheral call")
                    count = count + 1
                end
            end
            assert(count == 11)
        end
        assert(table.concat(lines, "\n"):find("All eleven stages completed", 1, true))
    else assert(not ok, "Expected failure in " .. mode) end
end
for _, mode in ipairs({ "normal", "normal_latency", "powered", "shift", "sensor_failure", "setter_failure", "rejected_limit" }) do run(mode) end
print("Mixed wing target checks passed")
