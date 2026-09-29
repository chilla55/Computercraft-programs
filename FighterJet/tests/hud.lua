local core = assert(loadfile("FighterJet/hud_core.lua"))()
local reader = assert(loadfile("FighterJet/hud_data.lua"))()
local c = assert(loadfile("FighterJet/jet_config.lua"))()
assert(core.classify({ category = "PLAYER" }, {}) == "player")
assert(core.classify({ category = "HOSTILE" }, {}) == "hostile")
assert(core.classify({ category = "ANIMAL" }, {}) == "passive")
assert(core.classify({ entityType = "entity.test.ship" }, {}) == "unknown")
assert(core.classify({ entityType = "entity.test.ship" }, { ["entity.test.ship"] = "structure" }) == "structure")
local function checkRows(rows, w, h)
    assert(#rows == h)
    for _, row in ipairs(rows) do
        assert(#row[1] == w and #row[2] == w and #row[3] == w)
        assert(not row[2]:find("[^0-9a-f]") and not row[3]:find("[^0-9a-f]"))
    end
end
local snapshot = { origin = {x = 0, z = 0}, tracks = {
    {category = "ANIMAL", position = {x = 50, z = 0}},
    {category = "HOSTILE", position = {x = 50, z = 0}},
    {category = "PLAYER", position = {x = 50, z = 0}},
    {category = "HOSTILE", position = {x = 0, z = -50}},
    {category = "ANIMAL", position = {x = -50, z = 0}},
    {category = "ANIMAL", position = {x = 999, z = 0}},
    {category = "HOSTILE", position = {x = 0/0, z = 0}},
    {category = "HOSTILE"},
} }
local rows = core.radar(15, 10, snapshot, 100, "ALL", {}, true)
checkRows(rows, 15, 10)
-- Player wins a collision east of centre; hostile is north, animal west.
assert(rows[5][1]:sub(11,11) == "P" and rows[5][2]:sub(11,11) == "9")
assert(rows[4][1]:sub(8,8) == "H" and rows[4][2]:sub(8,8) == "e")
assert(rows[5][1]:sub(5,5) == "A")
local filtered = core.radar(15, 10, snapshot, 100, "PLAYERS", {}, true)
assert(filtered[5][1]:sub(11,11) == "P" and filtered[5][1]:sub(5,5) ~= "A")
local missing = core.radar(15, 10, nil, 100, "ALL", {}, false)
assert(missing[9][1]:find("RADAR NO DATA", 1, true))
local packet = {data = {altitude = 123.4, velocity = 12, throttle = 0.5,
    gimbal = {0, 5.8}, engineCoal = 64, reserveCoal = 358, navDistance = -1, errorCount = 0}}
for _, size in ipairs({{7,5}, {15,10}, {29,19}}) do
    checkRows(core.flight(size[1], size[2], packet, true), size[1], size[2])
    checkRows(core.radar(size[1], size[2], snapshot, 100, "ALL", {}, true), size[1], size[2])
end
local stale = core.flight(15,10,packet,false)
assert(stale[3][1]:find("ALT --",1,true) and not stale[3][1]:find("123",1,true))
local calls, failGimbal, failInventory = {}, false, false
local p = {call = function(name, method)
    calls[method] = (calls[method] or 0) + 1
    assert(method:sub(1,3) == "get" or method == "list", "Unexpected write")
    if method == "getPosition" then return {x=100,y=90,z=600,space="world",dimension="minecraft:overworld"} end
    if method == "getHeight" then return 123.4 end
    if method == "getVelocity" then return 12 end
    if method == "getAngles" then if failGimbal then error("disconnected") end; return {0,5.8} end
    if method == "getStatus" then return {throttle = 0.5} end
    if method == "getTargetDistance" then return -1 end
    if method == "list" then
        if failInventory then error("inventory missing") end
        return { [6] = {name="minecraft:coal",count=64}, [12]={name="minecraft:coal",count=38},
            [1]={name="minecraft:stone",count=999} }
    end
    error("Unexpected read")
end}
local cache = {}
local data = reader.sample(p, c, cache, 0)
assert(data.engineCoal == 102 and data.reserveCoal == 102 and data.throttle == 0.5 and data.errorCount == 0)
reader.sample(p,c,cache,0.5)
assert(calls.list == 2, "Inventory polled too frequently")
failGimbal, failInventory = true, true
local bad = reader.sample(p,c,cache,3)
assert(bad.gimbal == nil and bad.engineCoal == nil and bad.reserveCoal == nil and bad.errorCount == 3)
assert(bad.altitude == 123.4)
print("HUD rendering, radar filtering, stale data and read-only polling tests passed")
-- Print a compact visual preview for a 15x10 display.
for _, row in ipairs(rows) do print(row[1]) end
