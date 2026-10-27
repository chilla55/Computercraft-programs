local source = "Powerplant/custom_transformer/probe.lua"
local function run(options)
    options = options or {}
    local lines, calls, closed, opened = {}, {}, false, nil
    local names = {"powergrid_addon_variac_0", "powergrid_addon_variac_1"}
    if not options.missing then names[#names + 1] = "powergrid_addon_variac_2" end
    names[#names + 1] = "powergrid_voltage_gauge_0"
    local env = setmetatable({
        print = function() end,
        sleep = function(seconds) assert(seconds == 0.5) end,
        os = {epoch = function(locale) assert(locale == "utc"); return 1000 end},
        textutils = {serialize = function(value)
            if type(value) ~= "table" then return tostring(value) end
            local parts = {}
            for _, entry in ipairs(value) do parts[#parts + 1] = tostring(entry) end
            return "{" .. table.concat(parts, ",") .. "}"
        end},
        fs = {
            exists = function(path) return path == "custom-transformer-snapshot.txt" end,
            open = function(path)
                opened = path
                return {
                    writeLine = function(line) lines[#lines + 1] = line end,
                    flush = function() end,
                    close = function() closed = true end,
                }
            end,
        },
        peripheral = {
            getNames = function() return names end,
            getType = function() return "custom_variac", "generic" end,
            getMethods = function(name)
                if name:find("gauge", 1, true) then return {"voltage"} end
                local methods = {"getStatus", "getThermalStatus", "getRatio",
                    "getInputVoltage", "getOutputVoltage", "getInputCurrent", "getOutputCurrent",
                    "getOutputPower", "getTemperature", "getCoolingStatus", "getEnergyStored",
                    "setRatio", "open", "close", "getUnknownNewMethod"}
                if not options.noHelp then
                    methods[#methods + 1] = "help"; methods[#methods + 1] = "methods"
                end
                return methods
            end,
            call = function(name, method, ...)
                assert(method == "help" or method == "methods" or method == "getStatus"
                    or method == "getThermalStatus" or method == "getRatio" or method == "voltage"
                    or method == "getInputVoltage" or method == "getOutputVoltage"
                    or method == "getInputCurrent" or method == "getOutputCurrent"
                    or method == "getOutputPower" or method == "getTemperature"
                    or method == "getCoolingStatus" or method == "getEnergyStored",
                    "Unexpected method invocation: " .. method)
                calls[#calls + 1] = {name, method, ...}
                if options.terminate and method == "getStatus" then error("Terminated", 0) end
                if method == "getThermalStatus" then error("injected telemetry failure") end
                if method == "getRatio" then return 0.1, 10 end
                if method == "getCoolingStatus" then return {powered = false, capacity = 10} end
                if method == "voltage" then return 264001 end
                return {position = 0.1}
            end,
        },
    }, {__index = _G})
    local ok, why = pcall(assert(loadfile(source, "t", env)), table.unpack(options.args or {}))
    return {ok = ok, why = why, text = table.concat(lines, "\n"), calls = calls,
        closed = closed, opened = opened}
end
local result = run()
assert(result.ok, result.why)
assert(result.closed and result.opened == "custom-transformer-snapshot-1.txt")
assert(result.text:find("required transformers found: 3/3", 1, true))
assert(result.text:find("injected telemetry failure", 1, true))
assert(result.text:find("Return 2: 10", 1, true))
assert(result.text:find("getUnknownNewMethod", 1, true))
local statuses, documentedSetter = 0, false
for _, call in ipairs(result.calls) do
    if call[2] == "getStatus" then statuses = statuses + 1 end
    if call[2] == "help" and call[3] == "setRatio" then documentedSetter = true end
end
assert(statuses == 9 and documentedSetter)
result = run({noHelp = true})
assert(result.ok and result.text:find("getCoolingStatus", 1, true))
local coolingReads = 0
for _, call in ipairs(result.calls) do
    assert(call[2] ~= "help" and call[2] ~= "methods")
    if call[2] == "getCoolingStatus" then coolingReads = coolingReads + 1 end
end
assert(coolingReads == 9)
result = run({missing = true, args = {"unpowered"}})
assert(result.ok and result.text:find("MISSING REQUIRED TRANSFORMER: powergrid_addon_variac_2", 1, true))
result = run({terminate = true})
assert(not result.ok and result.why == "Terminated" and result.closed)
assert(result.text:find("ABORTED: Terminated", 1, true))
result = run({args = {"powered", "custom-transformer-snapshot.txt"}})
assert(not result.ok and not result.opened)
print("Custom transformer probe: discovery, read-only calls, samples, errors and interruption passed")
