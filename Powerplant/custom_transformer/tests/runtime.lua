-- Exercise interruption while a native call is yielding, plus cleanup failures.
local function run(mode)
    local writes, states, clock, reads = {}, {}, 0, 0
    local closeCount, stoppedOnce, startedAgain = 0, false, false
    local env = setmetatable({}, {__index = _G})
    env.shell = {getRunningProgram = function() return "transformer.lua" end}
    env.colors = {black = 1, white = 2}
    env.term = {setBackgroundColor = function() end, setTextColor = function() end,
        clear = function() end, getSize = function() return 51, 19 end,
        setCursorPos = function() end, write = function() end}
    env.print = function() end
    env.os = {epoch = function() return clock end,
        pullEvent = function(filter) return coroutine.yield(filter) end}
    env.sleep = function() env.os.pullEvent("timer") end
    local function parallelRun(all, ...)
        local threads, filters, done = {}, {}, {}
        local function resume(i, ...)
            local ok, filter = coroutine.resume(threads[i], ...)
            assert(ok, filter); filters[i] = filter
            if coroutine.status(threads[i]) == "dead" then done[i] = true end
        end
        local functions = {...}
        for i, fn in ipairs(functions) do threads[i] = coroutine.create(fn); resume(i) end
        while true do
            local completed = 0
            for i in ipairs(threads) do
                if done[i] then
                    if not all then return i end
                    completed = completed + 1
                end
            end
            if completed == #threads then return end
            local event = {env.os.pullEvent()}
            for i in ipairs(threads) do
                if not done[i] and (not filters[i] or filters[i] == event[1]) then
                    resume(i, table.unpack(event))
                end
            end
        end
    end
    env.parallel = {
        waitForAny = function(...) return parallelRun(false, ...) end,
        waitForAll = function(...) return parallelRun(true, ...) end,
    }
    local M = assert(loadfile("Powerplant/custom_transformer/controller.lua", "t", env))("--module")
    local c = M.defaults()
    env.fs = {exists = function() return true end,
        open = function() return {readAll = function() return "config" end,
            close = function() closeCount = closeCount + 1 end} end}
    env.textutils = {unserialize = function() return c end}
    for i = 1, 3 do states[i] = {enabled = false, ratio = 0.01} end
    env.peripheral = {wrap = function() return setmetatable({}, {__index = function() return function() end end}) end}
    M.adapter = function() return {
        call = function(name, method, value)
            local i = tonumber(name:match("_(%d+)$")) + 1
            env.os.pullEvent("native")
            if mode == "failed_stop" and method == "setEnabled" and value == false and reads > 2 and i == 2 then
                error("injected shutdown failure")
            end
            writes[#writes + 1] = {i = i, method = method, value = value}
            if method == "setEnabled" then states[i].enabled = value
            elseif method == "setRatio" then states[i].ratio = value end
        end,
        read = function()
            reads = reads + 1
            env.os.pullEvent("native")
            if mode == "terminate" and reads == 3 then error("Terminated", 0) end
            local out, voltage = {}, (mode == "retry" and reads >= 3 and reads <= 8) and 0 or 264001
            for i, s in ipairs(states) do
                local r = {inputVoltage = voltage, ratio = s.ratio, inputCurrent = 0,
                    outputCurrent = 0, temperature = 25, status = s.enabled and "running" or "disabled",
                    cooling = {installed = true, powered = false, operating = false, blocked = false,
                        airflow = 0, speed = 0, capacity = c.stages[i].uncooled, tripped = false,
                        slots = 1, fans = 1, workingFans = 0, poweredFans = 0, blockedFans = 0, temperature = 25}}
                voltage = s.enabled and voltage * s.ratio or 0
                r.outputVoltage = voltage; out[i] = r
            end
            return out
        end,
    } end
    local root = coroutine.create(function() M.main({"run"}) end)
    local ok, filter = coroutine.resume(root)
    assert(ok, filter)
    local injectedQuit = false
    for step = 1, 2000 do
        if coroutine.status(root) == "dead" then break end
        clock = clock + 50
        local event = {filter or (step % 2 == 0 and "timer" or "native")}
        if not filter and reads >= 3 and not injectedQuit and (mode ~= "retry" or reads > 12) then
            if mode == "restart" and not stoppedOnce then
                event = {"char", "x"}; stoppedOnce = true
            elseif mode == "restart" and stoppedOnce and not startedAgain and not states[1].enabled then
                event = {"char", "s"}; startedAgain = true
            elseif mode ~= "restart" or startedAgain and reads > 7 then
                event = {"char", "q"}; injectedQuit = true
            end
        end
        ok, filter = coroutine.resume(root, table.unpack(event))
        if not ok then
            assert(mode == "terminate" and filter == "Terminated", filter)
            break
        end
    end
    assert(coroutine.status(root) == "dead", "Runtime stalled: " .. mode)
    assert(closeCount == 1)
    assert(not states[1].enabled and not states[3].enabled)
    if mode ~= "failed_stop" then assert(not states[2].enabled) end
    if mode == "restart" then assert(stoppedOnce and startedAgain) end
    if mode == "retry" then assert(reads > 12, "automatic retries failed to recover from source loss") end
    return writes
end
for _, mode in ipairs({"quit", "restart", "terminate", "failed_stop", "retry"}) do run(mode) end
print("Custom transformer runtime: quit during native calls, stop/restart, termination and failed shutdown passed")
