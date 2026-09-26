-- stock-monitor-version: 1.0.0
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
    local baseline = samples[1]
    local elapsed = now - baseline.time
    local result = { elapsed = elapsed, remaining = math.max(0, 300 - elapsed), losses = {} }
    if elapsed < 300 then return result end
    for name, count in pairs(baseline.items) do
        local current = items[name] or 0
        if current < count then
            result.losses[#result.losses + 1] = { name = name, current = current, loss = count - current }
        end
    end
    table.sort(result.losses, function(a, b)
        if a.loss == b.loss then return a.name < b.name end
        return a.loss > b.loss
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

function M.sample(config, wrap)
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
        local capacity = 0
        for slot = 1, slots do
            capacity = capacity + number(vault.getItemLimit(slot), "slot limit")
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

-- Keep totals and at least five loss rows visible together. A 3x2 monitor
-- uses the compact scale; larger monitors can use more readable text.
function M.fitMonitor(target)
    target.setTextScale(1)
    local w, h = target.getSize()
    if w < 38 or h < 18 then target.setTextScale(0.5) end
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
    line(1, "STOCK NETWORK / VAULTS", colors.cyan)
    if problem then
        line(3, "VAULT DATA UNAVAILABLE", colors.red)
        local message = tostring(problem)
        for y = 4, h - 1 do
            line(y, message:sub((y - 4) * w + 1, (y - 3) * w), colors.orange)
        end
        line(h, "Retrying... Q: quit")
        return
    end
    local function losses(top)
        local trend = data.trend
        line(top, "NET LOSSES / LAST 5 MIN", colors.cyan)
        if not trend or trend.unavailable then
            line(top + 1, "Trend data unavailable", colors.orange)
        elseif trend.remaining > 0 then
            line(top + 1, "Collecting: " .. math.ceil(trend.remaining) .. "s left", colors.lightGray)
        elseif #trend.losses == 0 then
            line(top + 1, "No items decreasing", colors.lime)
        else
            local rows = h - top - 2
            local pages = math.ceil(#trend.losses / rows)
            local page = (data.trendPage or 0) % pages
            for row = 1, rows do
                local item = trend.losses[page * rows + row]
                if not item then break end
                local amount = " -" .. M.format(item.loss)
                local name = item.name
                if #name + #amount > w then name = name:gsub("^[^:]+:", "") end
                name = name:sub(1, math.max(1, w - #amount - 1))
                line(top + row, name .. string.rep(" ", math.max(1, w - #name - #amount)) .. amount, colors.orange)
            end
            line(h - 1, string.format("Page %d/%d | window %.0fs", page + 1, pages, trend.elapsed), colors.lightGray)
        end
        line(h, "N: " .. (trendView and "summary" or "losses") .. " / Q: quit", colors.lightGray)
    end
    if trendView then
        line(2, "Source: " .. (data.trendSource or "network"), colors.lightGray)
        losses(3)
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
        line(10, "N: losses / Q: quit", colors.lightGray)
    end
    if h >= 14 then losses(11) end
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
    line(h, "N: monitor losses/summary    Q: quit")
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
    -- Validate before saving; no incomplete totals are accepted.
    M.sample(config, peripheral.wrap)
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
    local trendView = false
    local lastData, lastProblem, externalDisplay
    local function console()
        if externalDisplay then
            M.drawConsole(terminal, lastData, lastProblem, config, services.updateStatus)
        end
    end
    local function refresh()
        local ok, result = pcall(M.sample, config, peripheral.wrap)
        if not ok and result == "Terminated" then error(result, 0) end
        local now = os.epoch("utc") / 1000
        local trend = M.trend(history, ok and result.trendItems or nil, now)
        local saved, saveError = pcall(M.saveHistory, historyPath, config, history)
        if not saved and saveError == "Terminated" then error(saveError, 0) end
        if ok then
            result.historyError = not saved and tostring(saveError) or nil
            result.trend = trend
            result.trendSource = config.ticker and "stock network" or "selected vaults"
            result.trendPage = math.floor(now / 10)
        end
        local target = config.monitor and peripheral.wrap(config.monitor) or terminal
        if not target then target = terminal end
        local drawn = pcall(function()
            if target ~= terminal then M.fitMonitor(target) end
            M.draw(target, ok and result or nil, not ok and result or nil, trendView)
        end)
        externalDisplay = drawn and target ~= terminal
        lastData, lastProblem = ok and result or nil, not ok and result or nil
        if not drawn then M.draw(terminal, nil, "Monitor disconnected; retrying") end
        console()
    end
    refresh()
    local timer = os.startTimer(config.interval)
    while true do
        local event, value = os.pullEvent()
        if event == "char" and value:lower() == "q" then break end
        if event == "stock_monitor_status" then console() end
        if event == "char" and value:lower() == "u" then
            if services.requestUpdate then services.requestUpdate()
            else services.updateStatus = "Updates require the launcher: storage/start.lua --run" end
            console()
        end
        if event == "char" and value:lower() == "c" then
            services.configuring = true
            terminal.clear(); terminal.setCursorPos(1, 1)
            local configured, nextConfig = pcall(configure, path)
            services.configuring = false
            os.queueEvent("stock_monitor_configured")
            if not configured and nextConfig == "Terminated" then error(nextConfig, 0) end
            if configured then
                config = nextConfig
                history = M.loadHistory(historyPath, config, os.epoch("utc") / 1000)
            else
                services.updateStatus = "Configuration failed: " .. tostring(nextConfig)
            end
            os.cancelTimer(timer)
            refresh()
            timer = os.startTimer(config.interval)
        end
        if event == "char" and value:lower() == "n" then trendView = not trendView end
        if (event == "char" and value:lower() == "n") or (event == "timer" and value == timer) or event == "peripheral"
            or event == "peripheral_detach" or event == "monitor_resize"
            or event == "term_resize" then
            os.cancelTimer(timer)
            refresh()
            timer = os.startTimer(config.interval)
        end
    end
    terminal.setBackgroundColor(colors.black)
    terminal.setTextColor(colors.white)
    terminal.clear()
    terminal.setCursorPos(1, 1)
end

-- Allows the data and drawing functions to be exercised without Minecraft.
if not shell or (...) == "--module" then return M end
M.main({...})
