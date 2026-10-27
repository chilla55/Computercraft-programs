-- Discover the custom transformer API without moving shafts or switching power.
-- Run: probe [unpowered|powered|label] [output-file]
local args = { ... }
assert(#args <= 2, "Usage: probe [condition-label] [output-file]")
local label = args[1] or "snapshot"
assert(label:match("^[%w_-]+$"), "Use letters, numbers, underscores or hyphens for the label")
local path = args[2] or ("custom-transformer-" .. label .. ".txt")
if args[2] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index, base = 1, path:sub(1, -5)
    while fs.exists(path) do
        path = base .. "-" .. index .. ".txt"
        index = index + 1
    end
end

local stages = {
    { name = "powergrid_addon_variac_0", uncooled = 10, cooled = 40 },
    { name = "powergrid_addon_variac_1", uncooled = 10, cooled = 40 },
    { name = "powergrid_addon_variac_2", uncooled = 40, cooled = 200 },
}
-- Explicit list only: never invoke an unfamiliar method just because its name
-- starts with get. Unrecognized methods remain in the report for API review.
local readMethods = {
    "getApiVersion", "getStatus", "getThermalStatus", "getPosition", "getRatio",
    -- Candidate reads verified in local ComputerIntegration.java; the server
    -- may be older, so call each only if the deployed peripheral advertises it.
    "getInputVoltage", "getInputCurrent", "getOutputVoltage", "getOutputCurrent",
    "getOutputPower", "getEnergyStored", "getTemperature", "getCoolingStatus",
    "voltage", "current", "power", "isClosed", "isRunning", "getSpeed",
}
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local function emit(text)
    file.writeLine(text)
    file.flush()
end
local function pack(...) return { n = select("#", ...), ... } end
local function serialize(value) return textutils.serialize(value) end
local function inspect(name, method, ...)
    emit(name .. "." .. method .. " " .. serialize({ ... }))
    local result = pack(pcall(peripheral.call, name, method, ...))
    if not result[1] then
        if result[2] == "Terminated" then error("Terminated", 0) end
        emit("  ERROR: " .. tostring(result[2]))
    elseif result.n == 1 then
        emit("  (no return values)")
    else
        for i = 2, result.n do
            emit("  Return " .. (i - 1) .. ": " .. serialize(result[i]))
        end
    end
end
local found, missing = 0, {}
local ok, failure = pcall(function()
    emit("Custom transformer API probe / schema 1")
    emit("Operator condition label: " .. label .. " (not a verified cooling state)")
    emit("UTC capture timestamp (ms): " .. os.epoch("utc"))
    emit("Series: powergrid_addon_variac_0 -> powergrid_addon_variac_1 -> powergrid_addon_variac_2")
    emit("Operator nominal source: 264001 V; final target: 240 V")
    emit("Ratings below are manually supplied; never inferred from API/type/name.")
    emit("No hardware writes, redstone outputs or modem transmissions. Sequential readings, not atomic.")
    emit("Candidate read names from newer local addon source; deployed advertised methods take priority.")
    for i, stage in ipairs(stages) do
        emit(string.format("Stage %d: %s / uncooled %d A / cooled %d A",
            i, stage.name, stage.uncooled, stage.cooled))
    end

    local names, seen = peripheral.getNames(), {}
    for _, name in ipairs(names) do seen[name] = true end
    for _, stage in ipairs(stages) do
        if seen[stage.name] then found = found + 1
        else
            missing[#missing + 1] = stage.name
            emit("MISSING REQUIRED TRANSFORMER: " .. stage.name)
        end
    end
    table.sort(names)
    local inventory = {}
    for _, name in ipairs(names) do
        emit("\nPERIPHERAL: " .. name)
        local types = pack(pcall(peripheral.getType, name))
        emit("Types (pcall result followed by types): " .. serialize(types))
        local success, methods = pcall(peripheral.getMethods, name)
        if not success then
            if methods == "Terminated" then error("Terminated", 0) end
            emit("Method discovery ERROR: " .. tostring(methods))
        elseif type(methods) ~= "table" then
            emit("Method discovery ERROR: peripheral unavailable")
        else
            table.sort(methods)
            emit("Advertised methods: " .. serialize(methods))
            local available = {}
            for _, method in ipairs(methods) do available[method] = true end
            inventory[#inventory + 1] = { name = name, methods = available }
            local recognized = {help = true, methods = true}
            for _, method in ipairs(readMethods) do recognized[method] = true end
            local notCalled = {}
            for _, method in ipairs(methods) do
                if not recognized[method] then notCalled[#notCalled + 1] = method end
            end
            emit("Listed only, NOT invoked: " .. serialize(notCalled))
            -- Ask the peripheral itself about its API, including setter
            -- documentation. Calling help never calls the described setter.
            if available.help then
                inspect(name, "help")
                for _, method in ipairs(methods) do inspect(name, "help", method) end
            end
            if available.methods then inspect(name, "methods") end
        end
    end
    for sample = 1, 3 do
        emit("\nSAMPLE " .. sample .. " / UTC ms " .. os.epoch("utc"))
        for _, entry in ipairs(inventory) do
            for _, method in ipairs(readMethods) do
                if entry.methods[method] then inspect(entry.name, method) end
            end
        end
        if sample < 3 then sleep(0.5) end
    end
    emit("\nCOMPLETE / required transformers found: " .. found .. "/3")
end)
if not ok then pcall(emit, "ABORTED: " .. tostring(failure)) end
file.close()
if not ok then error(failure, 0) end
print("Saved probe: " .. path)
print("Transformers found: " .. found .. "/3")
for _, name in ipairs(missing) do print("Missing: " .. name) end
print("Send the full report back to build the controller against this API.")
