local UI=dofile('Powerplant/distributed/ui.lua')
keys={enter=257,backspace=259,escape=256,up=265,down=264}
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local c={white=1,black=2,gray=3,cyan=4,red=5,blue=6,yellow=7,lightGray=8}
local row,col,w,h=1,1,15,29
local writes=0
local lines,ink,fg={},{},c.white
local screen={getSize=function() return w,h end,clear=function() end,
 setCursorPos=function(x,y) assert(x>=1 and x<=w and y>=1 and y<=h); col,row=x,y end,
 setTextColor=function(color) fg=color end,setBackgroundColor=function() end,
 write=function(s)
 assert(#s<=w-col+1,'screen overflow'); writes=writes+1
 local old=lines[row] or string.rep(' ',w)
 lines[row]=old:sub(1,col-1)..s..old:sub(col+#s)
 ink[row]=ink[row] or {}; for x=col,col+#s-1 do ink[row][x]=fg end
end}
local d={phase='master / live',inputBreakers={},breakers={},stages={},voltages={},sourceMeters={},
 maintenance={},config={entryRatio=5,target=2640},nominalTarget=2640}
for _,k in ipairs({'source','input','preStepUp','output'}) do d.voltages[k]={available=false} end
for _,k in ipairs({'current','power'}) do d.sourceMeters[k]={available=false} end
for _,height in ipairs({19,29,40}) do
 h=height; local ui=UI.new(screen,c); ui.draw(d)
 check(ui.event('mouse_click',1,1,2).kind=='emergency','portrait emergency')
 check(ui.event('mouse_click',1,1,h-5).kind=='maintenance','portrait maintenance')
 check(ui.event('mouse_click',1,1,h-4).kind=='resume','portrait reset')
 ui=UI.new(screen,c); ui.draw(d)
 for i=1,3 do ui.event('mouse_click',1,w,3); ui.draw(d) end
 ui.event('mouse_click',1,1,5); check(ui.editing().key=='entryRatio','portrait setting selection')
 ui.event('char','6'); check(ui.event('mouse_click',1,1,2).kind=='emergency','emergency while editing')
 local a=ui.event('key',keys.enter); check(a.kind=='setting' and a.value=='6','keyboard setting entry')
 d.updateReady='distributed-1.1.0'; d.updateCanApprove=true; ui.draw(d)
 check(ui.event('mouse_click',1,1,h-1).kind=='update_apply','portrait Apply')
 check(ui.event('mouse_click',1,w,h-1).kind=='update_later','portrait Later')
 d.updateApplying=true; ui.draw(d)
 check(ui.event('mouse_click',1,1,h-1)==nil,'Apply available during activation')
 d.updateApplying=nil; d.updateReady=nil; ui.draw(d)
 local before=writes; ui.draw(d); check(writes==before,'unchanged frame repainted')
end
-- Overflow advances with elapsed time while button hitboxes stay fixed.
h=29; local now=0; local scrolling=UI.new(screen,c,function() return now end)
d.maintenance={active=true,verified=true,drivesIdle=true}; d.phase='maintenance'
scrolling.draw(d); local initial=lines[h-3]; local controls=lines[h-5]
check(scrolling.animating(),'long status did not request animation')
now=2.5; scrolling.draw(d)
check(lines[h-3]~=initial,'maintenance text did not scroll')
check(lines[h-5]==controls and scrolling.event('mouse_click',1,1,2).kind=='emergency','scrolling changed controls')
local maintenance='MAINTENANCE: contacts open, drives idle'
now=1.5+(#maintenance-w)*.2; scrolling.draw(d)
check(lines[h-3]==maintenance:sub(-w),'maintenance tail never visible')
d.fault='Input breaker input_2 failed to close'; d.tripPending=true
now=20; scrolling.draw(d)
check(lines[h-3]:sub(1,6)=='TRIP: ' and ink[h-3][1]==c.red and ink[h-3][7]==c.red,'trip did not replace maintenance in red')
check(lines[h-3]:sub(7)=='Checking ','pending trip reason missing')
d.tripPending=false; now=21; scrolling.draw(d)
check(lines[h-3]:sub(7)=='Input bre','new fault did not reset scrolling')
now=21+1.5+(#d.fault-(w-6))*.2; scrolling.draw(d)
check(lines[h-3]:sub(1,6)=='TRIP: ' and lines[h-3]:sub(7)==d.fault:sub(-(w-6)),'fault tail not visible or TRIP label scrolled away')
d.fault=nil; scrolling.draw(d)
check(lines[h-3]:sub(1,6)~='TRIP: ','cleared fault stayed on screen')
-- Updates page on the portrait monitor and the standard 51-column terminal.
for _,width in ipairs({15,51}) do
 w=width; h=29; local updates=UI.new(screen,c,function() return 0 end)
 d.updateCanApprove=true; d.updateChecking=nil; d.updateApplying=nil; d.runningVersion='distributed-1.1.9'; d.autoUpdate=false
 updates.draw(d)
 for _=1,2 do updates.event('mouse_click',1,1,width<45 and 3 or 2); updates.draw(d) end -- wrap left through Maintenance to Updates
 local y=width<45 and 5 or 3
 check(updates.event('mouse_click',1,2,y).kind=='update_check','Updates Check now missing')
 check(lines[y+1]:find('1.1.9',1,true),'running version absent from Updates')
 d.updateChecking=true; updates.draw(d)
 check(updates.event('mouse_click',1,2,y)==nil,'busy check button still enabled')
 d.updateChecking=nil; d.updateCanApprove=false; updates.draw(d)
 check(updates.event('mouse_click',1,2,y)==nil,'worker screen allowed update check')
end
for _,width in ipairs({15,36,57,78}) do
 w=width; h=29; local menu=UI.new(screen,c)
 d.maintenanceCanRun=true; d.maintenanceBusy=false; d.maintenanceLogs={}
 menu.draw(d)
 local y=width<45 and h-5 or h-1
 -- Use the visible maintenance button to enter its menu.
 if width<45 then menu.event('mouse_click',1,1,y)
 elseif width<78 then menu.event('mouse_click',1,1,2)
 else menu.event('mouse_click',1,65,2) end
 menu.draw(d)
 local actionRow=width<45 and 6 or 4
 local action=menu.event('mouse_click',1,1,actionRow)
 check(action and action.kind=='maintenance_test' and action.test=='bank_c','maintenance C test missing')
 d.maintenanceBusy=true; menu.draw(d)
 check(menu.event('mouse_click',1,1,actionRow)==nil,'busy maintenance allowed another test')
 d.maintenanceBusy=false
end
for _,size in ipairs({{15,19},{15,29},{36,29},{57,29}}) do
 w,h=size[1],size[2]; d.config={target=2640}
 local keyboard=UI.new(screen,c); keyboard.draw(d)
 for _=1,3 do keyboard.event('mouse_click',1,w,w<45 and 3 or 2); keyboard.draw(d) end
 keyboard.event('mouse_click',1,1,w<45 and 5 or 3); keyboard.draw(d)
 check(keyboard.editing().mode=='choose' and keyboard.editing().layout=='number','numeric input selector missing')
 keyboard.event('mouse_click',1,1,7); keyboard.draw(d)
 keyboard.event('mouse_click',1,1,6); keyboard.draw(d) -- full keyboard
 local kw=math.max(1,math.floor(w/10)); local stride=h>=25 and 2 or 1
 for _,index in ipairs({2,6,4,10}) do keyboard.event('mouse_click',1,1+(index-1)*kw,7) end
 local saved=keyboard.event('mouse_click',1,1,h-2)
 check(saved and saved.kind=='setting' and saved.key=='target' and saved.value=='2640','touch numeric entry failed')
 keyboard.draw(d); keyboard.event('mouse_click',1,1,w<45 and 5 or 3); keyboard.draw(d)
 check(keyboard.editing().mode=='choose' and keyboard.editing().layout=='number','numeric input selector missing')
 keyboard.event('mouse_click',1,1,7); keyboard.draw(d)
 keyboard.event('mouse_click',1,1,6); keyboard.draw(d) -- full keyboard
 local controls=7+5*stride
 keyboard.event('mouse_click',1,1,controls); keyboard.draw(d) -- Shift
 keyboard.event('mouse_click',1,1,7+stride) -- Q
 keyboard.event('mouse_click',1,1,7+4*stride) -- underscore
 keyboard.event('mouse_click',1,1+2*kw,7+4*stride) -- colon
 keyboard.event('mouse_click',1,7,controls) -- space
 check(keyboard.editing().text=='Q_: ','touch letters/punctuation/space failed')
 keyboard.event('mouse_click',1,1,controls+stride)
 check(keyboard.editing().text=='Q_:','touch delete failed')
 check(keyboard.event('mouse_click',1,1,2).kind=='emergency','keyboard hides emergency stop')
 keyboard.event('mouse_click',1,8,h-2)
 check(keyboard.editing()==nil and d.config.target==2640,'touch cancel changed setting')
end
w=57; h=29; d.config={target=2640}
local keypad=UI.new(screen,c); keypad.draw(d)
for _=1,3 do keypad.event('mouse_click',1,w,2); keypad.draw(d) end
keypad.event('mouse_click',1,1,3); keypad.draw(d)
keypad.event('mouse_click',1,1,7); keypad.draw(d)
check(keypad.editing().layout=='number' and keypad.editing().mode=='virtual','numpad was not default for a numeric setting')
keypad.event('mouse_click',1,1,7) -- 7
keypad.event('mouse_click',1,7,7) -- 8
check(keypad.editing().text=='78','numpad entry failed')
keypad.event('mouse_click',1,7,6); keypad.draw(d)
check(keypad.editing().mode=='terminal','terminal input choice failed')
keypad.event('char','9')
check(keypad.event('key',keys.enter).value=='789','terminal input did not preserve virtual entry')
d.workerPassive=true; keypad.draw(d)
check(keypad.event('mouse_click',1,1,2).kind=='emergency','passive worker lacks emergency stop')
check(keypad.event('mouse_click',1,1,h-2)==nil,'passive worker exposed full controls')
d.workerPassive=false; d.canSwitchDisplay=true; d.onTerminal=true; keypad.draw(d)
check(keypad.event('mouse_click',1,38,h-2).kind=='display_switch','display switch button absent')
d.canSwitchDisplay=nil
for _,width in ipairs({45,51,57,78}) do
 w=width; h=29; d.canSwitchDisplay=true; d.onTerminal=false
 local footer=UI.new(screen,c); footer.draw(d)
 check(lines[1]:sub(-15)==' EMERGENCY STOP','emergency label clipped')
 check(footer.event('mouse_click',1,w,1).kind=='emergency','last emergency letter not clickable')
 check(not lines[h-1]:find('Scroll:',1,true),'terminal hints shown on monitor')
 check(footer.event('mouse_click',1,38,h-2).kind=='display_switch','display switch not next to Quit')
 check(footer.event('mouse_click',1,w-1,h-2)==nil,'monitor scroll leaked an external action')
 d.onTerminal=true; footer.draw(d)
 check(lines[h-1]:find('Scroll:',1,true),'terminal hints missing on terminal')
end
d.canSwitchDisplay=nil; d.onTerminal=nil
w=15; h=29
-- The renderer may yield in a monitor write without blocking touch input.
local tasks,actions={},{}
local monitor=setmetatable({setTextScale=function(scale) check(scale==0.5,'monitor scale') end,
 write=function() coroutine.yield('monitor_write') end},{__index=screen})
local env=setmetatable({term=screen,colors=c,peripheral={wrap=function() return monitor end},
 os={pullEvent=function() return coroutine.yield('event') end},
 sleep=function() coroutine.yield('sleep') end,
 parallel={waitForAny=function(...) for _,fn in ipairs({...}) do tasks[#tasks+1]=coroutine.create(fn) end end}}, {__index=_G})
local R={role='master',node={monitor='monitor_0'},config={settings={}},U={},fresh=function() end,updatePeer=function() end,state={},events={},modules={ui=UI},
 trip=function(code) actions[#actions+1]=code end}
assert(loadfile('Powerplant/distributed/interface.lua','t',env))().run(R)
check(coroutine.resume(tasks[1]),'input startup')
local ok,wait=coroutine.resume(tasks[3]); check(ok and wait=='monitor_write','renderer did not yield')
ok,wait=coroutine.resume(tasks[1],'monitor_touch','monitor_0',1,2)
check(ok and wait=='event' and actions[1]=='emergency_stop','touch blocked by monitor drawing')
local powerData={voltages={source={available=true,volts=7140.4}},sourceMeters={current={available=true,amps=11}}}
check(math.abs(UI.sourcePower(powerData)-78544.4)<1e-6,'source power calculation wrong')
powerData.sourceMeters.current.amps=-11
check(math.abs(UI.sourcePower(powerData)-78544.4)<1e-6,'reversed current gauge changed power magnitude')
powerData.sourceMeters.current.available=false
check(UI.sourcePower(powerData)==nil,'unavailable current produced calculated power')
powerData.sourceMeters.current.available=true; powerData.voltages.source.volts=0/0
check(UI.sourcePower(powerData)==nil,'invalid voltage produced power')
powerData.voltages.source.volts=0
check(UI.sourcePower(powerData)==0,'zero voltage not shown as zero power')
powerData.voltages.source.available=false
check(UI.sourcePower(powerData)==nil,'missing source voltage used another voltage')
w=80; h=30; lines={}; ink={}
d.voltages.source={available=true,volts=7140.4}; d.sourceMeters.current={available=true,amps=11}
local powerUI=UI.new(screen,c); powerUI.draw(d)
local powerVisible=false
for _,line in pairs(lines) do if line:find('78.54 kW',1,true) then powerVisible=true end end
check(powerVisible,'calculated source power missing from diagram')
local watts,status=UI.sourcePowerReading(d)
check(math.abs(watts-78544.4)<1e-6 and status=='Calculated','calculated status wrong')
d.sourceMeters.power={available=true,watts=78000}
watts,status=UI.sourcePowerReading(d)
check(watts==78000 and status=='Measured','power gauge not preferred')
d.sourceMeters.power.available=false
watts,status=UI.sourcePowerReading(d)
check(status=='Calculated','failed power gauge did not fall back')
d.sourceMeters.current.available=false
watts,status=UI.sourcePowerReading(d)
check(watts==nil and status=='Unavailable','missing sources did not show unavailable')
print(('PASS: %d portrait monitor UI checks'):format(n))
