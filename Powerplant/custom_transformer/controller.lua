-- Custom series transformer controller v1.0.1 (CC: Tweaked).
-- Run: controller.lua run | configure | status
local M = { version = "1.0.1" }
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function clamp(n, low, high) return math.max(low, math.min(high, n)) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, entry in pairs(value) do out[key] = copy(entry) end; return out
end
function M.defaults()
    return { schema = 1, target = 240, nominalInput = 264001, minimumInput = 132000,
        maximumInput = 316802, minimumRatio = 0.01, maximumRatio = 1,
        finalRatioReserve = 1.1,
        accuracy = 2, overvoltage = 264, tripTemperature = 95,
        resetTemperature = 60, retrySeconds = 5,
        timeout = 45, coolingSamples = 3, stableSamples = 3, pollSeconds = 0.25,
        stages = {
            { name = "powergrid_addon_variac_0", uncooled = 10, cooled = 40 },
            { name = "powergrid_addon_variac_1", uncooled = 10, cooled = 40 },
            { name = "powergrid_addon_variac_2", uncooled = 40, cooled = 200 },
        } }
end
function M.validate(c)
    assert(type(c) == "table" and c.schema == 1, "Invalid configuration schema")
    -- Existing 1.0.0 configurations acquire the new recovery settings.
    if c.resetTemperature == nil then c.resetTemperature = 60 end
    if c.retrySeconds == nil then c.retrySeconds = 5 end
    for _, key in ipairs({"target", "nominalInput", "minimumInput", "maximumInput",
        "minimumRatio", "maximumRatio", "finalRatioReserve", "accuracy", "overvoltage", "tripTemperature",
        "timeout", "coolingSamples", "stableSamples", "pollSeconds", "resetTemperature", "retrySeconds"}) do
        assert(finite(c[key]) and c[key] > 0, "Invalid configuration: " .. key)
    end
    assert(c.minimumRatio < c.maximumRatio and c.maximumRatio <= 1, "Require step-down ratios: 0 < minimum < maximum <= 1")
    assert(c.finalRatioReserve > 1, "Final ratio reserve must exceed 1")
    assert(c.minimumInput < c.nominalInput and c.nominalInput < c.maximumInput, "Invalid source voltage range")
    assert(c.accuracy < c.target and c.overvoltage > c.target + c.accuracy, "Invalid output voltage limits")
    assert(c.coolingSamples % 1 == 0 and c.stableSamples % 1 == 0, "Sample counts must be integers")
    assert(c.pollSeconds >= 0.05 and c.timeout >= 1, "Invalid timing")
    assert(c.resetTemperature < c.tripTemperature and c.retrySeconds >= 1, "Invalid recovery settings")
    assert(type(c.stages) == "table" and #c.stages == 3, "Configure exactly three series stages")
    local seen = {}
    for _, stage in ipairs(c.stages) do
        assert(type(stage.name) == "string" and #stage.name > 0 and not seen[stage.name], "Invalid/duplicate peripheral name")
        seen[stage.name] = true
        assert(finite(stage.uncooled) and finite(stage.cooled) and stage.uncooled > 0
            and stage.cooled >= stage.uncooled, "Invalid manual winding ratings: " .. stage.name)
    end
    return c
end

-- Put the largest reduction on the high-current final cabinet. Use its minimum
-- ratio at the maximum configured source voltage, with correction headroom.
-- The smaller upstream stages split only the remaining reduction equally.
function M.plan(c, source)
    assert(finite(source) and source >= c.minimumInput and source <= c.maximumInput,
        "Source voltage outside configured range")
    local finalAtMaximum = c.minimumRatio * c.finalRatioReserve
    local upstream = clamp(math.sqrt(c.target / (c.maximumInput * finalAtMaximum)),
        c.minimumRatio, c.maximumRatio)
    local final = c.target / (source * upstream * upstream)
    assert(upstream >= c.minimumRatio and upstream <= c.maximumRatio
        and final >= c.minimumRatio and final <= c.maximumRatio,
        "Requested reduction cannot fit configured ratio range")
    assert(c.stages[3].cooled >= math.max(c.stages[1].cooled, c.stages[2].cooled),
        "Final cabinet must have the largest cooled winding rating for this plan")
    local out = {ratios = {upstream, upstream, final}, volts = {}, coldAmps = math.huge, cooledAmps = math.huge}
    local voltage = source
    for i = 1, 3 do voltage = voltage * out.ratios[i]; out.volts[i] = voltage end
    local downstream = 1
    for i = 3, 1, -1 do
        out.coldAmps = math.min(out.coldAmps, c.stages[i].uncooled / downstream)
        out.cooledAmps = math.min(out.cooledAmps, c.stages[i].cooled / downstream)
        downstream = downstream * out.ratios[i]
    end
    return out
end

-- Adapter reads return all three transformer snapshots. There are no native
-- software current setters for these transformers: exceeding a limit trips.
function M.new(config, io)
    local c = copy(M.validate(config))
    local s = { phase = "stopped", enabled = 0, cool = {0, 0, 0}, limits = {},
        commanded = {}, stable = 0, message = "Stopped", config = c }
    local api = { state = s }
    local function set(i, method, value) io.call(c.stages[i].name, method, value) end
    function api.stop(message)
        s.phase, s.enabled, s.message = "stopped", 0, message or "Stopped"
        s.retryAt = nil
        s.cool, s.limits = {0, 0, 0}, {}
        local errors = {}
        -- Try every stage even when one has disappeared or rejects a command.
        for i = 3, 1, -1 do
            local ok, why = pcall(set, i, "setEnabled", false)
            if not ok then errors[#errors + 1] = c.stages[i].name .. ": " .. tostring(why) end
        end
        s.stopErrors = errors
        return #errors == 0, table.concat(errors, " | ")
    end
    function api.fault(message, now)
        api.stop("FAULT: " .. tostring(message))
        s.retries = (s.retries or 0) + 1
        s.retryAt = now + c.retrySeconds
    end
    local function limit(i, reading)
        local cooling, stage = reading.cooling, c.stages[i]
        local full = cooling.installed == true and cooling.powered == true
            and cooling.operating == true and cooling.blocked == false
            and cooling.airflow >= 0.999 and cooling.speed >= 0.999
            and cooling.slots >= 1 and cooling.slots % 1 == 0
            and cooling.fans >= cooling.slots and cooling.workingFans >= cooling.slots
            and cooling.poweredFans >= cooling.slots and cooling.blockedFans == 0
        -- Fans can receive input power while a winding is disabled. Count that
        -- measured cooling during preset/startup too, not just after enable.
        if reading.inputVoltage > 1 and full then s.cool[i] = s.cool[i] + 1 else s.cool[i] = 0 end
        local rating = s.cool[i] >= c.coolingSamples and stage.cooled or stage.uncooled
        return math.min(rating, cooling.capacity)
    end
    local function read()
        local readings = io.read(c.stages)
        assert(type(readings) == "table" and #readings == 3, "Incomplete telemetry")
        for i, r in ipairs(readings) do
            local prefix = c.stages[i].name .. ": "
            assert(type(r) == "table" and type(r.status) == "string", prefix .. "invalid status")
            for _, key in ipairs({"inputVoltage", "outputVoltage", "inputCurrent", "outputCurrent", "ratio", "temperature"}) do
                assert(finite(r[key]), prefix .. "invalid " .. key)
            end
            assert(r.ratio > 0, prefix .. "invalid actual ratio")
            local cooling = r.cooling
            assert(type(cooling) == "table" and type(cooling.tripped) == "boolean", prefix .. "invalid cooling/trip telemetry")
            for _, key in ipairs({"capacity", "airflow", "speed", "slots", "fans", "workingFans", "poweredFans", "blockedFans", "temperature"}) do
                assert(finite(cooling[key]), prefix .. "invalid cooling " .. key)
            end
            for _, key in ipairs({"installed", "powered", "operating", "blocked"}) do
                assert(type(cooling[key]) == "boolean", prefix .. "invalid cooling " .. key)
            end
            assert(cooling.capacity >= 0 and cooling.airflow >= 0 and cooling.airflow <= 1
                and cooling.speed >= 0 and cooling.speed <= 1, prefix .. "invalid cooling capacity/airflow")
            local nativeTrip = cooling.tripped or r.status == "thermal_trip"
            -- A disabled, cool cabinet can be reset by its normal sequential
            -- enable after preset verification. Never pulse-enable to reset.
            assert(not nativeTrip or (i > s.enabled
                and math.max(r.temperature, cooling.temperature) < c.resetTemperature),
                prefix .. "native thermal trip; waiting to cool below " .. c.resetTemperature .. " C")
            assert(math.max(r.temperature, cooling.temperature) < c.tripTemperature, prefix .. "temperature limit")
            s.limits[i] = limit(i, r)
            assert(math.abs(r.inputCurrent) <= s.limits[i] + 1e-6, prefix .. "input current exceeds " .. s.limits[i] .. " A")
            assert(math.abs(r.outputCurrent) <= s.limits[i] + 1e-6, prefix .. "output current exceeds " .. s.limits[i] .. " A")
            assert(r.status ~= "input_overvoltage", prefix .. "native winding overvoltage")
            if i <= s.enabled then
                local healthy = {running = true, thermal_derating = true, airflow_blocked = true,
                    fan_unpowered = true, passive_or_spinning_up = true}
                assert(healthy[r.status], prefix .. "unexpected status: " .. r.status)
                assert(s.limits[i] > 0, prefix .. "no winding capacity")
            end
        end
        s.readings = readings
        assert(readings[3].outputVoltage >= -c.accuracy, "Final output polarity is reversed")
        assert(math.abs(readings[3].outputVoltage) <= c.overvoltage, "Final output overvoltage")
        local source = readings[1].inputVoltage
        assert(source >= c.minimumInput and source <= c.maximumInput, "Source voltage outside configured range")
        return readings
    end
    local function ratio(i, value)
        assert(finite(value) and value >= c.minimumRatio and value <= c.maximumRatio,
            "Target ratio unreachable at stage " .. i)
        if not s.commanded[i] or math.abs(s.commanded[i] - value) > 1e-7 then
            set(i, "setRatio", value); s.commanded[i] = value
        end
    end
    function api.start(now)
        local stopped, why = api.stop("Preparing ratios")
        assert(stopped, "Could not disable all stages: " .. why)
        s.commanded, s.stable, s.trim = {}, 0, 0
        local readings = read()
        for i, r in ipairs(readings) do
            assert(math.max(r.temperature, r.cooling.temperature) < c.resetTemperature,
                c.stages[i].name .. ": waiting to cool below " .. c.resetTemperature .. " C before restart")
        end
        s.plan = M.plan(c, readings[1].inputVoltage)
        -- Disable all outputs before requesting ratios. Actual ratios ramp
        -- asynchronously, including while disabled; verify before any enable.
        for i = 1, 3 do ratio(i, s.plan.ratios[i]) end
        s.phase, s.deadline = "preset", now + c.timeout
        s.message = "Waiting for disabled stages to reach preset ratios"
    end
    local function settled(readings, count)
        for i = 1, count do
            if math.abs(readings[i].ratio - s.commanded[i]) > 1e-5 then return false end
        end
        return true
    end
    local function regulate(r)
        local last = r[3]
        assert(last.inputVoltage > 1, "Stage 3 input lost")
        local base = c.target / last.inputVoltage
        assert(base >= c.minimumRatio and base <= c.maximumRatio, "Final target ratio is unreachable")
        -- Bounded voltage correction for small winding losses. Do not keep
        -- increasing ratio into a heavily overloaded/drooping load.
        if settled(r, 3) and last.outputVoltage > c.target * 0.8 then
            s.trim = clamp(s.trim + 0.25 * (c.target - last.outputVoltage) / last.inputVoltage,
                -base * 0.05, base * 0.05)
        end
        ratio(3, clamp(base + s.trim, c.minimumRatio, c.maximumRatio))
    end
    function api.tick(now)
        if s.phase == "stopped" then
            if s.retryAt and now >= s.retryAt then api.start(now) end
            return
        end
        local r = read()
        assert(now <= s.deadline or s.phase == "running", "Startup/regulation timed out")
        if s.phase == "preset" then
            local disabled = true
            for i = 1, 3 do
                if r[i].status ~= "disabled" and r[i].status ~= "thermal_trip" then disabled = false end
            end
            if disabled and settled(r, 3) then
                set(1, "setEnabled", true); s.enabled, s.phase, s.stable = 1, "starting", 0
                s.deadline = now + c.timeout
                s.message = "Starting stage 1 / 3"
            end
        elseif s.phase == "starting" then
            local i = s.enabled
            local expected = r[i].inputVoltage * s.commanded[i]
            local good = r[i].inputVoltage > 1 and r[i].outputVoltage > 1
                and math.abs(r[i].outputVoltage - expected) <= math.max(c.accuracy, expected * 0.02)
                and settled(r, i)
            if i == 2 and good then
                -- Stage 3 remains disabled while its ratio is corrected using
                -- the measured voltage actually reaching its input.
                local input = r[3].inputVoltage
                if input > 1 then
                    ratio(3, c.target / input)
                    good = math.abs(r[3].ratio - s.commanded[3]) <= 1e-5
                else good = false end
            end
            if i == 3 then
                regulate(r)
                good = r[3].inputVoltage > 1 and settled(r, 3)
                    and math.abs(r[3].outputVoltage - c.target) <= c.accuracy
            end
            s.stable = good and s.stable + 1 or 0
            if s.stable >= c.stableSamples then
                if i < 3 then
                    set(i + 1, "setEnabled", true); s.enabled = i + 1
                    s.message = "Starting stage " .. s.enabled .. " / 3"
                else s.phase, s.message = "running", "Regulating final output" end
                s.stable, s.deadline = 0, now + c.timeout
            end
        elseif s.phase == "running" then
            local last = r[3]
            assert(settled(r, 2), "Upstream ratio changed unexpectedly")
            regulate(r)
            if math.abs(last.outputVoltage - c.target) <= c.accuracy then s.deadline = now + c.timeout end
            assert(now <= s.deadline, "Cannot maintain target voltage")
        end
    end
    return api
end

local methods = {status = "getStatus", cooling = "getCoolingStatus", ratio = "getRatio",
    inputVoltage = "getInputVoltage", outputVoltage = "getOutputVoltage",
    inputCurrent = "getInputCurrent", outputCurrent = "getOutputCurrent", temperature = "getTemperature"}
function M.adapter()
    return {
        call = function(name, method, value)
            assert(peripheral.isPresent(name), "Peripheral unavailable: " .. name)
            return peripheral.call(name, method, value)
        end,
        read = function(stages)
            local out, tasks = {}, {}
            for i, stage in ipairs(stages) do
                local reading, name = {}, stage.name
                out[i] = reading
                for key, method in pairs(methods) do
                    local field, operation = key, method
                    tasks[#tasks + 1] = function() reading[field] = peripheral.call(name, operation) end
                end
            end
            parallel.waitForAll(table.unpack(tasks))
            return out
        end,
    }
end

function M.main(args)
    local command = args[1] or "run"
    assert(#args <= 1 and (command == "run" or command == "configure" or command == "status"),
        "Usage: controller.lua [run|configure|status]")
    local path = shell.getRunningProgram() .. ".cfg"
    local c
    if fs.exists(path) then
        local file = assert(fs.open(path, "r")); local text = file.readAll(); file.close()
        c = assert(textutils.unserialize(text), "Invalid config: " .. path)
    else
        c = M.defaults()
        local file = assert(fs.open(path, "w")); file.write(textutils.serialize(c)); file.close()
    end
    M.validate(c)
    if command == "configure" then
        print("Manual configuration: " .. path)
        print("Edit names, winding ratings and voltage/timing limits, then run again.")
        shell.run("edit", path)
        return
    end
    local io = M.adapter()
    if command == "status" then
        print(textutils.serialize(io.read(c.stages)))
        return
    end
    -- Verify the API surface before taking control. A missing peripheral still
    -- gets cleanup attempts on every other configured transformer.
    local control = M.new(c, io)
    local quitting, startRequested = false, true
    local function now() return os.epoch("utc") / 1000 end
    local function draw()
        local s = control.state
        term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
        local w, h = term.getSize()
        local y = 1
        local function line(text)
            if y <= h then term.setCursorPos(1, y); term.write(text:sub(1, w)); y = y + 1 end
        end
        line("CUSTOM TRANSFORMER v" .. M.version .. " / " .. s.phase)
        line("Target " .. c.target .. " V | series 0 -> 1 -> 2")
        line(s.message)
        if s.retryAt then
            line(string.format("Auto retry %d in %.0fs", s.retries, math.max(0, s.retryAt - now())))
        end
        if s.plan then
            line(string.format("Plan %.5f / %.5f / %.5f", table.unpack(s.plan.ratios)))
        end
        for i, stage in ipairs(c.stages) do
            local r = s.readings and s.readings[i]
            line("Stage " .. i .. " " .. stage.name)
            if r then
                line(string.format(" %.1f -> %.1f V | ratio %.6f", r.inputVoltage, r.outputVoltage, r.ratio))
                line(string.format(" %.3f / %.3f A | limit %.1f A", r.inputCurrent, r.outputCurrent, s.limits[i] or stage.uncooled))
                line(string.format(" %.1f C | %s | %s", r.temperature,
                    s.cool[i] >= c.coolingSamples and "cooled" or "uncooled", r.status))
            end
        end
        if s.stopErrors and #s.stopErrors > 0 then line("SHUTDOWN ERROR: " .. table.concat(s.stopErrors, " | ")) end
        term.setCursorPos(1, h)
        term.write(("S: start  X: stop  Q: quit"):sub(1, w))
    end
    local function hardware()
        while not quitting do
            local ok, why = pcall(function()
                if startRequested then
                    startRequested = false
                    for _, stage in ipairs(c.stages) do
                        for _, method in ipairs({"setRatio", "setEnabled", "getCoolingStatus", "getStatus",
                            "getInputVoltage", "getOutputVoltage", "getInputCurrent", "getOutputCurrent", "getRatio", "getTemperature"}) do
                            local p = assert(peripheral.wrap(stage.name), "Missing peripheral: " .. stage.name)
                            assert(type(p[method]) == "function", stage.name .. " missing " .. method)
                        end
                    end
                    control.start(now())
                end
                control.tick(now())
            end)
            if not ok then
                if why == "Terminated" then error(why, 0) end
                control.fault(why, now())
            end
            draw()
            sleep(c.pollSeconds)
        end
    end
    local function input()
        while true do
            local event, value = os.pullEvent()
            if event == "char" then
                value = value:lower()
                if value == "q" or value == "x" then
                    -- Return ends the hardware task before cleanup; it cannot
                    -- resume and re-enable a stage after a user stop.
                    quitting = value == "q"
                    return
                elseif value == "s" and control.state.phase == "stopped" then startRequested = true end
            elseif event == "term_resize" then draw() end
        end
    end
    local success, failure = pcall(function()
        repeat
            parallel.waitForAny(hardware, input)
            local stopped = control.stop(quitting and "Quit" or "Operator stop")
            if not stopped then quitting = true end
            startRequested = false
            draw()
        until quitting
    end)
    local stopped, stopError = control.stop(success and control.state.message or tostring(failure))
    term.setCursorPos(1, 1); term.clear()
    print(control.state.message)
    if not stopped then print("Could not disable all stages: " .. stopError) end
    if not success then error(failure, 0) end
end
if not shell or (...) == "--module" then return M end
M.main({...})
