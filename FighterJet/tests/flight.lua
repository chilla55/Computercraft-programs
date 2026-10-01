local core=dofile('FighterJet/flight_core.lua')
local c=dofile('FighterJet/jet_config.lua').flight
local link=dofile('FighterJet/jet_link.lua')
local ui=dofile('FighterJet/cockpit_ui.lua')
local render=dofile('FighterJet/hud_core.lua')
local config=dofile('FighterJet/jet_config.lua')
local none=core.input({})
local function sample(p,b)
    return {pitch=p or 0,bank=b or 0,altitude=100,position={x=0,y=100,z=0,dimension='minecraft:overworld'},course=0}
end
-- Commissioning must be usable with both verification flags false.
local direct=core.direct(core.input({83,68,32}),5,0)
assert(direct.left==0 and direct.right==5 and direct.throttle==1)
for _,angle in ipairs({5,20,30,40}) do
    local left=core.direct(core.input({65}),angle,0)
    local right=core.direct(core.input({68}),angle,0)
    assert(left.left==angle and left.right==-angle,'A must reverse the old mapping')
    assert(right.left==-angle and right.right==angle,'D must reverse the old mapping')
    local mix=core.direct(core.input({83,68}),angle,0)
    assert(mix.left==0 and mix.right==angle,'Mixed demand must remain within selected angle')
end
local neutral=core.direct(core.input({}),5,direct.throttle)
assert(neutral.left==0 and neutral.right==0 and neutral.throttle==1)
assert(core.direct(core.input({340}),5,1).throttle==0)
local pulse={selected=1}
assert(core.pulse(pulse,core.input({32}),0,4)==1)
assert(core.pulse(pulse,core.input({32}),0.31,4)==0)
assert(core.pulse(pulse,core.input({32}),2,4)==0)
core.pulse(pulse,core.input({83}),3,4)
assert(pulse.selected==2)
core.pulse(pulse,core.input({83}),4,4)
assert(pulse.selected==2,'Holding selection must not scroll continually')
assert(core.pulse(pulse,core.input({32}),5,4)==1)
assert(core.pulse(pulse,core.input({32,340}),5.1,4)==0)
assert(core.pulse(pulse,core.input({32}),5.2,4)==0,'Shift must require Space release before firing again')
local names={'thruster_8','thruster_9','thruster_10','thruster_11'}
local v=core.vectorConfig(nil)
local t=core.thrustMix(names,1,1,1,v)
assert(t.thruster_8==1 and t.thruster_9==0.75 and t.thruster_10==0.75 and t.thruster_11==1)
t=core.thrustMix(names,1,-1,-1,v)
assert(t.thruster_8==0.75 and t.thruster_9==1 and t.thruster_10==1 and t.thruster_11==0.75)
for _,value in pairs(core.thrustMix(names,0,1,1,v)) do assert(value==0,'Shift must kill all thrust') end
for _,value in pairs(core.thrustMix(names,1,1,1,core.vectorConfig(false))) do assert(value==1,'Disabled assist changed thrust') end
for pitch=-3,3 do for yaw=-3,3 do
    for _,value in pairs(core.thrustMix(names,1,pitch,yaw,v)) do assert(value>=0.75 and value<=1) end
end end
assert(not pcall(core.vectorConfig,{authority=2}))
assert(not pcall(core.vectorConfig,{top='thruster_8'}))
local enginesOnly=core.direct(core.input({83,68}),0,1)
assert(enginesOnly.left==0 and enginesOnly.right==0 and enginesOnly.pitchAssist==1 and enginesOnly.yawAssist==1)
local s=core.new(c)
core.step(s,sample(10,20),none,0.1,c)
assert(s.pitch==10 and s.bank==20 and s.throttle==0)
core.step(s,sample(12,22),core.input({83,68,32}),0.1,c)
assert(s.pitch>12 and s.bank>22 and s.throttle==1)
core.step(s,sample(15,25),none,0.1,c)
assert(s.pitch==15 and s.bank==25 and s.throttle==1,'Release must capture current attitude and latch thrust')
core.step(s,sample(15,25),core.input({32,340}),0.1,c)
assert(s.throttle==0,'OFF wins')
local rev=s.revision
assert(core.command(s,{action='mode',value='HOLD'},sample(),c))
core.step(s,sample(),core.input({87,83}),0.1,c)
assert(s.mode=='MANUAL' and s.revision==rev+2,'Opposing keys still override AP')
assert(not core.command(s,{action='mode',value='HOME'},sample(),c))
assert(not core.command(s,{action='home',value={x=0/0,y=1,z=1}},sample(),c))
assert(core.command(s,{action='home',value={x=200,y=70,z=0}},sample(),c))
assert(s.home.dimension=='minecraft:overworld')
assert(core.command(s,{action='altitude',value=130},sample(),c))
assert(core.command(s,{action='mode',value='HOME'},sample(),c))
core.step(s,sample(),none,0.1,c)
assert(s.bank>0 and s.pitch>0,'Home east from north requires right bank; climb to selected altitude')
for i=1,100 do core.step(s,sample(),none,0.1,c) end
assert(s.mode=='HOME','Link absence must not change mode')
local atHome=sample(); atHome.position.x=190
core.step(s,atHome,none,0.1,c)
assert(s.mode=='ALT' and s.warning=='HOME REACHED' and s.altitude==130,'Arrival must not land at home Y')
assert(core.command(s,{action='mode',value='HOME'},sample(),c))
local lost=sample(); lost.course=nil
core.step(s,lost,none,0.1,c)
assert(s.mode=='ALT' and s.warning=='NAV LOST: ALT HOLD')
lost.altitude=nil; core.step(s,lost,none,0.1,c)
assert(s.mode=='HOLD' and s.warning=='ALTITUDE LOST')
assert(core.course({x=0,z=0},{x=-10,z=0},1,2)==-90)
assert(core.course({x=0,z=0},{x=0.1,z=0},1,2)==nil)
assert(core.course({x=0,z=0,dimension='a'},{x=10,z=0,dimension='b'},1,2)==nil)
-- Both axes at once retain the command ratio under saturation.
s=core.new(c); s.pitch=50; s.bank=40
local demand=core.step(s,sample(),none,0.1,c)
assert(math.abs(demand.left)<=10 and math.abs(demand.right)<=10 and demand.left~=demand.right)
-- Simple plant sanity check: disturbances must decay with calibrated positive signs.
s=core.new(c); s.pitch=0; s.bank=0
local p,b=10,-10
for i=1,150 do
    local d=core.step(s,sample(p,b),none,0.1,c)
    p=p+(d.left+d.right)*0.05; b=b-(d.left-d.right)*0.05
end
assert(math.abs(p)<2 and math.abs(b)<2,'Feedback should reduce error')
-- Session/ticket/revision/sequence reject stale AP commands.
local server=link.server('boot1'); local ticket=link.ticket(server,10)
local m={boot='boot1',revision=3,ticket=ticket,sequence=1}
assert(link.accept(server,m,3,10.5,2))
assert(not link.accept(server,m,3,10.5,2))
m.sequence=2
assert(not link.accept(server,m,4,10.5,2),'Pilot revision invalidates old AP command')
assert(not link.accept(server,m,3,13,2),'Expired request')
m.boot='boot0'; assert(not link.accept(server,m,3,10.5,2),'Previous boot')
local recovery={autoRestartHUD=true,grace=30,timeout=10,cooldown=60,maxAttempts=3}
local w={started=0,attempts=0}
assert(not link.recovery(w,29,nil,recovery))
assert(link.recovery(w,30,nil,recovery))
assert(not link.recovery(w,40,nil,recovery))
assert(link.recovery(w,90,nil,recovery)); assert(link.recovery(w,150,nil,recovery))
assert(not link.recovery(w,1000,nil,recovery),'Must stop reboot loop')
-- UI cannot reboot from one accidental touch; no reboot action outside system page.
local model=ui.new(config); model.page=6
assert(not ui.touch(model,2,5,15,10,0))
assert(ui.touch(model,2,5,15,10,1).localAction=='rebootFlight')
assert(not ui.touch(model,2,5,15,10,10))
assert(not ui.touch(model,2,5,15,10,15),'Confirmation must expire')
for page=1,#ui.pages do
    model.page=page
    for _,calibrated in ipairs({false,true}) do
        config.flight.calibrated=calibrated
        for _,fresh in ipairs({false,true}) do
            local rows=ui.render(model,render,core,config,15,10,{data={gimbal={0,0}}},true,nil,false,
                {healthy=true,live=false,mode='MANUAL'},fresh,0)
            assert(#rows==10)
            for _,r in ipairs(rows) do assert(#r[1]==15 and #r[2]==15 and #r[3]==15) end
            if not fresh then assert(rows[1][1]=='FLIGHT LINK LOS','Lost link must be visible on every page') end
        end
    end
end
print('Flight control, navigation, protocol, watchdog and cockpit tests passed')

-- Active assistance uses observed signs without changing persistent calibration.
local ac=core.assistConfig(c)
assert(ac.bankSign==-1 and c.bankSign==1 and ac.maxSurface==40)
local pitch,bank=core.attitude({-12,7},ac)
assert(pitch>6.8 and pitch<7 and bank==12)
local s=core.new(ac)
core.step(s,sample(),none,0.1,ac)
local out=core.step(s,sample(0,10),none,0.1,ac)
assert(out.left>out.right,'Rightward disturbance must command left roll')
assert(out.yawAssist==0,'Bank stabilization must not introduce unmeasured yaw')
assert(out.left<=40 and out.right>=-40)
s=core.new(ac)
core.step(s,sample(),none,0.1,ac)
out=core.step(s,sample(10,0),none,0.1,ac)
assert(out.left<0 and out.right<0 and out.pitchAssist<0,'Pitch-up motion must be damped nose-down')
s=core.new(ac)
core.step(s,sample(),core.input({83,68}),0.1,ac)
out=core.step(s,sample(3,4),none,0.1,ac)
assert(s.pitch==3 and s.bank==4,'Release must capture current attitude')
assert(out.left+out.right<0 and out.right-out.left<0,'Release must brake both rotation rates')
-- Inertial toy plant: rate input, release and simultaneous disturbance recovery.
-- Verifies feedback direction/convergence, not actual Minecraft aerodynamic gains.
s=core.new(ac)
local p,b,pr,br=0,0,0,0
for i=1,400 do
    local input=i<=20 and core.input({83,68}) or none
    local demand=core.step(s,sample(p,b),input,0.05,ac)
    pr=pr+((demand.left+demand.right)/2*4-pr*0.2)*0.05
    br=br+((demand.right-demand.left)/2*4-br*0.2)*0.05
    p=p+pr*0.05; b=b+br*0.05
    if i==160 then pr=pr+15; br=br-20 end
    assert(math.abs(demand.left)<=40 and math.abs(demand.right)<=40)
end
assert(math.abs(p-s.pitch)<2 and math.abs(b-s.bank)<2,'Attitude hold failed to recover disturbance')
assert(math.abs(pr)<2 and math.abs(br)<2,'Rotation was not damped')
assert(not pcall(core.assistConfig,c,{pitchKd=-1}))
print('Assisted rate control, attitude capture, disturbance recovery and bounds passed')

config.flight.calibrated=false
local display=ui.new(config); display.page=1
-- Find horizon without relying on page ordering.
for i,name in ipairs(ui.pages) do if name=='horizon' then display.page=i end end
local rows=ui.render(display,render,core,config,15,10,{data={gimbal={-12,7}}},true,nil,false,
    {healthy=true,live=true,mode='MANUAL',assist={profile=ac}},true,0)
local text=''; for _,row in ipairs(rows) do text=text..row[1]..'\n' end
assert(text:find('ASSIST TUNING',1,true),'HUD must show active assist despite saved calibration=false')
assert(text:find('B12.0',1,true),'HUD must use active negative GX bank sign')

-- Direct manual requires explicit confirmation, preserves throttle, and assistance
-- recaptures attitude/derivatives without returning to the pre-manual target.
local switch=core.new(ac); switch.throttle=1
assert(not core.command(switch,{action='control',value='DIRECT'},sample(10,20),ac))
assert(not switch.direct and switch.revision==0)
assert(core.command(switch,{action='control',value='DIRECT',confirmed=true},sample(10,20),ac))
local manual=core.step(switch,sample(15,30),core.input({68}),0.1,ac)
assert(manual.left==-40 and manual.right==40 and manual.throttle==1)
manual=core.step(switch,sample(25,45),none,0.1,ac)
assert(manual.left==0 and manual.right==0 and switch.direct,'Release must keep selected direct mode')
assert(core.command(switch,{action='control',value='ASSIST'},sample(25,45),ac))
assert(not switch.direct and switch.pitch==25 and switch.bank==45 and switch.throttle==1)
local captured=core.step(switch,sample(25,45),none,0.1,ac)
assert(captured.left==0 and captured.right==0,'Re-enable caused stale derivative/target kick')
local buttons=ui.new(config); buttons.page=2
assert(not ui.touch(buttons,2,8,15,10,1),'One tap must not disable assistance')
local confirmed=ui.touch(buttons,2,8,15,10,2)
assert(confirmed.action=='control' and confirmed.value=='DIRECT' and confirmed.confirmed)
assert(not ui.touch(buttons,2,8,15,10,10))
assert(not ui.touch(buttons,2,8,15,10,15),'Expired confirmation must need another tap')
assert(ui.touch(buttons,2,7,15,10,16).value=='ASSIST' and not buttons.manualUntil)
assert(not core.new(ac).direct,'Reboot must never restore direct control')
print('Manual confirmation, expiry, throttle preservation and assisted recapture passed')

-- Reconstruct known gravity projections, including inverted banks.
for _,p in ipairs({-80,-35,0,35,80}) do
    for _,b in ipairs({-150,-55,0,55,150}) do
        local pr,br=math.rad(p),math.rad(b)
        local dx=math.sin(pr)
        local dy=-math.cos(pr)*math.cos(br)
        local dz=-math.cos(pr)*math.sin(br)
        local raw={math.deg(math.atan2(dz,-dy)),math.deg(math.atan2(dx,-dy))}
        local gotP,gotB=core.attitude(raw,ac)
        assert(math.abs(gotP-p)<1e-8 and math.abs(core.wrap(gotB-b))<1e-8,'Projected tilt was treated as Euler pitch')
    end
end
local envelope=core.new(ac)
core.step(envelope,sample(70,-122),none,0.1,ac)
assert(envelope.pitch==35 and envelope.bank==-55,'Must not capture inverted/outside-envelope targets')
envelope=core.new(ac)
local blocked=core.step(envelope,sample(50,70),core.input({83,68}),0.1,ac)
assert(blocked.left+blocked.right<0,'Outward pitch input beyond limit must request recovery')
assert(blocked.right-blocked.left<0,'Outward bank input beyond limit must request recovery')
-- Log regression: the old scaled mixer diluted nose-down demand during a large bank error.
envelope=core.new(ac); envelope.pitch=29.3; envelope.bank=0
local mixed=core.step(envelope,sample(84,40),none,0.1,ac)
assert((mixed.left+mixed.right)/2<=-32,'Roll saturation stole pitch correction')
assert(math.abs(mixed.left)<=40 and math.abs(mixed.right)<=40)
print('Gravity projection, assisted envelope and pitch-priority mixing passed')
-- Powered split: pitch uses engines, roll retains all wing authority.
local powered=core.new(ac)
local demand=core.step(powered,sample(),core.input({83,68,32}),0.1,ac)
assert(demand.pitchControl=='THRUST' and demand.left==-demand.right)
assert(demand.left<0 and demand.pitchAssist>0 and demand.yawAssist==0)
local engines=core.vectorConfig(config.vectoring); engines.authority=ac.thrustAuthority
local outputs=core.thrustMix(config.thrusters,demand.throttle,demand.pitchAssist,demand.yawAssist,engines)
assert(outputs[engines.top]<outputs[engines.bottom],'Pitch-up must reduce top thrust')
assert(outputs[engines.left]==1 and outputs[engines.right]==1,'Roll must not reduce side engines')
local coast=core.step(powered,sample(),core.input({83,68,340}),0.1,ac)
assert(coast.pitchControl=='WINGS' and coast.throttle==0 and coast.left+coast.right>0,'Shift must restore wing pitch control')
local disabled=core.assistConfig(c); disabled.poweredPitch=false
local fallback=core.step(core.new(disabled),sample(),core.input({83,32}),0.1,disabled)
assert(fallback.pitchControl=='WINGS' and fallback.left>0 and fallback.right>0,'Disabled vectoring must retain wing pitch')
local directPowered=core.new(ac)
assert(core.command(directPowered,{action='control',value='DIRECT',confirmed=true},sample(),ac))
local directMix=core.step(directPowered,sample(),core.input({83,68,32}),0.1,ac)
assert(directMix.left==-40 and directMix.right==40 and directMix.pitchAssist==1 and directMix.yawAssist==0)
local directOff=core.step(directPowered,sample(),core.input({83,340}),0.1,ac)
assert(directOff.left==40 and directOff.right==40 and directOff.throttle==0)
print('Powered pitch/roll separation, manual allocation and unpowered/disabled fallback passed')
