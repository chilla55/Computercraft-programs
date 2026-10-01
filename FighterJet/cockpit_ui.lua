-- Compact 1x1 colour-monitor cockpit pages and touch actions.
local M={pages={'horizon','flight','radar','autopilot','home','system','navigation'}}
function M.new(c) return {page=1,range=#c.ranges,filter=1,draftAltitude=c.flight.cruiseAltitude,
    home={x=0,y=90,z=0,dimension=c.homeDimension},coordinate=1,step=100} end
function M.touch(ui,x,y,w,h,now)
    local page=M.pages[ui.page]
    if page~='flight' or y~=8 then ui.manualUntil=nil end
    if y==h then
        if page~='radar' or x<=math.floor(w/3) then ui.page=ui.page%#M.pages+1; ui.rebootUntil=nil
        elseif x<=math.floor(2*w/3) then return {localAction='range'}
        else ui.filter=ui.filter%3+1 end
    elseif page=='flight' then
        if y==7 then return {action='control',value='ASSIST'} end
        if y==8 then
            if ui.manualUntil and now<=ui.manualUntil then
                ui.manualUntil=nil
                return {action='control',value='DIRECT',confirmed=true}
            end
            ui.manualUntil=now+4
        end
    elseif page=='autopilot' then
        if y==3 then ui.draftAltitude=ui.draftAltitude+(x<=w/2 and -10 or 10)
        elseif y==4 then return {action='altitude',value=ui.draftAltitude}
        elseif y==5 then return {action='mode',value='HOLD'}
        elseif y==6 then return {action='mode',value='ALT'}
        elseif y==7 then return {action='mode',value='HOME'}
        elseif y==8 then return {action='control',value='ASSIST'} end
    elseif page=='home' then
        if y>=3 and y<=5 then ui.coordinate=y-2
        elseif y==6 then
            local axis=({'x','y','z'})[ui.coordinate]
            ui.home[axis]=ui.home[axis]+(x<=w/2 and -ui.step or ui.step)
        elseif y==7 then ui.step=({[1]=10,[10]=100,[100]=1000,[1000]=1})[ui.step]
        elseif y==8 then return {action='home',value={x=ui.home.x,y=ui.home.y,z=ui.home.z,dimension=ui.home.dimension}}
        elseif y==2 then return {action='home',source=x<=w/2 and 'here' or 'marker'} end
    elseif page=='system' and y==5 then
        if ui.rebootUntil and now<=ui.rebootUntil then ui.rebootUntil=nil; return {localAction='rebootFlight'} end
        ui.rebootUntil=now+4
    end
end
function M.render(ui,core,flightCore,c,w,h,packet,sensorsFresh,radar,radarFresh,status,linkFresh,now)
    local page=M.pages[ui.page]
    local d=sensorsFresh and packet and packet.data or {}
    local f=core.frame(w,h)
    local header=not linkFresh and 'FLIGHT LINK LOST' or (status.fault and 'FLIGHT FAULT' or
        (status.healthy and ((status.live and '' or 'SIM ')..status.mode) or 'FLIGHT NOT READY'))
    local headerColor=linkFresh and status.healthy and '5' or 'e'
    if page=='radar' then
        local range=c.ranges[ui.range]
        if radarFresh then range=math.min(range,radar.range) end
        local rows=core.radar(w,h,radarFresh and radar or nil,range,({'ALL','NO ANIM','PLAYERS'})[ui.filter],c.entityKinds,sensorsFresh)
        if not linkFresh or not status.healthy then
            local overlay=core.frame(w,1); overlay.text(1,1,header,'e'); rows[1]=overlay.rows()[1]
        end
        return rows
    end
    f.text(1,1,header,headerColor)
    if page=='flight' then
        f.text(1,2,'FLIGHT DATA','b')
        f.text(1,3,'ALT '..core.number(d.altitude,1))
        f.text(1,4,'Vraw '..core.number(d.velocity,1))
        f.text(1,5,'T '..core.number(d.throttle and d.throttle*100)..'%')
        f.text(1,6,'COAL '..core.number(d.engineCoal)..'/'..core.number(d.reserveCoal))
        f.text(1,7,'ENABLE ASSIST','b')
        f.text(1,8,ui.manualUntil and now<=ui.manualUntil and 'CONFIRM MANUAL' or 'DIRECT MANUAL','e')
    elseif page=='horizon' then
        local valid,pitch,bank=false,nil,nil
        local assist=linkFresh and status.assist
        if d.gimbal then valid,pitch,bank=pcall(flightCore.attitude,d.gimbal,assist and assist.profile or c.flight) end
        if linkFresh and status.commission then
            local test=status.commission
            local assist=status.vectoring and status.vectoring.enabled and math.floor(status.vectoring.authority*100) or 0
            f.text(1,2,test.kind=='thruster' and test.thruster or ('DIRECT '..test.degrees..' V'..assist),'4')
            f.text(1,3,'NO ATTITUDE HOLD','4')
            f.text(1,4,'GX '..core.number(d.gimbal and d.gimbal[1],2))
            f.text(1,5,'GZ '..core.number(d.gimbal and d.gimbal[2],2))
            if test.kind=='thruster' then
                f.text(1,6,'W/S SELECT','b'); f.text(1,7,'SPACE PULSE','b')
            else
                f.text(1,6,'L '..core.number(status.surfaces and status.surfaces.left)..' R '..core.number(status.surfaces and status.surfaces.right))
                f.text(1,7,'W/S BOTH A/D MIX','b')
            end
            f.text(1,8,'THRUST '..core.number(test.throttle*100)..'%')
        elseif valid and (c.flight.calibrated or assist) then
            local cx,cy=(w+1)/2,(h+2)/2
            local angle=math.rad(bank)
            for y=3,h-2 do
                for x=1,w do
                    local line=(y-cy)*2*math.cos(angle)+(x-cx)*math.sin(angle)-pitch*0.15
                    f.backgrounds[y][x]=line>0 and 'c' or 'b'
                    if math.abs(line)<0.8 then f.text(x,y,'-','0') end
                end
            end
            f.text(math.floor(cx)-1,math.floor(cy),'-+-','4')
            f.text(1,2,'P'..core.number(pitch,1)..' B'..core.number(bank,1))
            if assist then
                local pitchSource=status.surfaces and status.surfaces.pitchControl
                f.text(1,h-2,assist.enabled==false and 'NO STABILIZER' or
                    (pitchSource=='THRUST' and 'P:THRUST R:WING' or 'ASSIST TUNING'),'4')
            end
        else
            f.text(1,3,d.gimbal and 'CALIBRATE AXES' or 'NO GIMBAL','4')
            f.text(1,4,'GX '..core.number(d.gimbal and d.gimbal[1],1))
            f.text(1,5,'GZ '..core.number(d.gimbal and d.gimbal[2],1))
        end
        f.text(1,h-1,'A'..core.number(d.altitude)..' V'..core.number(d.velocity))
    elseif page=='autopilot' then
        f.text(1,2,'AUTOPILOT','b')
        f.text(1,3,'- ALT '..core.number(ui.draftAltitude)..' +','b')
        f.text(1,4,'APPLY ALTITUDE','b')
        f.text(1,5,'HOLD ATTITUDE','b')
        f.text(1,6,'HOLD ALTITUDE','b')
        f.text(1,7,'RETURN HOME','b')
        f.text(1,8,'ENABLE ASSIST','b')
    elseif page=='home' then
        f.text(1,2,'HERE / MARKER','b')
        for i,axis in ipairs({'x','y','z'}) do
            f.text(1,i+2,(ui.coordinate==i and '>' or ' ')..axis:upper()..' '..core.number(ui.home[axis]),'0')
        end
        f.text(1,6,'-    VALUE    +','b')
        f.text(1,7,'STEP '..ui.step,'b')
        f.text(1,8,'SAVE HOME XYZ','b')
    elseif page=='navigation' then
        local pos=d.position or {}
        local home=status and status.home
        local distance
        if home and pos.x and pos.dimension==home.dimension then
            distance=math.sqrt((home.x-pos.x)^2+(home.z-pos.z)^2)
        end
        f.text(1,2,'WORLD POSITION','b')
        f.text(1,3,'X '..core.number(pos.x,1))
        f.text(1,4,'Y '..core.number(pos.y,1))
        f.text(1,5,'Z '..core.number(pos.z,1))
        f.text(1,6,'HOME '..core.number(distance))
        f.text(1,7,'COURSE '..core.number(linkFresh and status.course or nil))
        f.text(1,8,home and 'HOME SAVED' or 'NO HOME','4')
    elseif page=='system' then
        f.text(1,2,'SYSTEM','b')
        f.text(1,3,'FC5 '..(linkFresh and 'ONLINE' or 'NO LINK'))
        f.text(1,4,'HUD6 RESTART '..tostring(status and status.restarts or 0))
        f.text(1,5,ui.rebootUntil and now<=ui.rebootUntil and 'TAP TO CONFIRM' or 'RESTART FC5','e')
        f.text(1,6,'MODE '..(status and status.mode or '--'),linkFresh and '0' or '7')
        f.text(1,7,c.flight.calibrated and 'AXES VERIFIED' or 'AXES UNVERIFIED','4')
        f.text(1,8,status and status.warning or '')
    end
    if h>=10 and page~='horizon' then f.text(1,h-1,ui.message or (status and status.warning) or '', '4') end
    f.text(1,h,'PAGE > '..page,'b')
    return f.rows()
end
return M
