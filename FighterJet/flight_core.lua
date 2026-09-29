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
    return M.wrap((p-c.pitchOffset)*c.pitchSign), M.wrap((b-c.bankOffset)*c.bankSign)
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
    if cmd.action == 'home' then
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
    s.pitchHeld=input.pitch~=0; s.bankHeld=input.bank~=0
    local pr=s.lastPitch and M.wrap(a.pitch-s.lastPitch)/dt or 0
    local br=s.lastBank and M.wrap(a.bank-s.lastBank)/dt or 0
    local alpha=dt/(c.rateFilter+dt)
    s.pitchRate=(s.pitchRate or 0)+alpha*(pr-(s.pitchRate or 0))
    s.bankRate=(s.bankRate or 0)+alpha*(br-(s.bankRate or 0))
    s.lastPitch=a.pitch; s.lastBank=a.bank
    local common=(c.pitchKp*M.wrap(s.pitch-a.pitch)-c.pitchKd*s.pitchRate)*c.pitchSurfaceSign
    local differential=(c.bankKp*M.wrap(s.bank-a.bank)-c.bankKd*s.bankRate)*c.bankSurfaceSign
    local left,right=common+differential,common-differential
    local scale=math.max(1,math.abs(left)/c.maxSurface,math.abs(right)/c.maxSurface)
    local function round(v) return math.floor(math.abs(v)/scale+0.5)*(v<0 and -1 or 1) end
    return {left=round(left),right=round(right),throttle=s.throttle}
end
return M
