-- Read-only sensor collection. No network or actuator commands.
local M = {}
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function number(v) return finite(v) end
local function angles(v) return type(v) == "table" and finite(v[1]) and finite(v[2]) end
local function inventory(v) return type(v) == "table" end
local function status(v) return type(v) == "table" and finite(v.throttle) and v.throttle >= 0 and v.throttle <= 1 end
local function coal(items)
    local count = 0
    for _, item in pairs(items) do
        if type(item) == "table" and item.name == "minecraft:coal" and finite(item.count) and item.count >= 0 then
            count = count + item.count
        end
    end
    return count
end
function M.sample(p, c, cache, now, batch)
    local d, errors, jobs, throttles = {}, {}, {}, {}
    local function read(name, method, validate, assign, destinationErrors)
        jobs[#jobs + 1] = function()
            local ok, value = pcall(p.call, name, method)
            if not ok and value == "Terminated" then error(value, 0) end
            local targetErrors = destinationErrors or errors
            if ok and validate(value) then assign(value)
            else targetErrors[name .. "." .. method] = ok and "Invalid return value" or tostring(value) end
        end
    end
    read(c.altitude, "getHeight", number, function(v) d.altitude = v end)
    read(c.velocity, "getVelocity", number, function(v) d.velocity = v end)
    read(c.gimbal, "getAngles", angles, function(v) d.gimbal = {v[1], v[2]} end)
    if c.position then
        read(c.position.name, c.position.method, function(v)
            return type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z) and v.space=="world"
        end, function(v) d.position={x=v.x,y=v.y,z=v.z,dimension=v.dimension} end)
    end
    for i, name in ipairs(c.thrusters) do
        local index = i
        read(name, "getStatus", status, function(v) throttles[index] = v.throttle end)
    end
    if not cache.at or now - cache.at >= c.inventoryInterval then
        cache.engineCoal, cache.reserveCoal, cache.navDistance = nil, nil, nil
        cache.errors = {}
        read(c.engine, "list", inventory, function(v) cache.engineCoal = coal(v) end, cache.errors)
        read(c.barrel, "list", inventory, function(v) cache.reserveCoal = coal(v) end, cache.errors)
        if c.navigation then
            read(c.navigation, "getTargetDistance", number, function(v) cache.navDistance = v end, cache.errors)
        end
        cache.at = now
    end
    if batch then batch(jobs) else for _, job in ipairs(jobs) do job() end end
    for name, err in pairs(cache.errors or {}) do errors[name] = err end
    d.engineCoal, d.reserveCoal, d.navDistance = cache.engineCoal, cache.reserveCoal, cache.navDistance
    local sum, complete = 0, true
    for i = 1, #c.thrusters do
        if throttles[i] == nil then complete = false else sum = sum + throttles[i] end
    end
    if complete and #c.thrusters > 0 then d.throttle = sum / #c.thrusters end
    d.errorCount = 0
    for _ in pairs(errors) do d.errorCount = d.errorCount + 1 end
    d.errors = errors
    return d
end
return M
