-- Pure flight logic: pitch positive nose-up, bank positive right-wing-down.
local M = {}
function M.finite(v) return type(v) == 'number' and v == v and math.abs(v) < math.huge end
function M.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function M.wrap(v) return (v + 180) % 360 - 180 end
function M.position(p)
    if type(p) ~= 'table' or not M.finite(p.x) or not M.finite(p.y) or not M.finite(p.z) then return nil end
    if p.space and p.space ~= 'world' then return nil end
    if math.abs(p.x)>30000000 or math.abs(p.z)>30000000 or math.abs(p.y)>10000 then return nil end
    if p.dimension~=nil and (type(p.dimension)~='string' or #p.dimension>128) then return nil end
    return {x=p.x, y=p.y, z=p.z, dimension=p.dimension}
end
function M.attitude(a, c)
    assert(type(a) == 'table', 'Missing gimbal angles')
    local p, b = a[c.pitchAxis], a[c.bankAxis]
    assert(M.finite(p) and M.finite(b), 'Invalid gimbal angles')
    p=M.wrap((p-c.pitchOffset)*c.pitchSign)
    b=M.wrap((b-c.bankOffset)*c.bankSign)
    if c.projectedPitch then
        -- Simulated reports atan2(down.x,-down.y), not Euler pitch.
        -- Remove the roll projection: pitch = atan2(forwardDown, transverseLength).
        local pr,br=math.rad(p),math.rad(b)
        p=math.deg(math.atan2(math.sin(pr)*math.abs(math.cos(br)),math.abs(math.cos(pr))))
    end
    return p,b
end
-- Explicit tuning mode: observed upright signs, independent of saved calibration flags.
-- This profile does not certify the aircraft or enable navigation/autopilot.
function M.assistConfig(base, custom)
    local c={}; for k,v in pairs(base) do c[k]=v end
    local defaults={pitchAxis=2,bankAxis=1,pitchSign=1,bankSign=-1,
        pitchOffset=0,bankOffset=0,pitchSurfaceSign=1,bankSurfaceSign=-1,
        maxSurface=40,pitchKp=0.6,bankKp=0.6,pitchKd=0.5,bankKd=0.4,
        pitchRateLimit=25,bankRateLimit=40,rateFilter=0.15,
        pitchEnvelope=35,bankEnvelope=55,envelopeKp=2,thrustAuthority=0.6}
    assert(custom==nil or type(custom)=='table','Invalid assist profile')
    for k,v in pairs(defaults) do c[k]=custom and custom[k] or v end
    for k in pairs(defaults) do assert(M.finite(c[k]),'Invalid assist '..k) end
    for _,k in ipairs({'pitchKp','bankKp','pitchKd','bankKd','rateFilter'}) do
        assert(c[k]>0 and c[k]<=10,'Invalid assist '..k)
    end
    for _,k in ipairs({'pitchRateLimit','bankRateLimit'}) do
        assert(c[k]>0 and c[k]<=90,'Invalid assist '..k)
    end
    assert(c.pitchEnvelope>0 and c.pitchEnvelope<85 and c.bankEnvelope>0 and c.bankEnvelope<85,'Invalid assist envelope')
    assert(c.envelopeKp>0 and c.envelopeKp<=10,'Invalid envelope gain')
    assert(c.thrustAuthority>=0 and c.thrustAuthority<=1,'Invalid assist thrust authority')
    c.projectedPitch=true
    c.rateControl=true
    return c
end
function M.input(codes)
    assert(type(codes) == 'table', 'Invalid typewriter data')
    local held = {}
    for _, code in pairs(codes) do assert(type(code)=='number', 'Invalid key code'); held[code]=true end
    return {pitch=(held[83] and 1 or 0)-(held[87] and 1 or 0),
        bank=(held[68] and 1 or 0)-(held[65] and 1 or 0),
        on=held[32] or false, off=held[340] or false,
        any=held[87] or held[83] or held[65] or held[68] or held[32] or held[340] or false}
end
-- Direct commissioning demand: mechanical directions, no attitude feedback.
function M.direct(input, degrees, throttle)
    if input.off then throttle=0 elseif input.on then throttle=1 end
    -- Pilot observation: left-UP/right-DOWN banks left on this aircraft.
    local left=(input.pitch-input.bank)*degrees
    local right=(input.pitch+input.bank)*degrees
    local scale=degrees>0 and math.max(1,math.abs(left)/degrees,math.abs(right)/degrees) or 1
    local function rounded(v) return math.floor(math.abs(v)/scale+0.5)*(v<0 and -1 or 1) end
    return {left=rounded(left),right=rounded(right),throttle=throttle,pitchAssist=input.pitch,yawAssist=input.bank}
end
-- Forward-facing diamond layout, viewed from behind toward the nose.
-- This changes pitch/yaw torque by reducing opposing engines; it cannot produce axial roll.
function M.vectorConfig(custom)
    -- Legacy defaults: new installs provide explicit IDs; saved remaps override these.
    local c={enabled=true,authority=0.25,pitchSign=1,yawSign=1,
        top='thruster_9',bottom='thruster_8',left='thruster_11',right='thruster_10'}
    if custom==false then c.enabled=false
    elseif custom~=nil then
        assert(type(custom)=='table','Invalid vectoring configuration')
        for key in pairs(c) do if custom[key]~=nil then c[key]=custom[key] end end
    end
    assert(type(c.enabled)=='boolean' and M.finite(c.authority) and c.authority>=0 and c.authority<=1,'Invalid thrust authority')
    assert((c.pitchSign==1 or c.pitchSign==-1) and (c.yawSign==1 or c.yawSign==-1),'Invalid thrust direction signs')
    local seen={}
    for _,side in ipairs({'top','bottom','left','right'}) do
        assert(type(c[side])=='string' and not seen[c[side]],'Invalid/duplicate thruster mapping')
        seen[c[side]]=true
    end
    return c
end
function M.thrustMix(names,base,pitch,yaw,c)
    local out={}
    assert(M.finite(base) and M.finite(pitch) and M.finite(yaw),'Invalid thrust demand')
    base=M.clamp(base,0,1)
    for _,name in ipairs(names) do out[name]=base end
    if not c.enabled or base==0 then return out end
    for _,side in ipairs({'top','bottom','left','right'}) do assert(out[c[side]]~=nil,'Unmapped '..side..' thruster') end
    pitch=M.clamp(pitch*c.pitchSign,-1,1); yaw=M.clamp(yaw*c.yawSign,-1,1)
    local p=pitch>=0 and c.top or c.bottom
    local y=yaw>=0 and c.right or c.left
    out[p]=base*(1-c.authority*math.abs(pitch))
    out[y]=base*(1-c.authority*math.abs(yaw))
    -- Quantise to 1% to avoid needless writes from sub-percent sensor noise.
    for name,value in pairs(out) do out[name]=math.floor(value*100+0.5)/100 end
    return out
end
-- A pulse requires a new Space press; holding it cannot restart an expired pulse.
function M.pulse(s,input,now,count)
    if not input.on then s.latched=false end
    if input.off or not input.on then s.untilTime=nil end
    if not input.on and input.pitch~=0 and not s.selectHeld then
        s.selected=((s.selected or 1)-1+input.pitch)%count+1
    end
    s.selectHeld=input.pitch~=0
    s.selected=s.selected or 1
    if input.on and not input.off and not s.latched then
        s.untilTime=now+0.3; s.latched=true
    end
    if input.off then s.latched=true end
    return s.untilTime and now<s.untilTime and 1 or 0
end
function M.new(c, saved)
    saved = saved or {}
    return {mode='MANUAL', throttle=0, revision=0, pitch=nil, bank=nil,
        altitude=M.finite(saved.altitude) and M.clamp(saved.altitude,c.minAltitude,c.maxAltitude) or c.cruiseAltitude,
        home=M.position(saved.home), warning=nil}
end
function M.course(previous, current, dt, minimum)
    if not previous or not current or dt <= 0 or previous.dimension ~= current.dimension then return nil end
    local dx, dz = current.x-previous.x, current.z-previous.z
    if math.sqrt(dx*dx+dz*dz)/dt < minimum then return nil end
    return math.deg(math.atan2(dx,-dz)) -- north=0, east=90
end
function M.command(s, cmd, sample, c)
    if type(cmd) ~= 'table' then return false, 'Invalid command' end
    if cmd.action == 'control' then
        if not c.rateControl then return false,'Control selector requires assisted flight runtime' end
        if cmd.value~='ASSIST' and cmd.value~='DIRECT' then return false,'Unknown control selection' end
        if cmd.value=='DIRECT' and cmd.confirmed~=true then return false,'Confirm direct manual control first' end
        s.direct=cmd.value=='DIRECT'; s.mode='MANUAL'
        s.pitch=sample.pitch; s.bank=sample.bank
        s.lastPitch=sample.pitch; s.lastBank=sample.bank
        s.pitchRate=0; s.bankRate=0; s.pitchHeld=false; s.bankHeld=false
    elseif cmd.action == 'home' then
        local p = M.position(cmd.value or (cmd.source=='here' and sample.position or sample.marker))
        if not p or (sample.position and p.dimension and sample.position.dimension and p.dimension ~= sample.position.dimension) then
            return false, 'No valid home coordinates'
        end
        p.dimension = p.dimension or (sample.position and sample.position.dimension)
        s.home=p
    elseif cmd.action == 'altitude' then
        if not M.finite(cmd.value) or cmd.value<c.minAltitude or cmd.value>c.maxAltitude then return false,'Altitude out of range' end
        s.altitude=cmd.value
    elseif cmd.action == 'mode' then
        if cmd.value~='MANUAL' and cmd.value~='HOLD' and cmd.value~='ALT' and cmd.value~='HOME' then return false,'Unknown mode' end
        if cmd.value == 'ALT' or cmd.value == 'HOME' then
            if not M.finite(sample.altitude) then return false,'Altitude unavailable' end
        end
        if cmd.value == 'HOME' then
            if not s.home then return false,'Mark and save home first' end
            if not sample.position or not sample.position.dimension or not s.home.dimension or sample.position.dimension ~= s.home.dimension then return false,'Home dimension unavailable/different' end
            if not M.finite(sample.course) then return false,'Fly forward to establish course' end
        end
        s.mode=cmd.value; s.pitch=sample.pitch; s.bank=sample.bank
        if s.mode=='ALT' then s.bank=0 end
    else return false, 'Unknown command' end
    s.revision=s.revision+1
    s.warning=nil
    return true, 'Accepted'
end
function M.step(s, a, input, dt, c)
    assert(M.finite(a.pitch) and M.finite(a.bank), 'Invalid attitude')
    if c.rateControl and s.direct then
        local demand=M.direct(input,c.maxSurface,s.throttle)
        s.throttle=demand.throttle
        return demand
    end
    dt=M.clamp(dt,0.01,0.5)
    if not s.pitch then s.pitch=a.pitch; s.bank=a.bank end
    if input.any and s.mode~='MANUAL' then
        s.mode='MANUAL'; s.pitch=a.pitch; s.bank=a.bank; s.revision=s.revision+1; s.warning='PILOT OVERRIDE'
    end
    if input.off then s.throttle=0 elseif input.on then s.throttle=1 end
    if s.mode=='MANUAL' then
        if input.pitch~=0 then s.pitch=M.clamp(a.pitch+input.pitch*c.pitchLead,-c.maxPitch,c.maxPitch)
        elseif s.pitchHeld then s.pitch=a.pitch end
        if input.bank~=0 then s.bank=M.wrap(a.bank+input.bank*c.bankLead)
        elseif s.bankHeld then s.bank=a.bank end
    elseif s.mode=='ALT' or s.mode=='HOME' then
        if not M.finite(a.altitude) then
            s.mode='HOLD'; s.pitch=a.pitch; s.bank=a.bank; s.revision=s.revision+1; s.warning='ALTITUDE LOST'
        else
            s.pitch=M.clamp((s.altitude-a.altitude)*c.altitudeKp-(a.verticalSpeed or 0)*c.altitudeKd,-c.maxAPPitch,c.maxAPPitch)
            if s.mode=='HOME' then
                local p,h=a.position,s.home
                if not p or not h or p.dimension~=h.dimension or not M.finite(a.course) then
                    s.mode='ALT'; s.bank=0; s.revision=s.revision+1; s.warning='NAV LOST: ALT HOLD'
                else
                    local dx,dz=h.x-p.x,h.z-p.z
                    s.distance=math.sqrt(dx*dx+dz*dz)
                    if s.distance<=c.arrivalRadius then
                        s.mode='ALT'; s.bank=0; s.revision=s.revision+1; s.warning='HOME REACHED'
                    else
                        local bearing=math.deg(math.atan2(dx,-dz))
                        s.bank=M.clamp(M.wrap(bearing-a.course)*c.courseKp,-c.maxAPBank,c.maxAPBank)
                    end
                end
            else s.bank=0 end
        end
    end
    if c.rateControl then
        s.pitch=M.clamp(s.pitch,-c.pitchEnvelope,c.pitchEnvelope)
        s.bank=M.clamp(s.bank,-c.bankEnvelope,c.bankEnvelope)
    end
    s.pitchHeld=input.pitch~=0; s.bankHeld=input.bank~=0
    local pr=s.lastPitch and M.wrap(a.pitch-s.lastPitch)/dt or 0
    local br=s.lastBank and M.wrap(a.bank-s.lastBank)/dt or 0
    local alpha=dt/(c.rateFilter+dt)
    s.pitchRate=(s.pitchRate or 0)+alpha*(pr-(s.pitchRate or 0))
    s.bankRate=(s.bankRate or 0)+alpha*(br-(s.bankRate or 0))
    s.lastPitch=a.pitch; s.lastBank=a.bank
    local pitchEffort=c.pitchKp*M.wrap(s.pitch-a.pitch)-c.pitchKd*s.pitchRate
    local bankEffort=c.bankKp*M.wrap(s.bank-a.bank)-c.bankKd*s.bankRate
    if c.rateControl and s.mode=='MANUAL' then
        local function rateDemand(value,key,limit,rate)
            local demand=key*rate
            -- Approach the boundary with a shrinking outward rate allowance.
            -- Outside it, request an inward rate even if the pilot holds outward.
            return M.clamp(demand,
                M.clamp((-limit-value)*c.envelopeKp,-rate,rate),
                M.clamp((limit-value)*c.envelopeKp,-rate,rate))
        end
        if input.pitch~=0 then pitchEffort=c.pitchKd*(rateDemand(a.pitch,input.pitch,c.pitchEnvelope,c.pitchRateLimit)-s.pitchRate) end
        if input.bank~=0 then bankEffort=c.bankKd*(rateDemand(a.bank,input.bank,c.bankEnvelope,c.bankRateLimit)-s.bankRate) end
    end
    local common=pitchEffort*c.pitchSurfaceSign
    local differential=bankEffort*c.bankSurfaceSign
    if c.rateControl then
        -- Preserve collective pitch authority when roll saturates the shared surfaces.
        common=M.clamp(common,-c.maxSurface,c.maxSurface)
        local remaining=c.maxSurface-math.abs(common)
        differential=M.clamp(differential,-remaining,remaining)
    end
    local left,right=common+differential,common-differential
    local scale=math.max(1,math.abs(left)/c.maxSurface,math.abs(right)/c.maxSurface)
    local function round(v) return math.floor(math.abs(v)/scale+0.5)*(v<0 and -1 or 1) end
    return {left=round(left),right=round(right),throttle=s.throttle,
        pitchAssist=M.clamp(pitchEffort/c.maxSurface,-1,1),
        yawAssist=c.rateControl and 0 or s.mode=='HOME' and M.clamp(s.bank/c.maxAPBank,-1,1) or input.bank}
end
return M
