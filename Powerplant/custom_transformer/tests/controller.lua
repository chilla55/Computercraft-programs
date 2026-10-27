local M = dofile("Powerplant/custom_transformer/controller.lua")
local function near(a, b, tolerance) assert(math.abs(a - b) <= (tolerance or 1e-6), a .. " ~= " .. b) end
local function fixture()
    local c, f = M.defaults(), {source = 264001, commands = {}, load = 0, time = 0, loss = 0}
    f.stages = {}
    for i = 1, 3 do f.stages[i] = {enabled = false, ratio = i == 1 and 0.208407 or 0.01, requested = 0.01, full = false} end
    local function index(name)
        for i, stage in ipairs(c.stages) do if stage.name == name then return i end end
        error("unknown peripheral")
    end
    local io = {
        call = function(name, method, value)
            local i = index(name)
            f.commands[#f.commands + 1] = {i = i, method = method, value = value}
            if f.missing == i then error("peripheral offline") end
            if method == "setEnabled" then
                f.stages[i].enabled = value
                if value and (f.stages[i].temperature or 25) < 60 then f.stages[i].tripped = false end
            elseif method == "setRatio" then f.stages[i].requested = value
            else error("unsupported hardware write: " .. method) end
        end,
        read = function()
            local out, voltage = {}, f.source
            for i, stage in ipairs(f.stages) do
                if f.missing == i then error("telemetry offline") end
                local r = {inputVoltage = voltage, inputCurrent = 0, outputCurrent = 0,
                    ratio = stage.ratio, temperature = stage.temperature or 25,
                    status = stage.enabled and "running" or "disabled",
                    cooling = {installed = true, powered = stage.full, operating = stage.full,
                        blocked = false, airflow = stage.full and 1 or 0, speed = stage.full and 1 or 0,
                        slots = i == 3 and 2 or 1, fans = i == 3 and 2 or 1,
                        workingFans = stage.full and (i == 3 and 2 or 1) or 0,
                        poweredFans = stage.full and (i == 3 and 2 or 1) or 0,
                        blockedFans = 0, temperature = stage.temperature or 25,
                        tripped = stage.tripped or false,
                        capacity = stage.capacity or (stage.full and c.stages[i].cooled or c.stages[i].uncooled)}}
                voltage = stage.enabled and voltage * stage.ratio or 0
                if i == 3 and stage.enabled then voltage = math.max(0, voltage - f.loss) end
                r.outputVoltage = voltage
                out[i] = r
            end
            if f.stages[3].enabled and voltage > 0 then
                out[3].outputCurrent = f.load
                for i = 3, 1, -1 do
                    out[i].inputCurrent = out[i].outputCurrent * out[i].ratio
                    if i > 1 then out[i - 1].outputCurrent = out[i].inputCurrent end
                end
            end
            if f.mutate then f.mutate(out) end
            return out
        end,
    }
    f.io = io
    f.control = M.new(c, io)
    function f.step()
        f.time = f.time + 0.25
        for _, stage in ipairs(f.stages) do
            if not stage.jammed then
                stage.ratio = stage.ratio + math.max(-0.05, math.min(0.05, stage.requested - stage.ratio))
            end
        end
        local ok, why = pcall(f.control.tick, f.time)
        if not ok then f.control.stop("FAULT: " .. tostring(why)) end
        return ok, why
    end
    function f.start()
        local ok, why = pcall(f.control.start, f.time)
        if not ok then f.control.stop("FAULT: " .. tostring(why)) end
        return ok, why
    end
    function f.run()
        assert(f.start())
        for _ = 1, 200 do
            local ok, why = f.step(); assert(ok, why)
            if f.control.state.phase == "running" then return end
        end
        error("failed to reach running")
    end
    return f, c
end
local f = fixture()
f.run()
near(f.control.state.readings[3].outputVoltage, 240)
near(f.control.state.readings[1].outputVoltage, f.control.state.plan.volts[1], 2)
assert(f.stages[3].ratio < f.stages[1].ratio / 10, "largest reduction did not go to 200 A stage")
near(f.control.state.plan.coldAmps, 40); near(f.control.state.plan.cooledAmps, 200)
local sequence = {}
for _, command in ipairs(f.commands) do
    if command.method == "setEnabled" and command.value then sequence[#sequence + 1] = command.i end
end
assert(table.concat(sequence, ",") == "1,2,3")
assert(f.commands[1].i == 3 and f.commands[1].value == false)
-- Live source drift is corrected at the final stage; first two ratios stay put.
local first, second = f.stages[1].ratio, f.stages[2].ratio
f.source = 280000
for _ = 1, 40 do local ok, why = f.step(); assert(ok, why) end
near(f.control.state.readings[3].outputVoltage, 240, 2)
near(f.stages[1].ratio, first); near(f.stages[2].ratio, second)
f = fixture(); f.loss = 5; f.run()
near(f.control.state.readings[3].outputVoltage, 240, 2)
local defaults = M.defaults()
for _, source in ipairs({defaults.minimumInput, defaults.nominalInput, defaults.maximumInput}) do
    local plan = M.plan(defaults, source)
    near(plan.volts[3], 240)
    assert(plan.ratios[3] > defaults.minimumRatio and plan.ratios[3] < plan.ratios[1])
end
-- Every winding is checked, including reverse current and native derating.
for _, field in ipairs({"inputCurrent", "outputCurrent"}) do
    for i = 1, 3 do
        local test = fixture(); test.run()
        test.mutate = function(r) r[i][field] = -1000 end
        assert(not test.step())
        for _, stage in ipairs(test.stages) do assert(not stage.enabled) end
    end
end
f = fixture(); f.run()
for _, stage in ipairs(f.stages) do stage.full = true end
for _ = 1, 2 do assert(f.step()); near(f.control.state.limits[3], 40) end
assert(f.step()); near(f.control.state.limits[3], 200)
f.load = 150
assert(f.step())
f.stages[3].full = false
assert(not f.step()); assert(f.control.state.message:find("current exceeds", 1, true))
-- A single powered fan cannot grant the 200 A rating on the two-fan cabinet.
f = fixture(); f.run()
f.stages[3].full = true
f.mutate = function(r) r[3].cooling.workingFans = 1 end
for _ = 1, 5 do assert(f.step()); near(f.control.state.limits[3], 40) end
-- Lower effective capacity takes priority even with all fans operating.
f = fixture(); f.run(); f.stages[3].capacity = 20; f.load = 25
assert(not f.step())
for _, mutate in ipairs({
    function(r) r[3].outputVoltage = 270 end,
    function(r) r[3].outputVoltage = -240 end,
    function(r) r[1].inputVoltage = 0 end,
    function(r) r[2].temperature = 96 end,
    function(r) r[2].cooling.temperature = 96 end,
    function(r) r[2].cooling.tripped = true end,
    function(r) r[2].cooling.capacity = 0/0 end,
    function(r) r[2].cooling.powered = nil end,
    function(r) r[2].status = "disabled" end,
    function(r) r[2].inputCurrent = math.huge end,
}) do
    f = fixture(); f.run(); f.mutate = mutate
    assert(not f.step()); assert(f.control.state.phase == "stopped")
end
f = fixture(); assert(f.start()); f.stages[1].jammed = true
for _ = 1, 200 do if not f.step() then break end end
assert(f.control.state.phase == "stopped")
assert(f.control.state.message:find("timed out", 1, true))
for _, command in ipairs(f.commands) do
    assert(command.method ~= "setEnabled" or command.value == false, "enabled before ratios settled")
end
f = fixture(); f.run(); f.missing = 2
assert(not f.step()); assert(not f.stages[1].enabled and not f.stages[3].enabled)
assert(#f.control.state.stopErrors == 1)
-- Stop is latched: later ticks never start the chain again.
f = fixture(); f.run(); assert(f.control.stop("Operator stop"))
local writes = #f.commands
for _ = 1, 10 do assert(f.step()) end
assert(#f.commands == writes)
assert(f.start())
for _ = 1, 60 do local ok, why = f.step(); assert(ok, why) end
assert(f.control.state.phase == "running")
-- Unlimited recovery retries; no fourth-attempt permanent latch.
f = fixture(); f.run()
f.source = 0
for attempt = 1, 6 do
    local ok, why = f.step()
    assert(not ok)
    f.control.fault(why, f.time)
    assert(f.control.state.retries == attempt and f.control.state.retryAt)
    local writesBefore = #f.commands
    for _ = 1, 19 do assert(f.step()) end
    assert(#f.commands == writesBefore, "retried before delay expired")
end
f.source = 264001
for _ = 1, 100 do local ok, why = f.step(); assert(ok, why) end
assert(f.control.state.phase == "running")
-- Thermal reset is deferred until cool and performed only during normal enable.
f = fixture(); f.run(); f.stages[2].temperature = 100; f.stages[2].tripped = true
local ok, why = f.step(); assert(not ok); f.control.fault(why, f.time)
for _ = 1, 20 do
    local pass, errorText = f.step()
    if not pass then f.control.fault(errorText, f.time) end
end
assert(not f.stages[2].enabled and f.stages[2].tripped)
f.stages[2].temperature = 55
for _ = 1, 120 do local pass, errorText = f.step(); assert(pass, errorText) end
assert(f.control.state.phase == "running" and not f.stages[2].tripped)
-- Operator stop cancels an already scheduled retry.
f.control.fault("test", f.time)
f.control.stop("Operator stop")
assert(not f.control.state.retryAt)
local count = #f.commands
for _ = 1, 40 do assert(f.step()) end
assert(#f.commands == count and f.control.state.phase == "stopped")
local c = M.defaults(); c.stages[2].name = c.stages[1].name
assert(not pcall(M.validate, c))
c = M.defaults(); c.stages[3].uncooled = 300
assert(not pcall(M.validate, c))
c = M.defaults(); c.resetTemperature = nil; c.retrySeconds = nil
M.validate(c); assert(c.resetTemperature == 60 and c.retrySeconds == 5)
print("Custom transformer controller: staged startup, feedback, cooling/current limits, faults and shutdown passed")
