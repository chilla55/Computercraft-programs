-- stock-monitor-version: 1.0.3
-- Create Stock Ticker + Item Vault dashboard for CC: Tweaked.
-- Run stock_monitor --configure to choose peripherals again.
local M = {}

local function number(value, label)
    assert(type(value) == "number" and value >= 0 and value < math.huge
        and value == math.floor(value), "Invalid " .. label)
    return value
end

function M.count(items)
    assert(type(items) == "table", "Invalid item list")
    local total, occupied = 0, 0
    for _, item in pairs(items) do
        total = total + number(item.count, "item count")
        if item.count > 0 then occupied = occupied + 1 end
    end
    return total, occupied
end

-- Aggregate variants under their registry item name for stock trends.
function M.items(items, totals)
    totals = totals or {}
    for _, item in pairs(items) do
        assert(type(item.name) == "string", "Missing item name")
        totals[item.name] = (totals[item.name] or 0) + number(item.count, "item count")
    end
    return totals
end

-- Keep the nearest sample at/before the five-minute boundary, plus newer ones.
-- A failed read resets the window rather than turning missing data into losses.
function M.trend(history, items, now)
    if not items then
        history.samples = {}
        return { unavailable = true }
    end
    local samples = history.samples or {}
    history.samples = samples
    if #samples > 0 and now < samples[#samples].time then
        samples = {}; history.samples = samples
    end
    if #samples == 0 or now - samples[#samples].time >= 1 then
        samples[#samples + 1] = { time = now, items = items }
    end
    while #samples > 1 and samples[2].time <= now - 300 do
        table.remove(samples, 1)
    end
    local baseline, minute = samples[1], samples[1]
    for _, sample in ipairs(samples) do
        if sample.time <= now - 60 then minute = sample else break end
    end
    local result = { elapsed = now - baseline.time, minuteElapsed = now - minute.time, changes = {} }
    local names = {}
    for _, counts in ipairs({ baseline.items, minute.items, items }) do
        for name in pairs(counts) do names[name] = true end
    end
    for name in pairs(names) do
        local current = items[name] or 0
        local fiveDelta = current - (baseline.items[name] or 0)
        local minuteDelta = current - (minute.items[name] or 0)
        if fiveDelta ~= 0 or minuteDelta ~= 0 then
            result.changes[#result.changes + 1] = {
                name = name, current = current, five = fiveDelta, minute = minuteDelta,
            }
        end
    end
    table.sort(result.changes, function(a, b)
        local aMagnitude = math.max(math.abs(a.five), math.abs(a.minute))
        local bMagnitude = math.max(math.abs(b.five), math.abs(b.minute))
        if aMagnitude == bMagnitude then return a.name < b.name end
        return aMagnitude > bMagnitude
    end)
    return result
end

local function historyScope(config)
    local names = {}
    for _, name in ipairs(config.vaults) do names[#names + 1] = name end
    table.sort(names)
    return (config.ticker or "vaults") .. "\n" .. table.concat(names, "\n")
end

function M.loadHistory(path, config, now)
    for _, candidate in ipairs({ path, path .. ".bak" }) do
        if fs.exists(candidate) then
            local ok, history = pcall(function()
                assert(fs.getSize(candidate) <= 8 * 1024 * 1024, "History too large")
                local file = assert(fs.open(candidate, "r"))
                local bytes = file.readAll(); file.close()
                local saved = textutils.unserialize(bytes)
                assert(type(saved) == "table" and saved.schema == 1
                    and saved.scope == historyScope(config), "History scope changed")
                assert(type(saved.samples) == "table" and #saved.samples <= 302, "Invalid samples")
                local previous = -math.huge
                for _, sample in ipairs(saved.samples) do
                    assert(type(sample) == "table" and type(sample.time) == "number"
                        and sample.time > previous and sample.time <= now, "Invalid sample time")
                    assert(type(sample.items) == "table", "Invalid history items")
                    for name, count in pairs(sample.items) do
                        assert(type(name) == "string", "Invalid history item")
                        number(count, "history count")
                    end
                    previous = sample.time
                end
                -- Do not count a long offline interval as observed stock history.
                assert(#saved.samples == 0 or now - previous <= 60, "History expired")
                return { samples = saved.samples }
            end)
            if ok then return history end
        end
    end
    return { samples = {} }
end

function M.saveHistory(path, config, history)
    local bytes = textutils.serialize({ schema = 1, scope = historyScope(config),
        samples = history.samples or {} })
    assert(#bytes <= 8 * 1024 * 1024, "History exceeds 8 MiB")
    local temporary, backup = path .. ".tmp", path .. ".bak"
    local file = assert(fs.open(temporary, "w"), "Cannot write stock history")
    file.write(bytes); file.close()
    -- Recover a previously interrupted replacement before rotating the backup.
    if not fs.exists(path) and fs.exists(backup) then fs.move(backup, path) end
    if fs.exists(path) then
        if fs.exists(backup) then fs.delete(backup) end
        fs.move(path, backup)
    end
    local ok, reason = pcall(fs.move, temporary, path)
    if not ok then
        if not fs.exists(path) and fs.exists(backup) then fs.move(backup, path) end
        error(reason, 0)
    end
end

function M.capacity(vault, slots, progress)
    local total = 0
    -- Queue a bounded batch of peripheral reads together instead of waiting a
    -- server tick for every individual slot. Works with nonuniform inventories.
    for first = 1, slots, 32 do
        local calls = {}
        for slot = first, math.min(slots, first + 31) do
            local index = slot
            calls[#calls + 1] = function()
                local limit = number(vault.getItemLimit(index), "slot limit")
                total = total + limit
            end
        end
        if parallel and parallel.waitForAll then parallel.waitForAll(table.unpack(calls))
        else for _, call in ipairs(calls) do call() end end
        if progress then progress(math.min(slots, first + 31), slots) end
    end
    return total
end

function M.sample(config, wrap, cache, progress)
    local result = { current = 0, capacity = 0, slots = 0, occupied = 0, vaultItems = {} }
    local seen = {}
    assert(#config.vaults > 0, "No vaults configured; run --configure")
    for _, name in ipairs(config.vaults) do
        assert(not seen[name], "Duplicate vault: " .. name)
        seen[name] = true
        local vault = assert(wrap(name), "Vault offline: " .. name)
        assert(vault.size and vault.list and vault.getItemLimit,
            "Inventory API missing: " .. name)
        local slots = number(vault.size(), "slot count")
        local saved = cache and cache[name]
        local now = os.epoch and os.epoch("utc") / 1000 or 0
        local capacity
        if saved and saved.slots == slots and now >= saved.time and now - saved.time < 300 then
            capacity = saved.capacity
        else
            capacity = M.capacity(vault, slots, progress and function(done, count)
                progress(name, done, count)
            end)
            if cache then cache[name] = { slots = slots, capacity = capacity, time = now } end
        end
        local items = vault.list()
        local current, occupied = M.count(items)
        M.items(items, result.vaultItems)
        result.current = result.current + current
        result.capacity = result.capacity + capacity
        result.slots = result.slots + slots
        result.occupied = result.occupied + occupied
    end
    result.ratio = result.capacity > 0 and result.current / result.capacity or 0
    if config.ticker then
        local ok, value, items = pcall(function()
            local ticker = assert(wrap(config.ticker), "Ticker offline")
            assert(ticker.stock, "Ticker stock() API missing")
            local stock = ticker.stock()
            return M.count(stock), M.items(stock)
        end)
        if ok then
            result.network, result.trendItems = value, items
        else
            result.networkError = tostring(value)
        end
    else
        result.trendItems = result.vaultItems
    end
    return result
end

function M.format(value)
    local digits = string.format("%.0f", value)
    return digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Do not toggle between scales on each redraw: setTextScale queues resize
-- events, so toggling it causes a self-sustaining refresh/clear loop.
function M.fitMonitor(target)
    if not target.getTextScale or target.getTextScale() ~= 1.0 then
        target.setTextScale(1.0)
    end
end

function M.loading(target, message)
    local w, h = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    target.setCursorPos(1, 1)
    target.write(("READING VAULT STORAGE"):sub(1, w))
    if h >= 3 then
        target.setCursorPos(1, 3)
        target.write(message:sub(1, w))
    end
    if h >= 5 then
        target.setCursorPos(1, 5)
        target.write(("Please wait; Ctrl+T cancels"):sub(1, w))
    end
end

function M.draw(target, data, problem, trendView)
    local w, h = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    local function line(y, text, color)
        if y > h then return end
        target.setCursorPos(1, y)
        target.setTextColor(color or colors.white)
        target.write(text:sub(1, w))
    end
    if w < 26 or h < 10 then
        line(1, "Display too small")
        line(2, "Need 26 x 10 characters")
        return
    end
    if problem or trendView or h < 11 or h >= 15 then
        line(1, "STOCK NETWORK / VAULTS", colors.cyan)
    end
    if problem then
        line(3, "VAULT DATA UNAVAILABLE", colors.red)
        local message = tostring(problem)
        for y = 4, h - 1 do
            line(y, message:sub((y - 4) * w + 1, (y - 3) * w), colors.orange)
        end
        line(h, "Retrying... Q: quit")
        return
    end
    local function changes(top)
        local trend = data.trend
        line(top, "NET CHANGE / 1 MIN + 5 MIN", colors.cyan)
        if not trend or trend.unavailable then
            line(top + 1, "Trend data unavailable", colors.orange)
        elseif trend.elapsed == 0 then
            line(top + 1, "Waiting for next snapshot", colors.lightGray)
        else
            local column = math.max(7, math.min(14, math.floor(w / 4)))
            local nameWidth = w - 2 * column - 2
            local function row(y, name, minute, five, minuteColor, fiveColor)
                line(y, name:sub(1, nameWidth)
                    .. string.rep(" ", math.max(0, nameWidth - #name))
                    .. " " .. string.rep(" ", column - #minute) .. minute
                    .. " " .. string.rep(" ", column - #five) .. five)
                if minuteColor then
                    target.setCursorPos(nameWidth + 2 + column - #minute, y)
                    target.setTextColor(minuteColor); target.write(minute)
                    target.setCursorPos(w - #five + 1, y)
                    target.setTextColor(fiveColor); target.write(five)
                end
            end
            local function duration(seconds, full, label)
                return seconds < full and (math.floor(seconds) .. "s") or label
            end
            row(top + 1, "ITEM", duration(trend.minuteElapsed, 60, "1 min"), duration(trend.elapsed, 300, "5 min"))
            local rows = h - top - 3
            local pages = math.max(1, math.ceil(#trend.changes / rows))
            local page = (data.trendPage or 0) % pages
            local function signed(value)
                if value == 0 then return "0" end
                local sign, magnitude = value > 0 and "+" or "-", math.abs(value)
                local text = sign .. M.format(magnitude)
                if #text <= column then return text end
                for _, unit in ipairs({ {1e3, "k"}, {1e6, "M"}, {1e9, "B"}, {1e12, "T"} }) do
                    if magnitude < unit[1] * 1000 then
                        return sign .. string.format("%.1f%s", math.floor(magnitude / unit[1] * 10) / 10, unit[2])
                    end
                end
                return string.format("%+.0e", value):sub(1, column)
            end
            local function color(value)
                return value > 0 and colors.lime or value < 0 and colors.red or colors.lightGray
            end
            if #trend.changes == 0 then line(top + 2, "No net changes", colors.lightGray) end
            for index = 1, rows do
                local item = trend.changes[page * rows + index]
                if not item then break end
                local name = item.name
                if #name > nameWidth then name = name:gsub("^[^:]+:", "") end
                row(top + 1 + index, name, signed(item.minute), signed(item.five), color(item.minute), color(item.five))
            end
            line(h - 1, string.format("1m:%.0fs 5m:%.0fs | %d/%d", trend.minuteElapsed, trend.elapsed, page + 1, pages), colors.lightGray)
        end
        line(h, "N: " .. (trendView and "summary" or "changes") .. " / Q: quit", colors.lightGray)
    end
    if trendView then
        line(2, "Source: " .. (data.trendSource or "network"), colors.lightGray)
        changes(3)
        return
    end
    -- The 3x2 monitor has fewer rows at the larger text scale. Keep the
    -- essential totals, full-range gauge and both change columns on one screen.
    if h >= 11 and h < 15 then
        local color = data.ratio >= 0.9 and colors.red
            or data.ratio >= 0.75 and colors.orange or colors.lime
        if data.historyError then line(1, "History save failed", colors.orange)
        else line(1, string.format("VAULTS / %.1f%% FULL", data.ratio * 100), color) end
        line(2, "Network: " .. (data.network and M.format(data.network) or "unavailable"))
        line(3, "Items:   " .. M.format(data.current))
        line(4, "Maximum: " .. M.format(data.capacity))
        local filled = math.floor(math.max(0, math.min(1, data.ratio)) * (w - 2))
        line(5, "[" .. string.rep("#", filled) .. string.rep("-", w - 2 - filled) .. "]", color)
        local maximum = M.format(data.capacity)
        line(6, "0" .. string.rep(" ", math.max(1, w - #maximum - 1)) .. maximum)
        changes(7)
        return
    end
    line(2, "Network: " .. (data.network and M.format(data.network) or "unavailable"))
    line(3, "Items:   " .. M.format(data.current))
    line(4, "Maximum: " .. M.format(data.capacity))
    local color = data.ratio >= 0.9 and colors.red
        or data.ratio >= 0.75 and colors.orange or colors.lime
    line(5, string.format("Vault fill: %.1f%%", data.ratio * 100), color)
    local filled = math.floor(math.max(0, math.min(1, data.ratio)) * (w - 2))
    line(6, "[" .. string.rep("#", filled) .. string.rep("-", w - 2 - filled) .. "]", color)
    local maximum = M.format(data.capacity)
    line(7, "0" .. string.rep(" ", math.max(1, w - #maximum - 1)) .. maximum)
    line(8, "Slots used: " .. M.format(data.occupied) .. "/" .. M.format(data.slots))
    line(9, "Max assumes full-size stacks", colors.lightGray)
    if data.current > data.capacity then
        line(10, "Count exceeds capacity; retrying", colors.orange)
    elseif data.historyError then
        line(10, "History save failed", colors.orange)
    elseif data.networkError then
        line(10, "Ticker unavailable; Q: quit", colors.orange)
    else
        line(10, "N: changes / Q: quit", colors.lightGray)
    end
    if h >= 15 then changes(11) end
end

function M.drawConsole(target, data, problem, config, status)
    local w, h = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    local function line(y, text, color)
        if y > h then return end
        target.setCursorPos(1, y)
        target.setTextColor(color or colors.white)
        target.write(text:sub(1, w))
    end
    line(1, "STORAGE CONTROL PANEL", colors.cyan)
    line(3, "Configured vaults: " .. #config.vaults)
    line(4, "Ticker: " .. (config.ticker or "none (vault totals)"))
    if data then
        line(5, "Vault items: " .. M.format(data.current) .. " / " .. M.format(data.capacity))
    elseif problem then
        line(5, "Storage unavailable; retrying", colors.orange)
    end
    line(7, "UPDATER", colors.cyan)
    local message = status or "Start with storage/start.lua --run to enable updates"
    for y = 8, h - 3 do
        line(y, message:sub((y - 8) * w + 1, (y - 7) * w), colors.lightGray)
    end
    line(h - 1, "C: configure vaults/display   U: check updates")
    line(h, "N: monitor changes/summary    Q: quit")
end

local function discover()
    local tickers, vaults, monitors = {}, {}, {}
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        local p = peripheral.wrap(name)
        if p then
            if p.stock then tickers[#tickers + 1] = name end
            if peripheral.hasType(name, "monitor") then monitors[#monitors + 1] = name end
            if p.size and p.list and p.getItemLimit and not p.stock then
                vaults[#vaults + 1] = name
            end
        end
    end
    return tickers, vaults, monitors
end

local function choose(title, names, optional)
    print(title)
    for i, name in ipairs(names) do print(i .. ": " .. name) end
    if optional then print("0: None / computer terminal") end
    while true do
        write("> ")
        local index = tonumber(read())
        if optional and index == 0 then return nil end
        if index and names[index] then return names[index] end
        print("Enter a listed number.")
    end
end

local function configure(path)
    local tickers, inventories, monitors = discover()
    assert(#inventories > 0,
        "No inventories found. Connect vaults with enabled wired modems first.")
    print("Stock monitor setup")
    print("Connect each physical vault ONCE to avoid counting it twice.")
    local config = { interval = 5, vaults = {} }
    config.ticker = choose("Choose the network Stock Ticker:", tickers, true)
    config.monitor = choose("Choose the display:", monitors, true)
    print("Choose ONLY the vaults belonging to this network:")
    for i, name in ipairs(inventories) do print(i .. ": " .. name) end
    print("Enter numbers separated by spaces (e.g. 1 2 3).")
    while #config.vaults == 0 do
        write("> ")
        local selection, seen, valid = {}, {}, true
        for token in read():gmatch("%S+") do
            local name = inventories[tonumber(token) or 0]
            if not name then valid = false; break end
            if not seen[name] then selection[#selection + 1], seen[name] = name, true end
        end
        if valid then config.vaults = selection end
        if #config.vaults == 0 then print("Enter valid vault numbers.") end
    end
    -- Save selections immediately. The dashboard owns the first scan and
    -- reports progress/errors; setup must not silently scan everything twice.
    local file = assert(fs.open(path, "w"), "Cannot write " .. path)
    file.write(textutils.serialize(config))
    file.close()
    return config
end

function M.main(args, services)
    services = services or {}
    local program = services.program or shell.getRunningProgram()
    local path = program .. ".cfg"
    if args[1] == "--list" then
        local names = peripheral.getNames()
        table.sort(names)
        for _, name in ipairs(names) do
            print(name .. ": " .. table.concat(peripheral.getMethods(name) or {}, ", "))
        end
        return
    end
    if args[1] and args[1] ~= "--configure" then
        print("Usage: stock_monitor [--configure | --list]")
        return
    end
    services.configuring = true
    local config
    if args[1] == "--configure" or not fs.exists(path) then
        config = configure(path)
    else
        local file = assert(fs.open(path, "r"))
        config = textutils.unserialize(file.readAll())
        file.close()
    end
    assert(type(config) == "table" and type(config.vaults) == "table",
        "Invalid configuration; run --configure")
    assert(type(config.interval) == "number" and config.interval >= 1
        and config.interval < math.huge, "Refresh interval must be at least 1 second")
    services.configuring = false
    os.queueEvent("stock_monitor_configured")
    local terminal = term.current()
    local historyPath = program .. ".history"
    local history = M.loadHistory(historyPath, config, os.epoch("utc") / 1000)
    local trendView, revision = false, 0
    local capacityCache = {}
    local lastData, lastProblem, displayError
    local scanStatus = "Starting first scan..."
    local function notify() os.queueEvent("stock_monitor_display") end
    local function draw(target)
        if not lastData and not lastProblem then M.loading(target, scanStatus)
        else M.draw(target, lastData, lastProblem, trendView) end
    end
    local function storageTask()
        while true do
            while services.configuring do os.pullEvent("stock_monitor_configured") end
            local generation = revision
            scanStatus = "Reading stock..."; notify()
            local ok, result = pcall(M.sample, config, peripheral.wrap, capacityCache, function(name, done, total)
                if generation == revision then
                    scanStatus = name .. ": " .. done .. "/" .. total .. " slots"
                    notify()
                end
            end)
            if not ok and result == "Terminated" then error(result, 0) end
            -- A configuration change can happen while a peripheral call yields.
            -- Never publish old-scope totals or history into the new selection.
            if generation == revision and not services.configuring then
                local now = os.epoch("utc") / 1000
                local trend = M.trend(history, ok and result.trendItems or nil, now)
                local saved, saveError = pcall(M.saveHistory, historyPath, config, history)
                if not saved and saveError == "Terminated" then error(saveError, 0) end
                if ok then
                    result.historyError = not saved and tostring(saveError) or nil
                    result.trend = trend
                    result.trendSource = config.ticker and "stock network" or "selected vaults"
                    result.trendPage = math.floor(now / 10)
                else
                    capacityCache = {}
                end
                lastData, lastProblem = ok and result or nil, not ok and result or nil
                scanStatus = ok and "Storage scan complete" or "Storage read failed; retrying"
                notify()
                local timer = os.startTimer(config.interval)
                while true do
                    local event, id = os.pullEvent()
                    if (event == "timer" and id == timer) or event == "stock_monitor_rescan" then break end
                end
                os.cancelTimer(timer)
            end
        end
    end
    local function monitorTask()
        while true do
            local target = config.monitor and peripheral.wrap(config.monitor)
            local previousError = displayError
            displayError = nil
            if target then
                local ok, reason = pcall(function()
                    M.fitMonitor(target)
                    draw(target)
                end)
                if not ok then
                    if reason == "Terminated" then error(reason, 0) end
                    displayError = tostring(reason)
                end
            elseif config.monitor then
                displayError = "Monitor disconnected"
            end
            if displayError ~= previousError then os.queueEvent("stock_monitor_status") end
            while true do
                local event, name = os.pullEvent()
                if event == "stock_monitor_display"
                    or (event == "monitor_resize" and name == config.monitor)
                    or ((event == "peripheral" or event == "peripheral_detach") and name == config.monitor) then break end
            end
        end
    end
    local function terminalTask()
        local function render()
            if config.monitor and peripheral.wrap(config.monitor) and not displayError then
                M.drawConsole(terminal, lastData, lastProblem, config, services.updateStatus)
                local w, h = terminal.getSize()
                if h >= 6 then
                    terminal.setCursorPos(1, 6)
                    terminal.write(scanStatus:sub(1, w))
                end
            else
                draw(terminal)
                local w, h = terminal.getSize()
                terminal.setCursorPos(1, h)
                terminal.write(("C: setup U: update N: view Q: quit"):sub(1, w))
            end
        end
        render()
        while true do
            local event, value = os.pullEvent()
            if event == "char" then
                local key = value:lower()
                if key == "q" then return end
                if key == "u" then
                    if services.requestUpdate then services.requestUpdate()
                    else services.updateStatus = "Updates require the launcher: storage/start.lua --run" end
                elseif key == "n" then
                    trendView = not trendView; notify()
                elseif key == "c" then
                    services.configuring = true
                    revision = revision + 1
                    terminal.clear(); terminal.setCursorPos(1, 1)
                    local configured, nextConfig = pcall(configure, path)
                    if not configured and nextConfig == "Terminated" then error(nextConfig, 0) end
                    if configured then
                        config = nextConfig
                        capacityCache = {}
                        history = M.loadHistory(historyPath, config, os.epoch("utc") / 1000)
                        lastData, lastProblem = nil, nil
                    else
                        services.updateStatus = "Configuration failed: " .. tostring(nextConfig)
                    end
                    scanStatus = "Starting scan..."
                    services.configuring = false
                    os.queueEvent("stock_monitor_configured")
                    os.queueEvent("stock_monitor_rescan")
                    notify()
                end
                render()
            elseif event == "peripheral" or event == "peripheral_detach" then
                local storageChanged = value == config.ticker
                for _, name in ipairs(config.vaults) do
                    if value == name then storageChanged = true end
                end
                if storageChanged then
                    capacityCache = {}; revision = revision + 1
                    os.queueEvent("stock_monitor_rescan")
                end
                render()
            elseif event == "stock_monitor_display" or event == "stock_monitor_status"
                or event == "term_resize" then render() end
        end
    end
    -- Each UI owns its own output device. Only the storage task samples and
    -- persists history; monitor/terminal events cannot trigger extra scans.
    parallel.waitForAny(monitorTask, terminalTask, storageTask)
    terminal.setBackgroundColor(colors.black)
    terminal.setTextColor(colors.white)
    terminal.clear()
    terminal.setCursorPos(1, 1)
end

-- Allows the data and drawing functions to be exercised without Minecraft.
if not shell or (...) == "--module" then return M end
M.main({...})
