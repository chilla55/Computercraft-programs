-- Computer 5: flight and autopilot owner. Usage: flight [preview|live]
local args={...}
assert(#args<=1 and (not args[1] or args[1]=='preview' or args[1]=='live'),'Usage: flight [preview|live]')
local live=args[1]=='live'
local dir=fs.getDir(shell.getRunningProgram())
local paths=assert(loadfile(fs.combine(dir,'jet_paths.lua')))()
local function module(n) return paths.module(dir,n) end
local c,core,link,store,hw=module('jet_config'),module('flight_core'),module('jet_link'),module('jet_store'),module('hardware')
assert(os.getComputerID()==c.flightID,'Run flight on computer '..c.flightID)
assert(not live or (c.flight.calibrated and c.flight.thrustersVerified),
    'Live blocked: verify gimbal/control signs and thrust directions in jet_config.lua first')
assert(c.flight.pitchAxis~=c.flight.bankAxis and (c.flight.pitchAxis==1 or c.flight.pitchAxis==2)
    and (c.flight.bankAxis==1 or c.flight.bankAxis==2),'Invalid gimbal axes')
for _,key in ipairs({'pitchSign','bankSign','pitchSurfaceSign','bankSurfaceSign'}) do
    assert(math.abs(c.flight[key])==1,'Invalid '..key)
end
assert(c.flight.maxSurface>=1 and c.flight.maxSurface<=40 and c.flight.maxSurface%1==0,'Invalid surface limit')
local statePath=fs.combine(paths.root(dir),'jet_state')
local state=core.new(c.flight,store.load(statePath))
local boot=tostring(os.epoch('utc'))..':'..tostring(math.random(1,2147483647))
local server=link.server(boot)
local desired={left=0,right=0,throttle=0}
local sample,ready,fault,lastCycle,cycles=nil,false,nil,nil,0
local pending,ack,lastHUD=nil,nil,nil
local started=os.clock()
local watchdog={started=started,attempts=0}
local wings={hw.wings.right,hw.wings.left}
wings[1].side='right'; wings[2].side='left'
local function call(n,m,...) return peripheral.call(n,m,...) end
local function optional(n,m)
    local ok,v=pcall(call,n,m)
    if not ok and v=='Terminated' then error(v,0) end
    return ok and v or nil
end
local function cycleSleep(t,period) sleep(math.max(0,period-(os.clock()-t))) end
local function stopOutputs()
    local failures={}
    if not live then return failures end
    local jobs={}
    for _,w in ipairs(wings) do
        local wing=w
        jobs[#jobs+1]=function()
            local ok,e=pcall(call,wing.gearshift,'setOutputs',false,false)
            if not ok then failures[#failures+1]=tostring(e) end
        end
    end
    for _,name in ipairs(c.thrusters) do
        local n=name
        jobs[#jobs+1]=function()
            local ok,e=pcall(call,n,'setThrottle',0)
            if not ok then failures[#failures+1]=tostring(e) end
        end
    end
    parallel.waitForAll(table.unpack(jobs))
    return failures
end
local function healthyOutput()
    return ready and not fault and lastCycle and os.clock()-lastCycle<=c.flight.outputTimeout
end
local function refresh(wing)
    while true do
        local t=os.clock()
        local command=healthyOutput() and (wing.command or 0) or 0
        call(wing.gearshift,'setOutputs',command<0,command>0)
        wing.refreshed=os.clock()
        cycleSleep(t,0.05)
    end
end
local function limits(wing)
    wing.applied=call(wing.spring,'getLimit')
    wing.original=wing.applied
    local unsettledAt
    while true do
        local target=healthyOutput() and desired[wing.side]*wing.upAngleSign or 0
        if target==0 then wing.command=0
        elseif math.abs(target)==wing.applied then wing.command=target
        elseif not call(wing.spring,'isRunning') then
            call(wing.spring,'setLimit',math.abs(target))
            local actual=call(wing.spring,'getLimit')
            if actual==math.abs(target) then wing.applied=actual; wing.command=target end
        end
        local angle=call(wing.spring,'getAngle')
        assert(core.finite(angle),'Invalid spring angle: '..wing.side)
        if math.abs(angle-target)>1 then
            unsettledAt=unsettledAt or os.clock()
            assert(os.clock()-unsettledAt<5,'Surface not following command: '..wing.side)
        else unsettledAt=nil end
        wing.limitProgress=os.clock()
        sleep(0.05)
    end
end
local function thrust()
    local applied=nil
    while true do
        local target=healthyOutput() and desired.throttle or 0
        if applied~=target then
            local jobs={}
            for _,name in ipairs(c.thrusters) do
                local n=name
                jobs[#jobs+1]=function() call(n,'setThrottle',target); call(n,'setEnabled',true) end
            end
            parallel.waitForAll(table.unpack(jobs)); applied=target
        end
        state.appliedThrottle=applied
        state.thrustProgress=os.clock()
        sleep(0.05)
    end
end
local function control()
    local previousTime,previousAltitude,coursePosition,courseTime,courseAt,course
    local nav,nextNav={},0
    while true do
        local begin=os.clock()
        local raw,keys,altitude
        local jobs={function() raw=call(c.gimbal,'getAngles') end,
            function() keys=call(c.typewriter,'getPressedKeyCodes') end,
            function() altitude=optional(c.altitude,'getHeight') end}
        if begin>=nextNav then
            jobs[#jobs+1]=function()
                local position=optional(c.position.name,c.position.method)
                nav.position=type(position)=='table' and position.space=='world' and core.position(position) or nil
                nav.marker=c.navigation and core.position(optional(c.navigation,'getTargetPosition')) or nil
                nav.at=os.clock()
            end
            nextNav=begin+c.flight.courseInterval
        end
        parallel.waitForAll(table.unpack(jobs))
        local now=os.clock()
        local pitch,bank=core.attitude(raw,c.flight)
        local input=core.input(keys)
        local dt=previousTime and now-previousTime or c.flight.period
        if nav.position and nav.at and nav.at~=(courseTime or -1) then
            local nextCourse=core.course(coursePosition,nav.position,courseTime and nav.at-courseTime or 0,c.flight.courseMinSpeed)
            if nextCourse then course=nextCourse; courseAt=now end
            coursePosition=nav.position; courseTime=nav.at
        end
        if courseAt and now-courseAt>c.flight.courseMaxAge then course=nil end
        local vertical=core.finite(altitude) and previousAltitude and dt>0 and (altitude-previousAltitude)/dt or 0
        sample={pitch=pitch,bank=bank,altitude=altitude,verticalSpeed=vertical,position=nav.position,
            marker=nav.marker,course=course}
        if not ready then
            state.pitch=pitch; state.bank=bank
            if not input.any then ready=true end
        end
        if pending then
            local request=pending; pending=nil
            local accepted,reason=link.accept(server,request,state.revision,now,c.requestMaxAge)
            if accepted and (input.any or not ready) then accepted=false; reason='Pilot input active' end
            if accepted then
                local oldHome,oldAlt,oldRevision=state.home,state.altitude,state.revision
                accepted,reason=core.command(state,request.command,sample,c.flight)
                if accepted and request.command.action~='mode' then
                    local ok,err=pcall(store.save,statePath,{home=state.home,altitude=state.altitude})
                    if not ok then
                        state.home,state.altitude,state.revision=oldHome,oldAlt,oldRevision
                        accepted=false; reason='Save failed: '..tostring(err)
                    end
                end
            end
            ack={sequence=request.sequence,ok=accepted,message=reason}
        end
        if ready then desired=core.step(state,sample,input,dt,c.flight) end
        previousTime=now; previousAltitude=core.finite(altitude) and altitude or nil
        lastCycle=os.clock(); cycles=cycles+1
        if live and now-started>c.flight.outputTimeout*2 then
            for _,w in ipairs(wings) do
                assert(w.refreshed and now-w.refreshed<c.flight.outputTimeout,'Wing output stalled: '..w.side)
                assert(w.limitProgress and now-w.limitProgress<c.flight.outputTimeout,'Wing limit stalled: '..w.side)
            end
            assert(state.thrustProgress and now-state.thrustProgress<c.flight.outputTimeout,'Thrust output stalled')
        end
        cycleSleep(begin,c.flight.period)
    end
end
local function flightTask()
    local ok,err=pcall(function()
        if live then
            local failures=stopOutputs(); assert(#failures==0,table.concat(failures,'; '))
            parallel.waitForAny(control,function() refresh(wings[1]) end,function() refresh(wings[2]) end,
                function() limits(wings[1]) end,function() limits(wings[2]) end,thrust)
        else control() end
    end)
    ready=false; fault=tostring(err or 'Flight loop stopped'); desired={left=0,right=0,throttle=0}
    local errors=stopOutputs()
    if #errors>0 then fault=fault..'; output cleanup: '..table.concat(errors,'; ') end
    if not ok and err=='Terminated' then error(err,0) end
    print('FLIGHT FAULT: '..fault)
    -- Keep diagnostics/network alive. Never automatically reboot computer 5.
    while true do sleep(1) end
end
local function network()
    while true do
        pcall(rednet.open,c.modem)
        local id,m=rednet.receive(link.protocol,0.25)
        if id==c.hudID and type(m)=='table' then
            if m.kind=='hud' and m.boot==boot and type(m.ticket)=='number' and server.tickets[m.ticket]
                and os.clock()-server.tickets[m.ticket]<c.linkTimeout then lastHUD=os.clock()
            elseif m.kind=='command' and not pending and not fault then pending=m end
        end
    end
end
local function statusSender()
    while true do
        local now=os.clock()
        local m={kind='status',boot=boot,ticket=link.ticket(server,now),revision=state.revision,
            nextSequence=server.lastCommand+1,mode=state.mode,live=live,ready=ready,fault=fault,
            cycle=cycles,healthy=ready and not fault and lastCycle~=nil and now-lastCycle<c.flight.outputTimeout,
            targetPitch=state.pitch,targetBank=state.bank,altitude=state.altitude,home=state.home,
            distance=state.distance,course=sample and sample.course,throttle=state.throttle,
            surfaces=desired,warning=state.warning,ack=ack,restarts=watchdog.attempts,
            calibrated=c.flight.calibrated}
        pcall(rednet.send,c.hudID,m,link.protocol)
        sleep(0.5)
    end
end
local function recovery()
    while true do
        if live and link.recovery(watchdog,os.clock(),lastHUD,c.recovery) then
            local ok,err=pcall(function()
                assert(call(c.hudPeer,'getID')==c.hudID,'HUD peer ID mismatch')
                call(c.hudPeer,'reboot')
            end)
            print(ok and 'Restarted HUD computer 6' or ('HUD restart failed: '..tostring(err)))
        end
        sleep(1)
    end
end
local function screen()
    while true do
        term.setCursorPos(1,1); term.clear()
        print('FIGHTER '..(live and 'LIVE' or 'PREVIEW - NO ACTUATOR WRITES'))
        print(fault and ('FAULT: '..fault) or (ready and state.mode or 'Release flight keys first'))
        if sample then print(string.format('Pitch %.1f Bank %.1f',sample.pitch,sample.bank)) end
        print(string.format('Surfaces L %d R %d Thrust %d',desired.left,desired.right,desired.throttle))
        print('W/S pitch A/D bank Space ON Shift OFF')
        print('HUD '..(lastHUD and os.clock()-lastHUD<c.linkTimeout and 'CONNECTED' or 'OFFLINE'))
        print('Ctrl+T stops this controller')
        sleep(1)
    end
end
print('Starting fighter '..(live and 'LIVE' or 'PREVIEW'))
local ok,err=pcall(function() parallel.waitForAny(flightTask,network,statusSender,recovery,screen) end)
local failures=stopOutputs()
if #failures>0 then print('Cleanup failed: '..table.concat(failures,'; ')) end
-- Restore original spring limits after neutral, if termination allows it.
if live then
    for _,w in ipairs(wings) do
        if w.original then
            local restored,reason=pcall(function()
                local deadline=os.clock()+3
                repeat
                    if not call(w.spring,'isRunning') and math.abs(call(w.spring,'getAngle'))<0.5 then
                        call(w.spring,'setLimit',w.original); return
                    end
                    sleep(0.1)
                until os.clock()>deadline
                error('Spring did not return to neutral')
            end)
            if not restored then print('Limit restore: '..tostring(reason)) end
        end
    end
end
if not ok and err~='Terminated' then error(err,0) end
