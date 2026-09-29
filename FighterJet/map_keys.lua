-- Read-only linked-typewriter recorder; no aircraft outputs are changed.
local args = { ... }
assert(#args <= 2, "Usage: map_keys [seconds] [typewriter-name]")
local duration = args[1] and tonumber(args[1]) or 180
assert(duration and duration >= 10 and duration <= 1800,
    "Recording duration must be 10..1800 seconds")
local name = args[2] or "top"
assert(peripheral.isPresent(name), "Missing typewriter: " .. name)
local available = {}
for _, method in ipairs(peripheral.getMethods(name) or {}) do available[method] = true end
assert(available.getPressedKeyCodes, "Peripheral has no getPressedKeyCodes method")
local path, index = "fighter-keys.txt", 0
while fs.exists(path) do
    index = index + 1
    path = "fighter-keys-" .. index .. ".txt"
end
local file, reason = fs.open(path, "w")
assert(file, reason or ("Cannot write " .. path))
local started, previous, changes, bytes = os.clock(), nil, 0, 0
local function emit(line)
    -- Bound file growth even if a peripheral returns unexpected data.
    assert(bytes + #line + 1 <= 65536, "Keyboard report reached 64 KiB limit")
    file.writeLine(line)
    file.flush()
    bytes = bytes + #line + 1
end
local ok, err = pcall(function()
    emit("Fighter linked-typewriter raw input recording: " .. name)
    emit("Suggested order: W, S, A, D, Space, Left Shift")
    emit("Times are seconds since recording started; only changed states are recorded.")
    print("Recording for " .. duration .. " seconds. Move to the typewriter now.")
    print("Press separately: W S A D Space Left-Shift")
    print("Hold each about 2 seconds; release all keys between presses.")
    print("No further computer interaction is needed until finished.")
    while os.clock() - started < duration do
        local raw = peripheral.call(name, "getPressedKeyCodes")
        local serialized = textutils.serialize(raw, { compact = true })
        if serialized ~= previous then
            emit(string.format("%.2f: %s", os.clock() - started, serialized))
            previous = serialized
            changes = changes + 1
        end
        sleep(0.1)
    end
    emit("Recording finished. Changed states: " .. changes)
end)
file.close()
print("Saved keyboard recording to " .. path)
if not ok and err ~= "Terminated" then error(err, 0) end
