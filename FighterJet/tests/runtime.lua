-- Cooperative integration harness: execute the actual computer-5 program against peripherals.
local realPrint,realClock,realEpoch,realID=print,os.clock,os.epoch,os.getComputerID
local function run(mode)
    local clock,latest,commandSent,reboots,writes=0,nil,false,{},{}
    local terminated=false
    local config=dofile('FighterJet/jet_config.lua')
    local commissioning=mode=='commission' or mode=='thruster'
    config.flight.calibrated=not commissioning; config.flight.thrustersVerified=not commissioning
    config.recovery.grace=1; config.recovery.timeout=1; config.recovery.cooldown=1; config.recovery.maxAttempts=2
    local limits={torsion_spring_0=40,torsion_spring_1=40}
    local commands={directional_gearshift_2=0,directional_gearshift_3=0}
    local starts={}
    local throttle={thruster_8=0,thruster_9=0,thruster_10=0,thruster_11=0}
    local fakeFiles={}; local stateSnapshots={}; local errors={}
    local function pause(d)
        local _,main=coroutine.running()
        if main then clock=clock+math.max(0.05,d) else coroutine.yield(math.max(0.05,d)) end
    end
    _G.sleep=pause
    _G.print=function(...) errors[#errors+1]=table.concat({...},' ') end
    os.clock=function() return clock end
    os.epoch=function() return 123456 end
    os.getComputerID=function() return 5 end
    _G.term={clear=function() end,setCursorPos=function() end}
    _G.shell={getRunningProgram=function() return 'FighterJet/flight.lua' end}
    _G.fs={getDir=function() return 'FighterJet' end,combine=function(a,b) return a..'/'..b end,
        exists=function(p) return fakeFiles[p]~=nil end,
        open=function(p,m)
            local raw=fakeFiles[p] or ''
            return {write=function(s) raw=raw..s end,writeLine=function(s) raw=raw..s..'\n' end,flush=function() end,readAll=function() return raw end,
                close=function() if m=='w' then fakeFiles[p]=raw end end}
        end}
    _G.textutils={serialize=function(v) stateSnapshots[#stateSnapshots+1]=v; return tostring(#stateSnapshots) end,
        unserialize=function(v) return stateSnapshots[tonumber(v)] end}
    local function tasks(all,...)
        local jobs={}
        for _,fn in ipairs({...}) do jobs[#jobs+1]={co=coroutine.create(fn),at=clock} end
        while #jobs>0 do
            local index=1
            for i=2,#jobs do if jobs[i].at<jobs[index].at then index=i end end
            local job=jobs[index]
            if job.at>clock then pause(job.at-clock) end
            if clock>8 and not terminated then terminated=true; error('Terminated',0) end
            local ok,wait=coroutine.resume(job.co)
            if not ok then error(wait,0) end
            if coroutine.status(job.co)=='dead' then
                table.remove(jobs,index); if not all then return end
            else job.at=clock+wait end
        end
    end
    _G.parallel={waitForAny=function(...) return tasks(false,...) end,waitForAll=function(...) return tasks(true,...) end}
    _G.peripheral={call=function(name,method,a,b)
        if method=='getAngles' then
            if mode=='sensor_failure' and clock>2 then error('gimbal detached') end
            return {0,0}
        end
        if method=='getPressedKeyCodes' then
            if mode=='thruster' then
                if (clock>0.5 and clock<2) or (clock>3 and clock<3.5) then return {32} end
                if clock>=2.1 and clock<2.5 then return {83} end
                return {}
            end
            if mode=='commission' and clock>2 and clock<2.5 then return {83,68} end
            if (mode=='override' or mode=='setter_failure') and clock>2 and clock<2.5 then return {68} end
            if clock>0.5 and clock<0.8 then return {32} end
            return {}
        end
        if method=='getHeight' then return 100 end
        if method=='getPosition' then return {x=clock*10,y=100,z=0,space='world',dimension='minecraft:overworld'} end
        if method=='getTargetPosition' then return {x=1000,y=70,z=0,dimension='minecraft:overworld'} end
        if method=='getID' then return name=='left' and 6 or 5 end
        if method=='reboot' then reboots[#reboots+1]=name; return end
        if method=='getLimit' then return limits[name] end
        if method=='isRunning' then return false end
        if method=='getAngle' then
            local gear=name=='torsion_spring_0' and 'directional_gearshift_2' or 'directional_gearshift_3'
            return commands[gear]*limits[name]
        end
        writes[#writes+1]={name,method,a,b}
        if method=='setLimit' then limits[name]=a
        elseif method=='setOutputs' then
            commands[name]=a and -1 or b and 1 or 0
            if mode=='setter_failure' and clock>2 and (a or b) then error('gear failed after write') end
            pause(0.05)
        elseif method=='setThrottle' then
            if a==1 and throttle[name]~=1 then starts[#starts+1]={name=name,at=clock} end
            throttle[name]=a
        elseif method~='setEnabled' then error('Unexpected method '..method) end
    end}
    local acceptedMode=false
    _G.rednet={open=function() end,send=function(id,m)
        assert(id==6)
        latest=m
        if m.mode=='HOLD' then acceptedMode=true end
        return true
    end,receive=function()
        pause(0.1)
        if latest and clock>1 and not commandSent then
            commandSent=true
            return 6,{kind='command',boot=latest.boot,ticket=latest.ticket,revision=latest.revision,
                sequence=latest.nextSequence,command={action='mode',value='HOLD'}}
        end
        -- No HUD heartbeats: flight mode must survive and HUD recovery is bounded.
        return nil
    end}
    local realLoad=loadfile
    _G.loadfile=function(path,...)
        if path=='FighterJet/jet_config.lua' then return function() return config end end
        return realLoad(path,...)
    end
    local ok,err=pcall(realLoad('FighterJet/flight.lua'),commissioning and mode or (mode=='preview' and 'preview' or 'live'))
    _G.loadfile=realLoad
    assert(ok,tostring(err))
    assert(commandSent)
    if commissioning then assert(not acceptedMode and latest.ack and not latest.ack.ok,'Commissioning accepted autopilot')
    else assert(acceptedMode,'Runtime must process a fresh mode request') end
    if mode=='preview' then assert(#writes==0 and #reboots==0,'Preview wrote hardware')
    else
        assert(#reboots==(commissioning and 0 or 2),'Incorrect HUD recovery in test mode')
        for _,name in ipairs(reboots) do assert(name=='left','Never automatically reboot FC5') end
        for _,value in pairs(throttle) do assert(value==0,'Cleanup left thrust on') end
        for _,value in pairs(commands) do assert(value==0,'Cleanup left gear powered') end
    end
    if mode=='thruster' then
        assert(latest.mode=='THRUSTER TEST' and #starts==2,'Holding Space repeated the pulse')
        assert(starts[1].name=='thruster_8' and starts[2].name=='thruster_9','Wrong selected thruster')
        for _,w in ipairs(writes) do if w[2]=='setOutputs' then assert(not w[3] and not w[4],'Thruster test moved wings') end end
    elseif mode=='commission' then
        assert(latest.mode=='DIRECT TEST' and #starts==4)
        local moved=false
        for _,w in ipairs(writes) do if w[2]=='setLimit' and w[3]==5 then moved=true end end
        assert(moved,'Direct pilot inputs did not move surfaces')
        assert(fakeFiles['FighterJet/commission.csv']:find('seconds,gx,gz',1,true))
    elseif mode=='sensor_failure' then assert(latest.fault and latest.fault:find('gimbal detached',1,true))
    elseif mode=='setter_failure' then assert(latest.fault and latest.fault:find('gear failed after write',1,true))
    elseif mode=='override' then assert(latest.mode=='MANUAL','Pilot did not override AP')
    else assert(latest.mode=='HOLD','HUD failure changed flight mode') end
end
for _,mode in ipairs({'preview','live','override','sensor_failure','setter_failure','commission','thruster'}) do run(mode) end
print,os.clock,os.epoch,os.getComputerID=realPrint,realClock,realEpoch,realID
print('Actual flight runtime: preview, live, pilot override, sensor/actuator faults, cleanup, HUD reboot and commissioning tests passed')
