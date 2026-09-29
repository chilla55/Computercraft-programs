-- Read help and current values without changing actuator settings.
local args = { ... }
assert(#args <= 1, "Usage: probe_api [output-file]")
local path = args[1] or "fighter-api.txt"
if args[1] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index = 1
    while fs.exists(path) do
        path = "fighter-api-" .. index .. ".txt"
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
    emit("Fighter jet API probe: help and read methods only")
    emit("No actuator setters, inventory transfers, or modem transmissions are called.")
    for _, name in ipairs({ "thruster_8", "directional_gearshift_2" }) do
        reads(name, { "getApiVersion", "methods", "help" })
    end
    for _, method in ipairs({ "setThrottle", "setControlMode", "setEnabled", "getStatus" }) do
        inspect("thruster_8", "help", method)
    end
    for _, method in ipairs({ "setLeft", "setRight", "setOutputs", "clear", "getRotationModifier" }) do
        inspect("directional_gearshift_2", "help", method)
    end
    for i = 8, 11 do
        reads("thruster_" .. i, { "getName", "getStatus", "getControlMode",
            "isEnabled", "getThrottle", "getThrust", "getRealThrust", "getFuel" })
    end
    for i = 2, 3 do
        reads("directional_gearshift_" .. i, { "getName", "getStatus", "getPosition",
            "getFacing", "getWorldFacing", "isLeftPowered", "isRightPowered" })
        for _, face in ipairs({ "down", "up", "north", "south", "west", "east" }) do
            inspect("directional_gearshift_" .. i, "getRotationModifier", face)
        end
    end
    for i = 0, 1 do
        reads("torsion_spring_" .. i, { "getAngle", "getAngleRad", "getLimit", "isRunning" })
    end
    reads("gimbal_sensor_1", { "getAngles", "getAnglesRad" })
    reads("velocity_sensor_2", { "getVelocity" })
    reads("altitude_sensor_1", { "getHeight", "getAirPressure" })
    reads("create_radar:plane_radar_1", { "getPosition", "getRange", "getTracks" })
    reads("sophisticatedstorage:barrel_3", { "size", "list" })
    reads("create_radar:network_filterer_block_entity_1", { "size", "list" })
    reads("top", { "getPressedKeyCodes" })
end)
file.close()
if not ok then error(err, 0) end
print("Saved API probe to " .. path)
textutils.pagedPrint(table.concat(lines, "\n"))
