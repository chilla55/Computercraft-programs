-- Read help and current values without changing actuator settings.
local args = { ... }
assert(#args <= 1, "Usage: probe_api [output-file]")
local path = args[1] or "flight-api.txt"
if args[1] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index = 1
    while fs.exists(path) do
        path = "flight-api-" .. index .. ".txt"
        index = index + 1
    end
end
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local lines = {}
local function emit(line)
    lines[#lines + 1] = line
    file.writeLine(line)
    file.flush()
end
local function pack(...) return { n = select("#", ...), ... } end
local function inspect(name, method, ...)
    emit(name .. "." .. method .. "(" .. textutils.serialize({ ... }) .. ")")
    local results = pack(pcall(peripheral.call, name, method, ...))
    if not results[1] then
        if results[2] == "Terminated" then error("Terminated", 0) end
        emit("  ERROR: " .. tostring(results[2]))
    elseif results.n == 1 then
        emit("  (no return values)")
    else
        for i = 2, results.n do
            emit("  Return " .. (i - 1) .. ": " .. textutils.serialize(results[i]))
        end
    end
end
local function reads(name, methods)
    for _, method in ipairs(methods) do inspect(name, method) end
end
local ok, err = pcall(function()
    emit("Flight API probe: help and read methods only")
    for _, name in ipairs({ "thruster_0", "hot_air_burner_2" }) do
        reads(name, { "getApiVersion", "methods", "help" })
    end
    for _, method in ipairs({ "setThrottle", "setControlMode", "setEnabled",
        "clearThrottleOverride", "getStatus" }) do
        inspect("thruster_0", "help", method)
    end
    for _, method in ipairs({ "setSignal", "getSignal", "getStatus" }) do
        inspect("hot_air_burner_2", "help", method)
    end
    for i = 0, 7 do
        reads("thruster_" .. i, { "getName", "getStatus", "getControlMode",
            "isEnabled", "getThrottle", "getThrust", "getRealThrust", "getFuel" })
    end
    for i = 2, 5 do
        reads("hot_air_burner_" .. i, { "getName", "getStatus", "getSignal",
            "getPosition", "getFacing", "getWorldFacing" })
    end
    -- Only call advertised documentation and attitude/status read methods.
    local sensorReads = {
        help = true, methods = true, getApiVersion = true, getStatus = true,
        getPitch = true, getRoll = true, getYaw = true, getAngles = true, getAnglesRad = true,
        getOrientation = true, getRotation = true, getQuaternion = true,
        getEulerAngles = true,
    }
    for _, name in ipairs(peripheral.getNames()) do
        local types = { peripheral.getType(name) }
        local description = (name .. " " .. table.concat(types, " ")):lower()
        if description:find("gyro", 1, true) or description:find("gimbal", 1, true) then
            emit("Attitude sensor: " .. name)
            local methods = peripheral.getMethods(name) or {}
            emit(textutils.serialize(methods))
            for _, method in ipairs(methods) do
                if sensorReads[method] then inspect(name, method) end
            end
        end
    end
    reads("velocity_sensor_1", { "getVelocity" })
    reads("altitude_sensor_0", { "getHeight", "getAirPressure" })
    reads("sophisticatedstorage:barrel_0", { "size", "list" })
    for _, name in ipairs({ "redstone_relay_2", "redstone_relay_3" }) do
        for _, side in ipairs({ "top", "bottom", "back" }) do
            inspect(name, "getAnalogInput", side)
        end
    end
end)
file.close()
if not ok then error(err, 0) end
print("Saved API probe to " .. path)
textutils.pagedPrint(table.concat(lines, "\n"))
