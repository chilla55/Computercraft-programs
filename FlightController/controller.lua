-- Manual flight controller. Default mode previews outputs; --run controls hardware.
local M = {}
M.config = {
    burnerStepsPerSecond = 2,
    interval = 0.10,
}
M.right = { "thruster_0", "thruster_1", "thruster_2", "thruster_3" }
M.left = { "thruster_4", "thruster_5", "thruster_6", "thruster_7" }
M.burners = { "hot_air_burner_0", "hot_air_burner_1" } -- left, right
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function validSignal(v)
    return type(v) == "number" and v == v and v >= 0 and v <= 15
end

function M.mix(input, state, dt)
    local c = M.config
    local left, right = 0, 0
    if input.forward then left, right = 1, 1 end
    if input.left ~= input.right then
        if input.left then left, right = 0, 1
        else left, right = 1, 0 end
    end
    local direction = (input.up and 1 or 0) - (input.down and 1 or 0)
    for i = 1, 2 do
        state.burners[i] = clamp(state.burners[i] +
            direction * c.burnerStepsPerSecond * dt, 0, 15)
    end
    return {
        left = clamp(left, 0, 1), right = clamp(right, 0, 1),
        burners = { math.floor(state.burners[1] + 0.5),
                    math.floor(state.burners[2] + 0.5) },
    }
end

function M.inputs(p, batch)
    local function active(name, side)
        local value = p.call(name, "getAnalogInput", side)
        assert(validSignal(value), name .. ": invalid input on " .. side)
        return value > 0
    end
    local input, jobs = {}, {}
    local mapping = {
        { "forward", "redstone_relay_2", "top" },
        { "down", "redstone_relay_2", "bottom" },
        { "up", "redstone_relay_2", "back" },
        { "right", "redstone_relay_3", "top" },
        { "left", "redstone_relay_3", "back" },
    }
    for _, binding in ipairs(mapping) do
        local key, name, side = binding[1], binding[2], binding[3]
        jobs[#jobs + 1] = function() input[key] = active(name, side) end
    end
    if batch then batch(jobs) else for _, job in ipairs(jobs) do job() end end
    return input -- Relay 3 bottom remains reserved for reverse.

end
local function released(input)
    return not (input.forward or input.down or input.up or input.left or input.right)
end
local function eachThruster(fn)
    for _, group in ipairs({ M.left, M.right }) do
        for _, name in ipairs(group) do fn(name) end
    end
end
function M.preflight(p)
    local function requireMethods(name, methods)
        local found = {}
        for _, method in ipairs(p.getMethods(name) or {}) do found[method] = true end
        for _, method in ipairs(methods) do
            assert(found[method], name .. ": missing " .. method)
        end
    end
    eachThruster(function(name)
        requireMethods(name, { "setThrottle", "setEnabled" })
    end)
    for _, name in ipairs({ "redstone_relay_2", "redstone_relay_3" }) do
        requireMethods(name, { "getAnalogInput" })
    end
    local state = { burners = {} }
    for i, name in ipairs(M.burners) do
        requireMethods(name, { "setSignal", "getSignal" })
        local signal = p.call(name, "getSignal")
        assert(validSignal(signal), name .. ": invalid burner signal")
        state.burners[i] = signal
    end
    M.inputs(p)
    return state
end
function M.apply(p, output)
    for _, name in ipairs(M.left) do p.call(name, "setThrottle", output.left) end
    for _, name in ipairs(M.right) do p.call(name, "setThrottle", output.right) end
    for i, name in ipairs(M.burners) do p.call(name, "setSignal", output.burners[i]) end
end
-- Best effort: a failed device must not prevent stopping the remaining devices.
function M.stop(p)
    local failures = {}
    eachThruster(function(name)
        for _, command in ipairs({ { "setThrottle", 0 }, { "setEnabled", false } }) do
            local ok, err = pcall(p.call, name, command[1], command[2])
            if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
        end
    end)
    return failures
end

-- Services are injected so runtime fault/exit handling can be tested outside CC.
function M.run(p, live, services)
    local touched = false
    local ok, err = pcall(function()
        local state = M.preflight(p)
        if live then
            touched = true
            eachThruster(function(name) p.call(name, "setThrottle", 0) end)
            eachThruster(function(name) p.call(name, "setEnabled", true) end)
        end
        local ready = false
        local last = services.now()
        local timer = services.startTimer(M.config.interval)
        while true do
            local event, id = services.pullEvent()
            if event == "terminate" or (event == "key" and id == services.quitKey) then break end
            if event == "timer" and id == timer then
                local now = services.now()
                local dt = clamp(now - last, 0, 0.25)
                last = now
                local input = M.inputs(p)
                if not ready and released(input) then ready = true end
                local output
                if ready then
                    output = M.mix(input, state, dt)
                    if live then M.apply(p, output) end
                else
                    output = M.mix({}, state, 0)
                end
                services.render(p, live, ready, input, output)
                timer = services.startTimer(M.config.interval)
            end
        end
    end)
    local failures = touched and M.stop(p) or {}
    return ok, err, failures
end

-- Read back hardware state separately from the requested outputs.
function M.inspect(p, live, ready, input, output)
    local report = { live = live, ready = ready, inputs = input,
        requested = output, devices = {} }
    local function read(name, method)
        local ok, value = pcall(p.call, name, method)
        if not ok and value == "Terminated" then error(value, 0) end
        report.devices[name] = ok and { value = value } or { error = tostring(value) }
    end
    eachThruster(function(name) read(name, "getStatus") end)
    for _, name in ipairs(M.burners) do read(name, "getStatus") end
    read("altitude_sensor_0", "getHeight")
    read("velocity_sensor_1", "getVelocity")
    return report
end

local function main(args)
    assert(#args <= 1 and (not args[1] or args[1] == "--preview" or args[1] == "--run"),
        "Usage: controller [--preview|--run]")
    local live = args[1] == "--run"
    local report, nextTelemetry, message = nil, 0, ""
    local function value(name)
        local device = report and report.devices[name]
        return device and device.value
    end
    local function status(name)
        local result = value(name)
        return type(result) == "table" and result or {}
    end
    local function number(v)
        return type(v) == "number" and string.format("%.2f", v) or "?"
    end
    local function render(p, running, ready, input, output)
        if os.clock() >= nextTelemetry then
            report = M.inspect(p, running, ready, input, output)
            nextTelemetry = os.clock() + 0.5
        end
        local empty, disabled, active = {}, {}, 0
        eachThruster(function(name)
            local s = status(name)
            if type(s.fuel) == "number" and s.fuel <= 0 then
                empty[#empty + 1] = name:match("%d+$")
            end
            if s.enabled == false then disabled[#disabled + 1] = name:match("%d+$") end
            if s.active == true then active = active + 1 end
        end)
        local function signal(key) return input[key] and "1" or "0" end
        term.clear()
        term.setCursorPos(1, 1)
        print(running and "FLIGHT - LIVE" or "PREVIEW: use controller --run to fly")
        print(ready and "Controls ready" or "WAIT: release W/A/D/Space/Shift")
        print("Inputs W:" .. signal("forward") .. " A:" .. signal("left") ..
            " D:" .. signal("right") .. " Up:" .. signal("up") .. " Down:" .. signal("down"))
        print(string.format("Command thrust L %d%% R %d%%", output.left * 100, output.right * 100))
        print("Actual throttle 4(L):" .. number(status("thruster_4").throttle) ..
            " 0(R):" .. number(status("thruster_0").throttle))
        print("Active thrusters: " .. active .. "/8")
        print("Empty: " .. (#empty > 0 and table.concat(empty, ",") or "none reported"))
        print("Disabled: " .. (#disabled > 0 and table.concat(disabled, ",") or "none reported"))
        print(string.format("Command burner L %d R %d /15", output.burners[1], output.burners[2]))
        print("Actual burner L:" .. number(status(M.burners[1]).signal) ..
            " R:" .. number(status(M.burners[2]).signal))
        print("Gas L:" .. number(status(M.burners[1]).gasOutput) ..
            " R:" .. number(status(M.burners[2]).gasOutput))
        print("Height:" .. number(value("altitude_sensor_0")) ..
            " Velocity(raw):" .. number(value("velocity_sensor_1")))
        print("Space/Shift adjust burners; S inactive")
        print("Q stop thrust | P save diagnostic report")
        if message ~= "" then print(message) end
    end
    local function pullEvent()
        local event, id = os.pullEventRaw()
        if event == "key" and id == keys.p and report then
            local ok, result = pcall(function()
                local path, index = "flight-status.txt", 0
                while fs.exists(path) do
                    index = index + 1
                    path = "flight-status-" .. index .. ".txt"
                end
                local file, reason = fs.open(path, "w")
                assert(file, reason or ("Cannot write " .. path))
                file.write(textutils.serialize(report))
                file.close()
                return path
            end)
            if not ok and result == "Terminated" then error(result, 0) end
            message = ok and ("Saved " .. result) or ("Save failed: " .. tostring(result))
        end
        return event, id
    end
    local ok, err, failures = M.run(peripheral, live, {
        now = os.clock, startTimer = os.startTimer, pullEvent = pullEvent,
        quitKey = keys.q, render = render,
    })
    term.clear()
    term.setCursorPos(1, 1)
    print(live and "Stopped. Burner settings retained." or "Preview ended. No actuator writes.")
    for _, failure in ipairs(failures) do print("Stop failed: " .. failure) end
    if not ok then error(err, 0) end
end
if ... == "--module" then return M end
main({ ... })
