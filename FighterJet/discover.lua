-- Run in CraftOS: discover [output-file]
-- Inspect names/types/methods only; never invoke device methods.
local args = { ... }
assert(#args <= 1, "Usage: discover [output-file]")
local path = args[1] or "fighter-peripherals.txt"
if args[1] then
    assert(not fs.exists(path), "Output already exists: " .. path)
else
    local index = 1
    while fs.exists(path) do
        path = "fighter-peripherals-" .. index .. ".txt"
        index = index + 1
    end
end

local lines = {}
local function emit(line) lines[#lines + 1] = line end
emit("Fighter jet peripheral discovery")
emit("Names and methods only; device methods were not called.")
emit("")
emit("All connected peripherals:")
local names = peripheral.getNames()
table.sort(names)
for _, name in ipairs(names) do emit("  " .. name) end
if #names == 0 then emit("  (none)") end

for _, name in ipairs(names) do
    emit("")
    emit("[" .. name .. "]")
    local ok, types, methods = pcall(function()
        if not peripheral.isPresent(name) then return nil end
        return { peripheral.getType(name) }, peripheral.getMethods(name)
    end)
    if not ok then
        emit("  Inspection failed: " .. tostring(types))
    elseif not types or not methods then
        emit("  MISSING or disconnected; check the wired modem connection/name.")
    else
        emit("  Types: " .. table.concat(types, ", "))
        table.sort(methods)
        emit("  Methods:")
        for _, method in ipairs(methods) do emit("    " .. method) end
        if #methods == 0 then emit("    (none)") end
    end
end

local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
file.write(table.concat(lines, "\n") .. "\n")
file.close()
print("Saved peripheral dump to " .. path)
textutils.pagedPrint(table.concat(lines, "\n"))
