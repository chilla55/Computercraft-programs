-- Computer 6: instruments, radar, autopilot configuration, manual FC5 recovery.
local dir=fs.getDir(shell.getRunningProgram())
local paths=assert(loadfile(fs.combine(dir,'jet_paths.lua')))()
local function module(n) return paths.module(dir,n) end
local c,core,dataReader=module('jet_config'),module('hud_core'),module('hud_data')
local flightCore,link,cockpit=module('flight_core'),module('jet_link'),module('cockpit_ui')
assert(os.getComputerID()==c.hudID,'Run hud on computer '..c.hudID)
local monitor=assert(peripheral.wrap(c.monitor),'Missing monitor '..c.monitor)
assert(monitor.isColor(),'HUD requires a colour monitor')
local oldScale=monitor.getTextScale()
local packet,received,radar,radarRead,radarError,sensorError
local previousRows,ui={},cockpit.new(c)
local status,statusAt,pending,drawAt,sequence=nil,nil,nil,nil,0
local function checked(fn)
    local ok,result=pcall(fn)
    if not ok and result=='Terminated' then error(result,0) end
    return ok,result
end
local function fresh() return statusAt and os.clock()-statusAt<=c.linkTimeout end
local function request(command)
    if not fresh() or not status.healthy then ui.message='Flight unavailable'; return end
    if pending then ui.message='Request pending'; return end
    sequence=math.max(sequence+1,status.nextSequence)
    local m={kind='command',boot=status.boot,ticket=status.ticket,revision=status.revision,
        sequence=sequence,command=command}
    local ok,sent=pcall(rednet.send,c.flightID,m,link.protocol)
    if ok and sent then pending={sequence=sequence,at=os.clock()}; ui.message='Waiting for FC5'
    else ui.message='Send failed' end
end
local function restartFlight()
    local ok,err=checked(function()
        assert(peripheral.call(c.flightPeer,'getID')==c.flightID,'Flight peer ID mismatch')
        peripheral.call(c.flightPeer,'reboot')
    end)
    ui.message=ok and 'FC5 RESTARTED' or tostring(err)
    pending=nil; statusAt=nil
end
local function sensors()
    local cache = {}
    while true do
        local ok, result = checked(function()
            return dataReader.sample(peripheral, c, cache, os.clock(), function(jobs)
                parallel.waitForAll(table.unpack(jobs))
            end)
        end)
        if ok then
            packet, received, sensorError = {data = result}, os.clock(), nil
        else
            packet, received, sensorError = nil, nil, tostring(result)
        end
        sleep(c.sensorInterval)
    end
end
local function radarReader()
    while true do
        local ok, result = checked(function()
            local origin = peripheral.call(c.radar, "getPosition")
            local tracks = peripheral.call(c.radar, "getTracks")
            local range = peripheral.call(c.radar, "getRange")
            assert(type(origin) == "table" and core.finite(origin.x) and core.finite(origin.z), "Invalid radar position")
            assert(type(tracks) == "table" and core.finite(range) and range > 0, "Invalid radar data")
            return { origin = origin, tracks = tracks, range = range }
        end)
        if ok then radar, radarRead, radarError = result, os.clock(), nil
        else radar, radarRead, radarError = nil, nil, tostring(result) end
        sleep(c.radarInterval)
    end
end
local function draw()
    local w,h=monitor.getSize()
    local sf=received and os.clock()-received<=c.staleSeconds
    local rf=radarRead and os.clock()-radarRead<=math.max(3,c.radarInterval*3)
    local rows
    if w<13 or h<9 then
        local f=core.frame(w,h); f.text(1,1,'SMALL DISPLAY','e'); f.text(1,2,w..'x'..h); rows=f.rows()
    else rows=cockpit.render(ui,core,flightCore,c,w,h,packet,sf,radar,rf,status,fresh(),os.clock()) end
    for y,row in ipairs(rows) do
        local signature=table.concat(row,'\0')
        if previousRows[y]~=signature then
            monitor.setCursorPos(1,y); monitor.blit(row[1],row[2],row[3]); previousRows[y]=signature
        end
    end
    drawAt=os.clock()
end
local function network()
    while true do
        pcall(rednet.open,c.modem)
        local id,m=rednet.receive(link.protocol,0.25)
        if id==c.flightID and type(m)=='table' and m.kind=='status' and type(m.boot)=='string'
            and core.finite(m.ticket) and core.finite(m.revision) and core.finite(m.nextSequence)
            and type(m.mode)=='string' and type(m.healthy)=='boolean' then
            local changed=not status or m.boot~=status.boot or not fresh()
            if status and m.boot==status.boot and m.ticket<=status.ticket then
                -- Ignore delayed/out-of-order status; do not refresh freshness.
            else
                if changed then
                    pending=nil; sequence=m.nextSequence-1
                    ui.draftAltitude=m.altitude or c.flight.cruiseAltitude
                    if flightCore.position(m.home) then ui.home=flightCore.position(m.home) end
                    ui.message='Synced with FC5'
                end
                if changed or (status and m.revision~=status.revision) then ui.manualUntil=nil end
                status,statusAt=m,os.clock()
                if pending and type(m.ack)=='table' and m.ack.sequence==pending.sequence then
                    ui.message=(m.ack.ok and 'OK: ' or 'NO: ')..tostring(m.ack.message)
                    if m.ack.ok and flightCore.position(m.home) then ui.home=flightCore.position(m.home) end
                    pending=nil
                end
            end
        end
        if pending and os.clock()-pending.at>c.linkTimeout then
            pending=nil; ui.message='No ACK; check state' -- never replay a command automatically
        end
        if status and drawAt and os.clock()-drawAt<2 then
            pcall(rednet.send,c.flightID,{kind='hud',boot=status.boot,ticket=status.ticket},link.protocol)
        end
    end
end
local function screen()
    draw()
    local timer=os.startTimer(0.25)
    while true do
        local event,name,x,y=os.pullEvent()
        if event=='timer' and name==timer then draw(); timer=os.startTimer(0.25)
        elseif event=='monitor_touch' and name==c.monitor then
            local w,h=monitor.getSize()
            if not fresh() or not status.healthy then ui.manualUntil=nil end
            local command=cockpit.touch(ui,x,y,w,h,os.clock())
            ui.draftAltitude=flightCore.clamp(ui.draftAltitude,c.flight.minAltitude,c.flight.maxAltitude)
            if command then
                if command.localAction=='range' then ui.range=ui.range%#c.ranges+1
                elseif command.localAction=='rebootFlight' then restartFlight()
                else request(command) end
            end
            previousRows={}; draw()
        elseif event=='monitor_resize' and name==c.monitor then previousRows={}; draw() end
    end
end
local function console()
    print('HUD: touch PAGE for horizon/data/radar/AP/home/system.')
    print('Console: home X Y Z [dimension], altitude N, mode MANUAL|HOLD|ALT|HOME')
    print('Also: here, marker, restart5, quit. Flight keys are read only by FC5.')
    while true do
        write('hud> ')
        local line=read()
        local words={}; for word in line:gmatch('%S+') do words[#words+1]=word end
        if words[1]=='quit' then return
        elseif words[1]=='restart5' then restartFlight()
        elseif words[1]=='status' then print(textutils.serialize(status or {}))
        elseif words[1]=='home' then
            local p={x=tonumber(words[2]),y=tonumber(words[3]),z=tonumber(words[4]),dimension=words[5] or c.homeDimension}
            if flightCore.position(p) then ui.home=p; request({action='home',value=p}) else print('Use home X Y Z [dimension]') end
        elseif words[1]=='here' or words[1]=='marker' then request({action='home',source=words[1]})
        elseif words[1]=='altitude' then request({action='altitude',value=tonumber(words[2])})
        elseif words[1]=='mode' then request({action='mode',value=words[2] and words[2]:upper()})
        else print('Unknown command') end
        print(ui.message or '')
    end
end
local ok,err=pcall(function()
    monitor.setTextScale(c.textScale); monitor.setBackgroundColor(colors.black); monitor.clear()
    parallel.waitForAny(sensors,radarReader,network,screen,console)
end)
pcall(function()
    monitor.setTextScale(oldScale); monitor.setBackgroundColor(colors.black); monitor.setTextColor(colors.white)
    monitor.clear(); monitor.setCursorPos(1,1); monitor.write('HUD OFF')
end)
if not ok and err~='Terminated' then error(err,0) end
