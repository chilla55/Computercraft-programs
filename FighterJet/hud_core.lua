-- Pure display/protocol helpers; no peripheral or actuator calls.
local M = {}
function M.finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local kinds = {
    player = { symbol = "P", color = "9", priority = 5 },
    hostile = { symbol = "H", color = "e", priority = 4 },
    passive = { symbol = "A", color = "5", priority = 2 },
    structure = { symbol = "S", color = "a", priority = 3 },
    unknown = { symbol = "?", color = "4", priority = 1 },
}
function M.classify(track, overrides)
    local custom = type(track.entityType) == "string" and overrides[track.entityType]
    if kinds[custom] then return custom end
    local category = type(track.category) == "string" and track.category:upper() or ""
    if category == "PLAYER" or track.entityType == "entity.minecraft.player" then return "player" end
    if category == "HOSTILE" then return "hostile" end
    if category == "ANIMAL" or category == "PASSIVE" then return "passive" end
    if category == "STRUCTURE" then return "structure" end
    return "unknown"
end
function M.frame(width, height)
    local f = { width = width, height = height, chars = {}, colors = {}, backgrounds = {} }
    for y = 1, height do
        f.chars[y], f.colors[y], f.backgrounds[y] = {}, {}, {}
        for x = 1, width do f.chars[y][x], f.colors[y][x], f.backgrounds[y][x] = " ", "0", "f" end
    end
    function f.text(x, y, value, color)
        if y < 1 or y > height then return end
        local s = tostring(value)
        for i = 1, #s do
            local xx = x + i - 1
            if xx >= 1 and xx <= width then
                f.chars[y][xx], f.colors[y][xx] = s:sub(i, i), color or "0"
            end
        end
    end
    function f.rows()
        local rows = {}
        for y = 1, height do
            rows[y] = { table.concat(f.chars[y]), table.concat(f.colors[y]), table.concat(f.backgrounds[y]) }
        end
        return rows
    end
    return f
end
function M.number(v, places)
    if not M.finite(v) then return "--" end
    return string.format("%." .. (places or 0) .. "f", v)
end
function M.flight(width, height, packet, fresh)
    local f = M.frame(width, height)
    local d = fresh and packet and packet.data or {}
    f.text(1, 1, fresh and "FLIGHT LIVE" or "FLIGHT NO DATA", fresh and "5" or "e")
    f.text(1, 2, "READ ONLY", "4")
    f.text(1, 3, "ALT " .. M.number(d.altitude, 1))
    f.text(1, 4, "V(raw) " .. M.number(d.velocity, 1))
    local angles = type(d.gimbal) == "table" and d.gimbal or {}
    f.text(1, 5, "GX " .. M.number(angles[1], 1) .. " GZ " .. M.number(angles[2], 1))
    f.text(1, 6, "Tavg " .. M.number(M.finite(d.throttle) and d.throttle * 100 or nil) .. "%")
    f.text(1, 7, "ENG " .. M.number(d.engineCoal) .. " RES " .. M.number(d.reserveCoal))
    f.text(1, 8, "ERR " .. M.number(d.errorCount), d.errorCount == 0 and "5" or "e")
    if height >= 10 then f.text(1, 9, "NAV " .. (M.finite(d.navDistance) and d.navDistance >= 0 and M.number(d.navDistance) or "NONE")) end
    f.text(1, height, "PAGE", "b")
    return f.rows()
end
function M.radar(width, height, snapshot, range, filter, overrides, sensorsFresh)
    local f = M.frame(width, height)
    f.text(1, 1, "RAD N " .. range, "0")
    f.text(width, 1, sensorsFresh and "+" or "!", sensorsFresh and "5" or "e")
    local cx, cy = math.floor((width + 1) / 2), math.floor((height + 1) / 2)
    local rx, ry = math.max(1, (width - 3) / 2), math.max(1, (height - 5) / 2)
    for y = 2, height - 2 do
        for x = 1, width do
            local r = ((x - cx) / rx)^2 + ((y - cy) / ry)^2
            if math.abs(r - 1) < 0.28 or math.abs(r - 0.25) < 0.1 then f.text(x, y, ".", "7") end
        end
    end
    local origin = snapshot and snapshot.origin
    local valid = type(origin) == "table" and M.finite(origin.x) and M.finite(origin.z)
        and type(snapshot.tracks) == "table"
    local cells, visible, processed = {}, 0, 0
    if valid then
        for _, track in pairs(snapshot.tracks) do
            processed = processed + 1
            if processed > 2048 then break end
            if type(track) == "table" and type(track.position) == "table" then
                local p = track.position
                if M.finite(p.x) and M.finite(p.z) then
                    local dx, dz = p.x - origin.x, p.z - origin.z
                    local distance = dx * dx + dz * dz
                    local kind = M.classify(track, overrides)
                    local allowed = filter == "ALL" or (filter == "NO ANIM" and kind ~= "passive")
                        or (filter == "PLAYERS" and kind == "player")
                    if allowed and distance <= range * range then
                        local style = kinds[kind]
                        local x, y = math.floor(cx + dx / range * rx + 0.5), math.floor(cy + dz / range * ry + 0.5)
                        local key = x .. ":" .. y
                        local old = cells[key]
                        if not old or style.priority > old.priority or (style.priority == old.priority and distance < old.distance) then
                            cells[key] = { x = x, y = y, symbol = style.symbol, color = style.color,
                                priority = style.priority, distance = distance }
                        end
                        visible = visible + 1
                    end
                end
            end
        end
        for _, cell in pairs(cells) do f.text(cell.x, cell.y, cell.symbol, cell.color) end
    end
    f.text(cx, cy, "+", "0") -- centre = radar position; north at top, east at right
    f.text(1, height - 1, valid and (filter .. " " .. visible) or "RADAR NO DATA", valid and "8" or "e")
    f.text(1, height, "PAGE", "b")
    f.text(math.floor(width / 3) + 1, height, "RNG", "b")
    f.text(math.floor(2 * width / 3) + 1, height, "FILT", "b")
    return f.rows()
end
return M
