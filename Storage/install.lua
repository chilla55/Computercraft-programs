-- Storage monitor installer and automatic-update launcher.
local hash = (function()
-- SHA-256, Lua 5.2/CC bit32. Hashes bytes; not an authentication mechanism.
local b=bit32
local K={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local function word(n) return string.char(b.extract(n,24,8),b.extract(n,16,8),b.extract(n,8,8),b.extract(n,0,8)) end
return function(s)
  local bits=#s*8
  s=s..'\128'..string.rep('\0',(55-#s)%64)..word(math.floor(bits/2^32))..word(bits%2^32)
  local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  for p=1,#s,64 do
    local w={}
    for i=0,15 do local a,c,d,e=s:byte(p+i*4,p+i*4+3); w[i]=a*2^24+c*2^16+d*256+e end
    for i=16,63 do
      local x,y=w[i-15],w[i-2]
      w[i]=(w[i-16]+b.bxor(b.rrotate(x,7),b.rrotate(x,18),b.rshift(x,3))+w[i-7]+b.bxor(b.rrotate(y,17),b.rrotate(y,19),b.rshift(y,10)))%2^32
    end
    local a,c,d,e,f,g,j,k=table.unpack(h)
    for i=0,63 do
      local t1=(k+b.bxor(b.rrotate(f,6),b.rrotate(f,11),b.rrotate(f,25))+b.bxor(b.band(f,g),b.band(b.bnot(f),j))+K[i+1]+w[i])%2^32
      local t2=(b.bxor(b.rrotate(a,2),b.rrotate(a,13),b.rrotate(a,22))+b.bxor(b.band(a,c),b.band(a,d),b.band(c,d)))%2^32
      k,j,g,f,e,d,c,a=j,g,f,(e+t1)%2^32,d,c,a,(t1+t2)%2^32
    end
    local v={a,c,d,e,f,g,j,k}; for i=1,8 do h[i]=(h[i]+v[i])%2^32 end
  end
  local out={}; for i=1,8 do out[i]=string.format('%08x',h[i]) end
  return table.concat(out)
end

end)()
local M = { interval = 300 }
local base = "https://raw.githubusercontent.com/chilla55/Computercraft-programs/main/Storage/"
local function readFile(path)
    local f = assert(fs.open(path, "r"), "Cannot read " .. path)
    local body = f.readAll(); f.close(); return body
end
local function writeFile(path, body)
    local f = assert(fs.open(path, "w"), "Cannot write " .. path)
    f.write(body); f.close()
end
local function remove(path) if fs.exists(path) then fs.delete(path) end end
function M.version(body)
    return body:match("^%-%- stock%-monitor%-version: (%d+%.%d+%.%d+)\n")
end
function M.newer(a, b)
    local function parts(v)
        local x, y, z = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$")
        assert(x, "Invalid version")
        return { tonumber(x), tonumber(y), tonumber(z) }
    end
    local x, y = parts(a), parts(b)
    for i = 1, 3 do if x[i] ~= y[i] then return x[i] > y[i] end end
    return false
end
function M.validate(manifest, body)
    assert(type(manifest) == "table" and manifest.schema == 1, "Invalid release manifest")
    assert(type(manifest.version) == "string", "Missing version")
    M.newer(manifest.version, "0.0.0")
    assert(type(manifest.size) == "number" and manifest.size % 1 == 0
        and manifest.size > 0 and manifest.size <= 1048576, "Invalid release size")
    assert(type(manifest.sha256) == "string" and #manifest.sha256 == 64
        and not manifest.sha256:find("[^0-9a-f]"), "Invalid checksum")
    if body then
        assert(#body == manifest.size and hash(body) == manifest.sha256, "Download checksum mismatch")
        assert(M.version(body) == manifest.version, "Download version mismatch")
        assert(load(body, "@stock_monitor.lua", "t", {}), "Invalid Lua download")
    end
    return manifest
end
function M.get(url)
    assert(http and http.get, "HTTP is disabled")
    local response, reason, failed = http.get(url, nil, true)
    if not response then
        if failed then failed.close() end
        error(reason or "Download failed", 0)
    end
    local ok, body = pcall(function() return response.readAll() end)
    response.close()
    assert(ok, body)
    assert(type(body) == "string" and #body <= 1048576, "Oversized HTTP response")
    return body
end
function M.recover(path)
    if not fs.exists(path) and fs.exists(path .. ".bak") then
        fs.move(path .. ".bak", path)
    end
end
function M.update(root, get)
    get = get or M.get
    local path = fs.combine(root, "stock_monitor.lua")
    M.recover(path)
    local suffix = "?check=" .. tostring(os.epoch("utc"))
    local manifest = M.validate(textutils.unserializeJSON(get(base .. "release.json" .. suffix)))
    local rejected = fs.combine(root, "rejected.sha256")
    if fs.exists(rejected) and readFile(rejected) == manifest.sha256 then return false end
    if fs.exists(path) then
        local current = readFile(path)
        if hash(current) == manifest.sha256 then return false end
        local version = M.version(current)
        assert(version, "Installed monitor has no version; reinstall into a new directory")
        if not M.newer(manifest.version, version) then return false end
    end
    local body = get(base .. "stock_monitor.lua" .. suffix)
    M.validate(manifest, body)
    local staging = path .. ".download"
    writeFile(staging, body)
    M.validate(manifest, readFile(staging))
    -- No active file is touched until the complete staged file is verified.
    if fs.exists(path) then
        remove(path .. ".bak")
        fs.move(path, path .. ".bak")
    end
    local ok, reason = pcall(fs.move, staging, path)
    if not ok then M.recover(path); error(reason, 0) end
    return true
end
function M.rollback(root)
    local path = fs.combine(root, "stock_monitor.lua")
    if not fs.exists(path .. ".bak") then return false end
    -- Remember a crashing build so checks do not repeatedly reinstall it.
    writeFile(fs.combine(root, "rejected.sha256"), hash(readFile(path)))
    remove(path)
    fs.move(path .. ".bak", path)
    return true
end
local function log(root, message)
    -- Keep only the latest updater status, without writing over the monitor UI.
    pcall(writeFile, fs.combine(root, "update-status.txt"),
        tostring(os.epoch("utc")) .. " " .. message .. "\n")
end
function M.launch(path, args, services)
    local app = assert(loadfile(path))("--module")
    assert(type(app) == "table" and type(app.main) == "function", "Invalid monitor module")
    app.main(args, services)
end
function M.run(root, args)
    local path = fs.combine(root, "stock_monitor.lua")
    M.recover(path)
    if args[1] then return M.launch(path, args, { program = path }) end
    assert(fs.exists(path), "Missing monitor; run the installer again in a new directory")
    while true do
        local applied, appOK, appError = false, nil, nil
        local services = { program = path, configuring = true,
            updateStatus = "Automatic checks on startup and every 5 minutes." }
        local requested = false
        local function status(message)
            services.updateStatus = message
            log(root, message)
            os.queueEvent("stock_monitor_status")
        end
        services.requestUpdate = function()
            requested = true
            status("Manual update check requested...")
            os.queueEvent("stock_monitor_update_check")
        end
        parallel.waitForAny(function()
            appOK, appError = pcall(M.launch, path, {}, services)
        end, function()
            while true do
                while services.configuring do os.pullEvent("stock_monitor_configured") end
                requested = false
                status("Checking GitHub for updates...")
                local ok, changed = pcall(M.update, root, function(url)
                    local bytes = M.get(url)
                    -- Configuration can begin while an HTTP request is pending.
                    -- Pause before activation so the wizard is never interrupted.
                    while services.configuring do os.pullEvent("stock_monitor_configured") end
                    return bytes
                end)
                if not ok and changed == "Terminated" then error(changed, 0) end
                if ok and changed then
                    applied = true
                    status("Update installed; restarting monitor")
                    return
                end
                status(ok and "Up to date (or release held after rollback). Next check in 5 minutes."
                    or ("Update check failed; retrying in 5 minutes: " .. tostring(changed)))
                local timer = os.startTimer(M.interval)
                while not requested do
                    local event, id = os.pullEvent()
                    if event == "timer" and id == timer then break end
                end
                os.cancelTimer(timer)
            end
        end)
        if not applied then
            if appError == "Terminated" then return end
            if appOK == false and M.rollback(root) then
                log(root, "Monitor failed; restored previous version: " .. tostring(appError))
            else
                if appOK == false then error(appError, 0) end
                return -- Q and normal exits stop the updater too.
            end
        end
    end
end
function M.install(directory, startup)
    assert(type(directory) == "string" and directory:match("^[%w_-]+$"), "Use a simple directory name")
    local root = shell.resolve(directory)
    local startupPath = "/startup/stock_monitor.lua"
    assert(not fs.exists(root), "Installation exists; run " .. directory .. "/start.lua --run")
    if startup then
        assert(not fs.exists(startupPath), "Stock monitor startup entry already exists")
        assert(not fs.exists("/startup") or fs.isDir("/startup"), "Existing /startup is a file; use --no-startup and add the launcher to it manually")
    end
    fs.makeDir(root)
    local ok, reason = pcall(function()
        assert(M.update(root), "No installable release")
        fs.copy(shell.getRunningProgram(), fs.combine(root, "start.lua"))
    end)
    if not ok then fs.delete(root); error(reason, 0) end
    if startup then
        fs.makeDir("/startup")
        writeFile(startupPath, "shell.run(" .. string.format("%q", "/" .. root:gsub("^/", "") .. "/start.lua") .. ", \"--run\")\n")
    end
    print("Installed in " .. root)
    if startup then print("Startup enabled: " .. startupPath) end
    print("Start: " .. root .. "/start.lua --run")
    print("Automatic update checks run every five minutes while the launcher is open.")
end
function M.main(args)
    if args[1] == "--run" then
        table.remove(args, 1)
        return M.run(fs.getDir(shell.getRunningProgram()), args)
    end
    assert(#args <= 2 and (not args[2] or args[2] == "--startup" or args[2] == "--no-startup"),
        "Usage: install [directory] [--no-startup]")
    M.install(args[1] or "storage", args[2] ~= "--no-startup")
end
if not shell then return M end
M.main({...})
