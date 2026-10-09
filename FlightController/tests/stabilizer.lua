local M = assert(loadfile("FlightController/stabilizer.lua"))("--module")
local base = assert(loadfile("FlightController/controller.lua"))("--module")
local function config()
    local c = assert(loadfile("FlightController/aircraft_config.lua"))()
    c.thrusterPitchTrim = 0 -- Generic mixer checks use the untrimmed baseline.
    c.thrusterPitch = nil -- Also exercise compatibility with earlier configs.
    c.burners = { leftFront = "burner_lf", leftBack = "burner_lb",
        rightFront = "burner_rf", rightBack = "burner_rb" }
    c.gyro = { name = "gyro_test", read = function(g) return g.read() end }
    return c
end
local function state() return { collective = 7, pitch = {}, roll = {} } end
local c = config()
M.validate(c)
local installed = assert(loadfile("FlightController/aircraft_config.lua"))()
M.validate(installed)
local missing = config(); missing.burners.leftFront = false
assert(not pcall(M.validate, missing))
-- Actual report: front burners are lower than rear, so pitch must be negative.
local measured = M.attitude({ getAngles = function()
    return { 4.7192933583703352e-06, 10.304694434678627 }
end }, installed)
assert(math.abs(measured.pitch + 10.304694434678627) < 1e-9)
assert(math.abs(measured.roll - 4.7192933583703352e-06) < 1e-9)
assert(installed.burners.leftFront == "hot_air_burner_5")
assert(installed.burners.leftBack == "hot_air_burner_4")
assert(installed.burners.rightFront == "hot_air_burner_3")
assert(installed.burners.rightBack == "hot_air_burner_2")
local correction = M.step(installed, state(), { forward = true }, measured, 0.1)
assert(correction.burners.leftFront > correction.burners.leftBack)
assert(correction.burners.rightFront > correction.burners.rightBack)
-- Nose-down feedback shifts thrust toward the bottom relative to trimmed level.
-- A powered trim may still leave the top stronger in the absolute command.
local trimmedLevel = M.step(installed, state(), { forward = true },
    { pitch = 0, roll = 0 }, 0.1)
assert(correction.left[1] - correction.left[4]
    > trimmedLevel.left[1] - trimmedLevel.left[4])
assert(not pcall(M.attitude, { getAngles = function() return {} end }, installed))
assert(not pcall(M.attitude, { getAngles = function() return { 0/0, 0 } end }, installed))
local duplicate = config(); duplicate.burners.leftFront = duplicate.burners.rightFront
assert(not pcall(M.validate, duplicate))
local o = M.step(c, state(), { forward = true }, { pitch = 0, roll = 0 }, 0.1)
for i = 1, 4 do assert(o.left[i] == 1 and o.right[i] == 1) end
for _, signal in pairs(o.burners) do assert(signal == 7) end
-- Nose up: less front lift, more rear lift; reduce bottom forward thrust.
o = M.step(c, state(), { forward = true }, { pitch = 20, roll = 0 }, 0.1)
assert(o.burners.leftFront < o.burners.leftBack)
assert(o.left[1] < o.left[4] and o.right[1] < o.right[4])
-- Nose down: reverse pitch corrections.
o = M.step(c, state(), { forward = true }, { pitch = -20, roll = 0 }, 0.1)
assert(o.burners.leftFront > o.burners.leftBack and o.left[1] > o.left[4])
-- Right side down: more right lift. Forward thrusters cannot independently roll.
o = M.step(c, state(), {}, { pitch = 0, roll = 20 }, 0.1)
assert(o.burners.rightFront > o.burners.leftFront)
assert(o.burners.rightBack > o.burners.leftBack)
for i = 1, 4 do assert(o.left[i] == 0 and o.right[i] == 0) end
o = M.step(c, state(), { left = true }, { pitch = 20, roll = 20 }, 0.1)
for i = 1, 4 do assert(o.left[i] == 0 and o.right[i] > 0 and o.right[i] <= 1) end
local s = state(); s.collective = 15
o = M.step(c, s, { up = true }, { pitch = -90, roll = -90 }, 0.1)
for _, v in pairs(o.burners) do assert(v >= 0 and v <= 15 and v % 1 == 0) end
assert(s.collective == 15)
s = state()
M.step(c, s, { up = true, down = true }, { pitch = 0, roll = 0 }, 0.1)
assert(s.collective == 7)
assert(not pcall(M.attitude, { read = function() return 0/0, 0 end }, c))
local a = M.attitude({ read = function() return 359, 1 end }, c)
assert(a.pitch == -1 and a.roll == 1)
-- Derivative feedback damps movement even while crossing the level target.
s = state()
M.step(c, s, {}, { pitch = -5, roll = 0 }, 0.1)
o = M.step(c, s, {}, { pitch = 0, roll = 0 }, 0.1)
assert(o.pitch < 0)

-- Regression: slow samples must use measured time, not a 0.25 s cap.
local timingConfig = config()
timingConfig.pitch = { kp = 0, kd = 0.1 }
timingConfig.derivativeFilterSeconds = 0
local slowState = state()
M.step(timingConfig, slowState, {}, { pitch = 0, roll = 0 }, 0.1)
local slowOutput = M.step(timingConfig, slowState, { up = true },
    { pitch = 2.6, roll = 0 }, 1.3)
assert(math.abs(slowState.pitch.rate - 2) < 1e-9)
assert(math.abs(slowOutput.pitch + 0.2) < 1e-9)
assert(math.abs(slowState.collective - 9.6) < 1e-9)

local function scenario(live, fault, supplied, period)
    period = period or 0.1
    local tick, writes, frames, stops, observed = 0, {}, {}, {}, 0
    local batches = {}
    local p = {
        getMethods = function()
            return { "setThrottle", "setEnabled", "setSignal", "getSignal" }
        end,
        wrap = function()
            return { read = function()
                if fault == "gyro" and tick == 3 then error("gyro disconnected") end
                return 20, 10
            end }
        end,
    }
    p.call = function(name, method, value)
        if method == "getSignal" then return 7 end
        if method == "getAnalogInput" then
            return (tick == 1 or tick == 3) and name == "redstone_relay_2" and value == "top" and 15 or 0
        end
        writes[#writes + 1] = { name, method, value }
        if fault == "actuator" and tick == 3 and name == "thruster_4" then error("disconnected") end
        if method == "setEnabled" and value == false then stops[name] = true end
    end
    local ok, err, failures = M.run(p, base, supplied or config(), {
        now = function() return tick * period end,
        startTimer = function() return 1 end,
        pullEvent = function()
            tick = tick + 1
            if tick == 4 then return "terminate" end
            return "timer", 1
        end,
        quitKey = 99,
        batch = function(jobs)
            batches[#jobs] = true
            for _, job in ipairs(jobs) do job() end
        end,
        observe = function(_, _, running, ready, input, attitude, collective, output, time, dt)
            observed = observed + 1
            assert(math.abs(dt - period) < 1e-8)
            assert(time == tick * period)
            assert(running == live and attitude.pitch == 20 and collective == 7)
            if ready then assert(output and output.burners.leftFront) end
            if tick == 3 then assert(input.forward) end
        end,
        render = function(_, ready, _, _, output)
            frames[#frames + 1] = { ready = ready, output = output }
        end,
    }, live)
    if ok then
        assert(observed == 3)
        assert(batches[5] and batches[2]) -- relay inputs and gyro/input sampling
        if live then assert(batches[12]) end -- all independent actuator writes
    end
    return ok, err, failures, writes, frames, stops
end
local ok, _, _, writes, frames = scenario(false)
assert(ok and #writes == 0 and not frames[1].ready and frames[2].ready)
assert(frames[3].output.left[1] < frames[3].output.left[4])
ok, _, _, writes = scenario(true, nil, missing)
assert(not ok and #writes == 0)
local stops
ok, _, _, writes, frames, stops = scenario(true)
assert(ok)
for i = 0, 7 do assert(stops["thruster_" .. i]) end
local seen = {}
for _, write in ipairs(writes) do
    if write[2] == "setSignal" then seen[write[1]] = true end
end
for _, name in pairs(c.burners) do assert(seen[name]) end
ok, _, _, _, _, stops = scenario(true, "gyro")
assert(not ok)
for i = 0, 7 do assert(stops["thruster_" .. i]) end
local failures
ok, _, failures, _, _, stops = scenario(true, "actuator")
assert(not ok and #failures == 2)
for i = 0, 7 do if i ~= 4 then assert(stops["thruster_" .. i]) end end
ok = scenario(false, nil, nil, 1.3)
assert(ok)
-- Only the current and numbered flight recorder files are eligible for cleanup.
local deleted = {}
M.clearRecordings({
    list = function(path)
        assert(path == "/")
        return { "flight-leveling.jsonl", "flight-leveling-2.jsonl", "flight-leveling-3.jsonl",
            "flight-leveling.lua", "flight-leveling-backup.jsonl", "unrelated.jsonl",
            "aircraft_config.lua", "flight-api.txt" }
    end,
    isDir = function(path) return path == "/flight-leveling-3.jsonl" end,
    delete = function(path) deleted[#deleted + 1] = path end,
})
assert(#deleted == 2 and deleted[1] == "/flight-leveling.jsonl"
    and deleted[2] == "/flight-leveling-2.jsonl")
assert(M.recording.maxBytes == 900 * 1024)
-- Logging is bounded even on unlimited disks, and reserves update space.
assert(M.recordingRoom(0, 100, "unlimited"))
assert(M.recordingRoom(M.recording.maxBytes - 100, 100, 1000000))
assert(not M.recordingRoom(M.recording.maxBytes - 99, 100, "unlimited"))
assert(not M.recordingRoom(0, 100, M.recording.reserveBytes))
assert(not M.recordingRoom(0, 0, 0))
local header = M.recordingHeader(installed, base)
assert(header.schema == 3 and header.thrusters[1] == "thruster_0")
assert(header.burners[1].name == "hot_air_burner_5")
local original = { time = 1.23456789, attitude = { pitch = 2, roll = 3 },
    live = true, ready = false, burners = {
    leftFront = { name = "burner", status = { value = {
        signal = 3, gasOutput = 100, powered = false, className = "redundant",
        position = { x = 1.23456789, y = 90, z = 10, subLevelId = "redundant" },
    } } },
}, thrusters = { thruster_0 = { value = { throttle = 0.5, realThrust = 42,
    fuel = 100, enabled = true, active = false, fuelType = "redundant" } },
    thruster_1 = { error = "disconnected" } } }
local compact = M.compactSample(original, header)
assert(compact.time == 1.2346 and compact.state[2] == false)
assert(compact.burners[1][1] == 3 and compact.burners[1][3] == 1.2346)
assert(compact.thrusters[1][2] == 42 and compact.thrusters[1][5] == false)
assert(compact.thrusters[2].error == "disconnected")
assert(original.burners.leftFront.status.value.className == "redundant")
local function noRepeatedNames(value)
    if type(value) ~= "table" then return end
    for k, v in pairs(value) do
        assert(not (type(k) == "string" and k:find("thruster_", 1, true)))
        assert(not (type(v) == "string" and v:find("hot_air_burner_", 1, true)))
        noRepeatedNames(v)
    end
end
noRepeatedNames(compact)
local room, reason = M.recordingRoom(0, 100, 50)
assert(not room and reason:find("50 bytes free", 1, true))
local disk = M.diskUsage({
    getDrive = function(path) return path == "/rom" and "rom" or "hdd" end,
    list = function(path)
        if path == "/" then return { "small.lua", "folder", "rom" } end
        assert(path == "/folder"); return { "large.lua" }
    end,
    combine = function(a, b) return a == "/" and (a .. b) or (a .. "/" .. b) end,
    isDir = function(path) return path == "/folder" end,
    getSize = function(path) return path == "/small.lua" and 10 or 1000 end,
    getFreeSpace = function() return 50 end,
    getCapacity = function() return 1060 end,
})
assert(disk.free == 50 and #disk.files == 2)
assert(disk.files[1].path == "/folder/large.lua")
-- Replay the recorded zero-collective failure: attitude must not relight burners.
local offState = state(); offState.collective = 0
local off = M.step(c, offState, {}, { pitch = 80, roll = 15 }, 0.1)
for _, value in pairs(off.burners) do assert(value == 0) end
local resume = M.step(c, offState, { up = true }, { pitch = 80, roll = 15 }, 0.1)
assert(offState.collective > 0 and resume.burners.leftBack > 0)
offState.collective = 0.1
local lower = M.step(c, offState, { down = true }, { pitch = -40, roll = -50 }, 0.1)
for _, value in pairs(lower.burners) do assert(value == 0) end
-- Growing oscillation trace: pitch is positive but rapidly approaching level.
-- Braking should command nose-up torque before the aircraft crosses level.
local braking = state()
braking.pitch = { previous = 6.7, rate = -5 }
local brake = M.step(installed, braking, {}, { pitch = 6.2, roll = 0 }, 0.1)
assert(brake.pitch > 0 and brake.burners.leftFront > brake.burners.leftBack)
local oldGains = config(); oldGains.pitch.kd = 0.015
local oldState = state(); oldState.pitch = { previous = 6.7, rate = -5 }
assert(M.step(oldGains, oldState, {}, { pitch = 6.2, roll = 0 }, 0.1).pitch < 0)
-- At full collective, a five-degree tilt still receives a differential correction.
local full = state(); full.collective = 15
local fullOutput = M.step(installed, full, {}, { pitch = -5, roll = 0 }, 0.1)
assert(fullOutput.burners.leftFront == 15 and fullOutput.burners.leftBack == 14)
local levelFull = state(); levelFull.collective = 15
for _, value in pairs(M.step(installed, levelFull, {}, { pitch = 0, roll = 0 }, 0.1).burners) do
    assert(value == 15)
end
-- Near-zero residual must not sustain corrections after the pilot releases down.
local tiny = state(); tiny.collective = 1e-12
for _, value in pairs(M.step(installed, tiny, {}, { pitch = 70, roll = -40 }, 0.1).burners) do
    assert(value == 0)
end
assert(tiny.collective == 0)
assert(M.recordingHeader(installed, base).controllerVersion == "0.2.2")
-- Powered trim acts at level, leaves burners unchanged, and never starts an off bank.
local trimmed = config(); trimmed.thrusterPitchTrim = -0.15
local level = { pitch = 0, roll = 0 }
local trimmedForward = M.step(trimmed, state(), { forward = true }, level, 0.1)
assert(math.abs(trimmedForward.left[1] - 0.85) < 1e-9)
assert(math.abs(trimmedForward.left[2] - 0.95) < 1e-9)
assert(trimmedForward.left[3] == 1 and trimmedForward.left[4] == 1)
local untrimmedForward = M.step(c, state(), { forward = true }, level, 0.1)
for role, signal in pairs(untrimmedForward.burners) do
    assert(trimmedForward.burners[role] == signal)
end
local trimmedOff = M.step(trimmed, state(), {}, level, 0.1)
local trimmedTurn = M.step(trimmed, state(), { right = true }, level, 0.1)
for i = 1, 4 do
    assert(trimmedOff.left[i] == 0 and trimmedOff.right[i] == 0)
    assert(trimmedTurn.right[i] == 0 and trimmedTurn.left[i] == trimmedForward.left[i])
end
trimmed.thrusterPitchTrim = nil
local legacy = M.step(trimmed, state(), { forward = true }, level, 0.1)
for i = 1, 4 do assert(legacy.left[i] == 1 and legacy.right[i] == 1) end
trimmed.thrusterPitchTrim = 2
assert(not pcall(M.validate, trimmed))
assert(M.recordingHeader(installed, base).tuning.thrusterPitchTrim == -0.30)
-- Independent thrust gains must strengthen correction without affecting burners/rates.
local separate = config(); separate.thrusterPitch = { kp = 0.075, kd = 0.15 }
local oldState, newState = state(), state()
M.step(c, oldState, {}, { pitch = 5.9, roll = 0 }, 0.1)
M.step(separate, newState, {}, { pitch = 5.9, roll = 0 }, 0.1)
local oldOutput = M.step(c, oldState, { forward = true }, { pitch = 6, roll = 0 }, 0.1)
local newOutput = M.step(separate, newState, { forward = true }, { pitch = 6, roll = 0 }, 0.1)
assert(newOutput.left[1] < oldOutput.left[1])
assert(newOutput.right[1] < oldOutput.right[1])
assert(newOutput.rates.pitch == oldOutput.rates.pitch)
for role, signal in pairs(oldOutput.burners) do assert(newOutput.burners[role] == signal) end
for _, input in ipairs({ {}, { left = true }, { right = true }, { forward = true } }) do
    for _, angle in ipairs({ -180, -6, 0, 6, 180 }) do
        local out = M.step(separate, state(), input, { pitch = angle, roll = 0 }, 0.1)
        for i = 1, 4 do
            assert(out.left[i] >= 0 and out.left[i] <= 1)
            assert(out.right[i] >= 0 and out.right[i] <= 1)
            if input.left or not (input.forward or input.right) then assert(out.left[i] == 0) end
            if input.right or not (input.forward or input.left) then assert(out.right[i] == 0) end
        end
    end
end
separate.thrusterPitch.kp = -1
assert(not pcall(M.validate, separate))
assert(M.recordingHeader(installed, base).tuning.thrusterPitch.kp == 0.075)
print("Stabilizer tests passed")
