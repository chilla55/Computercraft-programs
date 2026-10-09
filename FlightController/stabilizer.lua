-- Four-burner attitude controller. Requires aircraft_config.lua and controller.lua.
local M = { version = "0.2.2" }
local roles = { "leftFront", "leftBack", "rightFront", "rightBack" }
local pitchSign = { leftFront = 1, rightFront = 1, leftBack = -1, rightBack = -1 }
local rollSign = { leftFront = 1, leftBack = 1, rightFront = -1, rightBack = -1 }
local heightWeights = { 1, 1/3, -1/3, -1 } -- bottom to top, pitch-up authority
local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function wrap(v) return (v + 180) % 360 - 180 end
local function bounded(v, lo, hi, label)
    assert(finite(v) and v >= lo and v <= hi, "Invalid " .. label)
end
function M.validate(c)
    assert(type(c) == "table" and type(c.burners) == "table", "Missing aircraft config")
    local used = {}
    for _, role in ipairs(roles) do
        local name = c.burners[role]
        assert(type(name) == "string" and name ~= "", "Configure burners." .. role)
        assert(not used[name], "Burner assigned twice: " .. name)
        used[name] = true
        bounded(c.burnerTrim[role], -15, 15, "burnerTrim." .. role)
    end
    assert(type(c.gyro) == "table" and type(c.gyro.name) == "string"
        and c.gyro.name ~= "", "Configure gyro.name")
    assert(type(c.gyro.read) == "function", "Configure gyro.read using the real gyro API")
    bounded(c.interval, 0.05, 1, "interval")
    bounded(c.burnerStepsPerSecond, 0, 15, "burnerStepsPerSecond")
    bounded(c.derivativeFilterSeconds, 0, 10, "derivativeFilterSeconds")
    bounded(c.burnerPitchAuthority, 0, 15, "burnerPitchAuthority")
    bounded(c.burnerRollAuthority, 0, 15, "burnerRollAuthority")
    bounded(c.thrusterPitchAuthority, 0, 1, "thrusterPitchAuthority")
    bounded(c.thrusterPitchTrim or 0, -1, 1, "thrusterPitchTrim")
    if c.thrusterPitch ~= nil then
        assert(type(c.thrusterPitch) == "table", "Invalid thrusterPitch gains")
        bounded(c.thrusterPitch.kp, 0, 10, "thrusterPitch.kp")
        bounded(c.thrusterPitch.kd, 0, 10, "thrusterPitch.kd")
    end
    for _, axis in ipairs({ "pitch", "roll" }) do
        bounded(c[axis].kp, 0, 10, axis .. ".kp")
        bounded(c[axis].kd, 0, 10, axis .. ".kd")
    end
end
function M.attitude(device, c)
    local pitch, roll = c.gyro.read(device)
    assert(finite(pitch) and finite(roll), "Gyro must return finite pitch and roll degrees")
    return { pitch = wrap(pitch), roll = wrap(roll) }
end
local function axis(angle, state, dt, gains, filter)
    local rate = state.previous and wrap(angle - state.previous) / dt or 0
    state.rate = (state.rate or 0) + dt / (filter + dt) * (rate - (state.rate or 0))
    state.previous = angle
    return clamp(-gains.kp * angle - gains.kd * state.rate, -1, 1)
end
function M.step(c, state, input, attitude, dt)
    assert(finite(dt) and dt > 0, "Invalid control timestep")
    assert(finite(attitude.pitch) and finite(attitude.roll), "Invalid attitude")
    local pitch = axis(attitude.pitch, state.pitch, dt, c.pitch, c.derivativeFilterSeconds)
    local roll = axis(attitude.roll, state.roll, dt, c.roll, c.derivativeFilterSeconds)
    local vertical = (input.up and 1 or 0) - (input.down and 1 or 0)
    state.collective = clamp(state.collective + vertical * c.burnerStepsPerSecond * dt, 0, 15)
    -- Repeated 0.2-step subtraction may otherwise leave an invisible positive residue.
    if state.collective < 1e-6 then state.collective = 0 end
    local output = { burners = {}, left = {}, right = {}, pitch = pitch, roll = roll,
        rates = { pitch = state.pitch.rate, roll = state.roll.rate } }
    local signals, maximum = {}, -math.huge
    for _, role in ipairs(roles) do
        local signal = state.collective + c.burnerTrim[role] +
            pitch * c.burnerPitchAuthority * pitchSign[role] +
            roll * c.burnerRollAuthority * rollSign[role]
        signals[role] = signal
        maximum = math.max(maximum, signal)
    end
    -- Shift all commands down together when the upper limit is reached. This
    -- preserves differential lift instead of flattening both sides to 15.
    local shift = math.max(0, maximum - 15)
    for _, role in ipairs(roles) do
        output.burners[role] = state.collective == 0 and 0
            or math.floor(clamp(signals[role] - shift, 0, 15) + 0.5)
    end
    local left, right = input.forward and 1 or 0, input.forward and 1 or 0
    if input.left ~= input.right then
        if input.left then left, right = 0, 1 else left, right = 1, 0 end
    end
    -- Share the measured, filtered rate without updating its state a second time.
    local thrustGains = c.thrusterPitch or c.pitch
    local thrustPitch = clamp(-thrustGains.kp * attitude.pitch
        - thrustGains.kd * state.pitch.rate, -1, 1)
    -- Keep the pilot's off banks off. Reduce selected thrusters to create pitch torque.
    for i, weight in ipairs(heightWeights) do
        local correction = clamp(thrustPitch * c.thrusterPitchAuthority
            + (c.thrusterPitchTrim or 0), -1, 1) * weight
        output.left[i] = clamp(left + correction, 0, left)
        output.right[i] = clamp(right + correction, 0, right)
    end
    return output
end

function M.run(p, base, c, services, live)
    local touched = false
    local function batch(jobs)
        if services.batch then return services.batch(jobs) end
        for _, job in ipairs(jobs) do job() end
    end
    local ok, err = pcall(function()
        M.validate(c)
        local function requires(name, methods)
            local found = {}
            for _, method in ipairs(p.getMethods(name) or {}) do found[method] = true end
            for _, method in ipairs(methods) do
                assert(found[method], name .. ": missing " .. method)
            end
        end
        for _, bank in ipairs({ base.left, base.right }) do
            for _, name in ipairs(bank) do requires(name, { "setThrottle", "setEnabled" }) end
        end
        local collective = 0
        for _, role in ipairs(roles) do
            local name = c.burners[role]
            requires(name, { "setSignal", "getSignal" })
            local signal = p.call(name, "getSignal")
            bounded(signal, 0, 15, name .. " signal")
            collective = collective + signal / 4
        end
        local gyro = assert(p.wrap(c.gyro.name), "Gyro is missing: " .. c.gyro.name)
        M.attitude(gyro, c)
        base.inputs(p, services.batch)
        local state = { collective = collective, pitch = {}, roll = {} }
        if live then
            touched = true
            for _, bank in ipairs({ base.left, base.right }) do
                for _, name in ipairs(bank) do p.call(name, "setThrottle", 0) end
            end
            for _, bank in ipairs({ base.left, base.right }) do
                for _, name in ipairs(bank) do p.call(name, "setEnabled", true) end
            end
        end
        local ready, last = false, services.now()
        local timer = services.startTimer(c.interval)
        while true do
            local event, id = services.pullEvent()
            if event == "terminate" or (event == "key" and id == services.quitKey) then break end
            if event == "timer" and id == timer then
                -- Start the next timer before peripheral work, not after it.
                timer = services.startTimer(c.interval)
                local input, attitude
                batch({
                    function() input = base.inputs(p, services.batch) end,
                    function() attitude = M.attitude(gyro, c) end,
                })
                local now = services.now()
                local dt = math.max(0.001, now - last)
                last = now
                if not ready and not (input.forward or input.left or input.right or input.up or input.down) then
                    ready = true
                end
                local output
                if ready then
                    output = M.step(c, state, input, attitude, dt)
                    if live then
                        local jobs = {}
                        for _, side in ipairs({ "left", "right" }) do
                            for i, name in ipairs(base[side]) do
                                local device, throttle = name, output[side][i]
                                jobs[#jobs + 1] = function() p.call(device, "setThrottle", throttle) end
                            end
                        end
                        for _, role in ipairs(roles) do
                            local device, signal = c.burners[role], output.burners[role]
                            jobs[#jobs + 1] = function() p.call(device, "setSignal", signal) end
                        end
                        batch(jobs)
                    end
                end
                if services.observe then
                    services.observe(p, c, live, ready, input, attitude, state.collective, output, now, dt)
                end
                services.render(live, ready, attitude, state.collective, output)
            end
        end
    end)
    return ok, err, touched and base.stop(p) or {}
end
-- Starting a new recording replaces only previous flight-leveling JSONL logs.
M.recording = { maxBytes = 900 * 1024, reserveBytes = 32 * 1024 }
function M.clearRecordings(filesystem)
    for _, name in ipairs(filesystem.list("/")) do
        if name == "flight-leveling.jsonl" or name:match("^flight%-leveling%-%d+%.jsonl$") then
            local path = "/" .. name
            if not filesystem.isDir(path) then filesystem.delete(path) end
        end
    end
end
function M.recordingRoom(written, nextBytes, free)
    if written + nextBytes > M.recording.maxBytes then
        return false, "900 KB recording limit reached"
    end
    -- Leave room for filesystem allocation overhead as well as program updates.
    if type(free) == "number" and free - nextBytes < M.recording.reserveBytes + 1024 then
        return false, string.format("Only %d bytes free; need %d bytes (includes reserve)",
            free, nextBytes + M.recording.reserveBytes + 1024)
    end
    return true
end
-- Read-only disk report. Other mounted drives are excluded from root usage.
function M.diskUsage(filesystem)
    local rootDrive = filesystem.getDrive("/")
    local files = {}
    local function visit(directory)
        for _, name in ipairs(filesystem.list(directory)) do
            local path = filesystem.combine(directory, name)
            if filesystem.getDrive(path) == rootDrive then
                if filesystem.isDir(path) then visit(path)
                else files[#files + 1] = { path = path, bytes = filesystem.getSize(path) } end
            end
        end
    end
    visit("/")
    table.sort(files, function(a, b)
        if a.bytes == b.bytes then return a.path < b.path end
        return a.bytes > b.bytes
    end)
    return { free = filesystem.getFreeSpace("/"), capacity = filesystem.getCapacity("/"), files = files }
end
function M.recordingHeader(c, base)
    local header = { schema = 3, type = "layout", controllerVersion = M.version,
        tuning = { pitch = c.pitch, roll = c.roll, filterSeconds = c.derivativeFilterSeconds,
            burnerPitchAuthority = c.burnerPitchAuthority, burnerRollAuthority = c.burnerRollAuthority,
            thrusterPitchAuthority = c.thrusterPitchAuthority,
            burnerTrim = c.burnerTrim, thrusterPitchTrim = c.thrusterPitchTrim or 0,
            thrusterPitch = c.thrusterPitch or c.pitch },
        burners = {}, thrusters = {},
        columns = {
            angles = { "pitch", "roll" },
            rates = { "pitchDegreesPerSecond", "rollDegreesPerSecond" },
            inputs = { "forward", "left", "right", "up", "down" },
            state = { "live", "ready" },
            read = { "started", "finished" },
            burners = { "signal", "gasOutput", "x", "y", "z" },
            thrusters = { "throttle", "realThrust", "fuel", "enabled", "active" },
        } }
    for _, role in ipairs(roles) do
        header.burners[#header.burners + 1] = { role = role, name = c.burners[role] }
    end
    for _, bank in ipairs({ base.right, base.left }) do
        for _, name in ipairs(bank) do header.thrusters[#header.thrusters + 1] = name end
    end
    return header
end
function M.compactSample(sample, header)
    local function rounded(v)
        if type(v) == "number" then return math.floor(v * 10000 + 0.5) / 10000 end
        if type(v) ~= "table" then return v end
        local out = {}
        for k, value in pairs(v) do out[k] = rounded(value) end
        return out
    end
    local function status(result, fields, position)
        if not result then return { error = "missing reading" } end
        if result.error then return { error = tostring(result.error):sub(1, 160) } end
        if type(result.value) ~= "table" then return { error = "invalid status" } end
        local row = {}
        for _, key in ipairs(fields) do
            local value = result.value[key]
            if value == nil then return { error = "missing " .. key } end
            row[#row + 1] = value
        end
        if position then
            local p = result.value.position
            if type(p) ~= "table" or p.x == nil or p.y == nil or p.z == nil then
                return { error = "missing world position" }
            end
            row[#row + 1], row[#row + 2], row[#row + 3] = p.x, p.y, p.z
        end
        return row
    end
    local input = sample.inputs or {}
    local out = { time = sample.time, dt = sample.controlDt,
        read = { sample.readStarted, sample.readFinished },
        state = { sample.live, sample.ready },
        inputs = { not not input.forward, not not input.left, not not input.right,
            not not input.up, not not input.down },
        angles = { sample.attitude.pitch, sample.attitude.roll },
        collective = sample.collective, burners = {}, thrusters = {} }
    out.gimbal = sample.gimbal and (sample.gimbal.value or
        { error = tostring(sample.gimbal.error):sub(1, 160) })
    if sample.requested then
        if sample.requested.rates then
            out.rates = { sample.requested.rates.pitch, sample.requested.rates.roll }
        end
        out.commands = { burners = {}, thrusters = {} }
        for _, corner in ipairs(header.burners) do
            out.commands.burners[#out.commands.burners + 1] = sample.requested.burners[corner.role]
        end
        for _, side in ipairs({ "right", "left" }) do
            for _, throttle in ipairs(sample.requested[side]) do
                out.commands.thrusters[#out.commands.thrusters + 1] = throttle
            end
        end
    end
    for i, corner in ipairs(header.burners) do
        local burner = sample.burners and sample.burners[corner.role]
        out.burners[i] = status(burner and burner.status, { "signal", "gasOutput" }, true)
    end
    for i, name in ipairs(header.thrusters) do
        out.thrusters[i] = status(sample.thrusters and sample.thrusters[name],
            { "throttle", "realThrust", "fuel", "enabled", "active" })
    end
    return rounded(out)
end

local function main(args)
    if #args == 1 and args[1] == "--disk" then
        local disk = M.diskUsage(fs)
        print("Disk capacity: " .. tostring(disk.capacity) .. " bytes")
        print("Disk free: " .. tostring(disk.free) .. " bytes")
        print("Largest files on computer drive:")
        for i = 1, math.min(15, #disk.files) do
            print(string.format("%d  %s", disk.files[i].bytes, disk.files[i].path))
        end
        return
    end
    local live, record = false, false
    for _, arg in ipairs(args) do
        if arg == "--run" then live = true
        elseif arg == "--preview" then live = false
        elseif arg == "--record" then record = true
        else error("Usage: stabilizer [--preview|--run] [--record] or --disk", 0) end
    end
    local directory = fs.getDir(shell.getRunningProgram())
    local base = assert(loadfile(fs.combine(directory, "controller.lua")))("--module")
    local c = assert(loadfile(fs.combine(directory, "aircraft_config.lua")))()
    local log, logPath, latest, recordError = nil, nil, nil, nil
    local logBytes = 0
    local header = M.recordingHeader(c, base)
    if record then
        logPath = "flight-leveling.jsonl"
        local ok, reason = pcall(function()
            local line = textutils.serializeJSON(header)
            M.clearRecordings(fs)
            local room, why = M.recordingRoom(0, #line + 1, fs.getFreeSpace("/"))
            if not room then error(why, 0) end
            local openError
            log, openError = fs.open(logPath, "w")
            assert(log, openError or ("Cannot write " .. logPath))
            log.writeLine(line)
            log.flush()
            logBytes = #line + 1
        end)
        if not ok then
            recordError = tostring(reason)
            if log then pcall(log.close); log = nil end
        end
    end
    local function batch(jobs)
        if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
    end
    -- This observer only publishes an immutable snapshot. No peripheral or disk I/O.
    local function observe(_, _, running, ready, input, attitude, collective, output, time, dt)
        latest = { time = time, controlDt = dt, live = running, ready = ready,
            inputs = input, attitude = attitude, collective = collective, requested = output }
    end
    local function recorder()
        while true do
            if log and latest then
                local ok, reason = pcall(function()
                    local snapshot = latest
                    local sample = {}
                    for k, v in pairs(snapshot) do sample[k] = v end
                    sample.readStarted = os.clock()
                    sample.burners, sample.thrusters = {}, {}
                    local function read(name, method)
                        local success, value = pcall(peripheral.call, name, method)
                        return success and { value = value } or { error = tostring(value) }
                    end
                    local jobs = { function() sample.gimbal = read(c.gyro.name, "getAngles") end }
                    for _, role in ipairs(roles) do
                        local corner = role
                        jobs[#jobs + 1] = function()
                            sample.burners[corner] = { name = c.burners[corner],
                                status = read(c.burners[corner], "getStatus") }
                        end
                    end
                    for _, bank in ipairs({ base.left, base.right }) do
                        for _, name in ipairs(bank) do
                            local device = name
                            jobs[#jobs + 1] = function() sample.thrusters[device] = read(device, "getStatus") end
                        end
                    end
                    batch(jobs)
                    sample.readFinished = os.clock()
                    local line = textutils.serializeJSON(M.compactSample(sample, header))
                    local room, why = M.recordingRoom(logBytes, #line + 1, fs.getFreeSpace("/"))
                    if not room then
                        recordError = why
                        local handle = log
                        log = nil
                        pcall(handle.close)
                        return
                    end
                    log.writeLine(line)
                    log.flush()
                    logBytes = logBytes + #line + 1
                end)
                if not ok then
                    recordError = tostring(reason)
                    if log then pcall(log.close) end
                    log = nil
                end
            end
            -- Raw event wait: Ctrl+T is handled by the controller, including cleanup.
            local timer = os.startTimer(0.5)
            repeat
                local event, id = os.pullEventRaw()
                if event == "timer" and id == timer then break end
            until false
        end
    end
    local nextRender = 0
    local function render(live, ready, attitude, collective, output)
        if os.clock() < nextRender then return end
        nextRender = os.clock() + 0.25
        term.clear()
        term.setCursorPos(1, 1)
        print("LEVELING " .. M.version .. (live and " - LIVE" or " - PREVIEW"))
        print(ready and "Target: pitch 0, roll 0" or "Release W/A/D/Space/Shift first")
        print(string.format("Pitch %.1f  Roll %.1f deg", attitude.pitch, attitude.roll))
        print(string.format("Burner collective %.1f /15", collective))
        if output then
            print(string.format("Pitch rate %.1f  Roll rate %.1f /s", output.rates.pitch, output.rates.roll))
            print(string.format("Burners LF %d LB %d RF %d RB %d",
                output.burners.leftFront, output.burners.leftBack,
                output.burners.rightFront, output.burners.rightBack))
            for _, side in ipairs({ "left", "right" }) do
                local row = {}
                for i, throttle in ipairs(output[side]) do row[i] = string.format("%.0f", throttle * 100) end
                print(side .. " bottom->top %: " .. table.concat(row, "/"))
            end
        end
        print("W thrust | A/D yaw | Space/Shift lift")
        print("Q stop thrust; burner settings retained")
        if latest then print(string.format("Control interval: %.3fs", latest.controlDt)) end
        if recordError then print("Recording stopped: " .. recordError)
        elseif logPath then print("Recording: " .. logPath) end
    end
    local ok, err, failures
    local function control()
        ok, err, failures = M.run(peripheral, base, c, {
            now = os.clock, pullEvent = os.pullEventRaw, startTimer = os.startTimer,
            quitKey = keys.q, render = render, observe = observe, batch = batch,
        }, live)
    end
    if record then parallel.waitForAny(control, recorder) else control() end
    if log then pcall(log.close) end
    if logBytes > 0 then print("Saved " .. logPath .. " (" .. logBytes .. " bytes)") end
    -- The live display already shows the recorder stop reason.
    print("Leveling stopped. Burner settings retained.")
    for _, failure in ipairs(failures) do print("Stop failed: " .. failure) end
    if not ok then error(err, 0) end
end
if ... == "--module" then return M end
main({ ... })
