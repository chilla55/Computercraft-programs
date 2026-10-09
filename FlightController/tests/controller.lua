local M = assert(loadfile("FlightController/controller.lua"))("--module")
local function near(a, b) assert(math.abs(a - b) < 0.00001, tostring(a) .. " ~= " .. tostring(b)) end
local function mix(input, burners, dt)
    return M.mix(input, { burners = burners or { 0, 0 } }, dt or 0.1)
end
local o = mix({ forward = true })
near(o.left, 1); near(o.right, 1)
o = mix({ forward = true, left = true })
near(o.left, 0); near(o.right, 1)
o = mix({ forward = true, right = true })
near(o.left, 1); near(o.right, 0)
o = mix({ left = true })
near(o.left, 0); near(o.right, 1)
o = mix({ right = true })
near(o.left, 1); near(o.right, 0)
o = mix({ left = true, right = true, forward = true })
near(o.left, 1); near(o.right, 1)
o = mix({ backward = true })
near(o.left, 0); near(o.right, 0)
o = mix({ up = true }, { 15, 14 }, 1)
assert(o.burners[1] == 15 and o.burners[2] == 15)
o = mix({ down = true }, { 0, 1 }, 1)
assert(o.burners[1] == 0 and o.burners[2] == 0)
o = mix({ up = true, down = true }, { 8, 9 }, 1)
assert(o.burners[1] == 8 and o.burners[2] == 9)
local state = { burners = { 0, 0 } }
for _ = 1, 5 do o = M.mix({ up = true }, state, 0.1) end
assert(o.burners[1] == 1 and o.burners[2] == 1)
o = M.mix({}, state, 1)
assert(o.burners[1] == 1)

local function scenario(live, options)
    options = options or {}
    local tick, writes, displays, stopped = 0, {}, {}, {}
    local p = {}
    p.getMethods = function(name)
        if name == options.missing then return nil end
        return { "setThrottle", "setEnabled", "setSignal", "getSignal", "getAnalogInput" }
    end
    p.call = function(name, method, value)
        if method == "getSignal" then return 7 end
        if method == "getAnalogInput" then
            if tick == 3 and options.inputFault then error("relay disconnected") end
            return (tick == 1 or tick >= 3) and name == "redstone_relay_2" and value == "top" and 15 or 0
        end
        writes[#writes + 1] = { name, method, value }
        if options.outputFault and tick == 3 and name == "thruster_4" then error("actuator disconnected") end
        if method == "setEnabled" and value == false then stopped[name] = true end
    end
    local ok, err, failures = M.run(p, live, {
        now = function() return tick * 0.1 end,
        startTimer = function() return 1 end,
        pullEvent = function()
            tick = tick + 1
            if tick == 4 then return options.terminate and "terminate" or "key", 99 end
            return "timer", 1
        end,
        quitKey = 99,
        render = function(_, _, ready, _, output)
            displays[#displays + 1] = { ready = ready, output = output }
        end,
    })
    return ok, err, failures, writes, displays, stopped
end
local ok, _, _, writes, displays, stopped = scenario(false)
assert(ok and #writes == 0)
assert(not displays[1].ready and displays[1].output.left == 0)
assert(displays[2].ready and displays[3].output.left == 1)
ok, _, _, writes, displays, stopped = scenario(true, { terminate = true })
assert(ok)
for i = 0, 7 do assert(stopped["thruster_" .. i]) end
for _, write in ipairs(writes) do
    if write[2] == "setSignal" then assert(write[3] == 7) end
end
ok, _, _, writes = scenario(true, { missing = "thruster_7" })
assert(not ok and #writes == 0)
ok, _, _, _, _, stopped = scenario(true, { inputFault = true })
assert(not ok)
for i = 0, 7 do assert(stopped["thruster_" .. i]) end
local failures
ok, _, failures, _, _, stopped = scenario(true, { outputFault = true })
assert(not ok and #failures == 2)
for i = 0, 7 do if i ~= 4 then assert(stopped["thruster_" .. i]) end end
print("Flight controller tests passed")
