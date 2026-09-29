-- Read help and current values without changing actuator settings.
local args = { ... }
assert(#args <= 1, "Usage: probe_setup [output-file]")
local stem = "fighter-setup-" .. os.getComputerID()
local path = args[1] or (stem .. ".txt")
if args[1] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index = 1
    while fs.exists(path) do
        path = stem .. "-" .. index .. ".txt"
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
    emit("Fighter setup probe: read-only; no monitor writes or network transmissions")
    emit("Computer ID: " .. os.getComputerID())
    local label = os.getComputerLabel() -- Capture zero returned values as nil.
    emit("Computer label: " .. (label == nil and "(unlabelled)" or tostring(label)))
    reads("bottom", { "isWireless", "getNameLocal", "getNamesRemote" })
    -- Direct and network names may be aliases. Read IDs rather than assuming.
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        local types = { peripheral.getType(name) }
        for _, kind in ipairs(types) do
            if kind == "computer" then
                reads(name, { "getID", "getLabel", "isOn" })
                break
            end
        end
    end
    reads("monitor_1", { "getSize", "getTextScale", "isColor" })
    reads("simulated:portable_engine_0", { "size", "list" })
    reads("sophisticatedstorage:barrel_3", { "size", "list" })
    reads("linked_typewriter_1", { "getPressedKeyCodes" })
    reads("gimbal_sensor_1", { "getAngles", "getAnglesRad" })
    reads("navigation_table_0", { "getBlockPos", "getTablePosition",
        "getTargetPosition", "getTargetDistance", "getRelativeAngle", "getRelativeAngleRad" })
    reads("create_radar:plane_radar_2", { "getPosition", "getRange" })
end)
file.close()
if not ok then error(err, 0) end
print("Saved setup probe to " .. path)
textutils.pagedPrint(table.concat(lines, "\n"))
