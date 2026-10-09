-- Run in CraftOS: dump_peripherals [output-file]
-- Inspect names/types/methods only; never invoke device methods.
local args = { ... }
assert(#args <= 1, "Usage: dump_peripherals [output-file]")
local path = args[1] or "flight-peripherals.txt"
if args[1] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index = 1
    while fs.exists(path) do
        path = "flight-peripherals-" .. index .. ".txt"
        index = index + 1
    end
end

local targets = {
    "sophisticatedstorage:barrel_0",
    "thruster_0",
    "hot_air_burner_2",
    "hot_air_burner_3",
    "hot_air_burner_4",
    "hot_air_burner_5",
    "gimbal_sensor_0",
    "velocity_sensor_1",
    "altitude_sensor_0",
    "redstone_relay_2",
    "redstone_relay_3",
}
local lines = {}
local function emit(line) lines[#lines + 1] = line end
emit("Flight controller peripheral discovery")
emit("Names and methods only; device methods were not called.")
emit("")
emit("All connected peripherals:")
local names = peripheral.getNames()
table.sort(names)
-- Include newly installed gyros and any other connected device automatically.
local seen = {}
for _, name in ipairs(targets) do seen[name] = true end
for _, name in ipairs(names) do
    if not seen[name] then targets[#targets + 1] = name; seen[name] = true end
end
table.sort(targets)
for _, name in ipairs(names) do emit("  " .. name) end
if #names == 0 then emit("  (none)") end

for _, name in ipairs(targets) do
    emit("")
    emit("[" .. name .. "]")
    local ok, types, methods = pcall(function()
        if not peripheral.isPresent(name) then return nil end
        return { peripheral.getType(name) }, peripheral.getMethods(name)
    end)
    if not ok then
        emit("  Inspection failed: " .. tostring(types))
    elseif not types or not methods then
        emit("  MISSING or disconnected; check the wired modem connection/name.")
    else
        emit("  Types: " .. table.concat(types, ", "))
        table.sort(methods)
        emit("  Methods:")
        for _, method in ipairs(methods) do emit("    " .. method) end
        if #methods == 0 then emit("    (none)") end
    end
end

local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
file.write(table.concat(lines, "\n") .. "\n")
file.close()
print("Saved peripheral dump to " .. path)
textutils.pagedPrint(table.concat(lines, "\n"))
