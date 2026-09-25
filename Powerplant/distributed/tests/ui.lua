local UI=dofile('Powerplant/distributed/ui.lua')
keys={enter=257,backspace=259,escape=256,up=265,down=264}
local n=0; local function check(v,m) assert(v,m); n=n+1 end
local c={white=1,black=2,gray=3,cyan=4,red=5,blue=6,yellow=7,lightGray=8}
local row,col,w,h=1,1,15,29
local writes=0
local screen={getSize=function() return w,h end,clear=function() end,
 setCursorPos=function(x,y) assert(x>=1 and x<=w and y>=1 and y<=h); col,row=x,y end,
 setTextColor=function() end,setBackgroundColor=function() end,
 write=function(s) assert(#s<=w-col+1,'screen overflow'); writes=writes+1 end}
local d={phase='master / live',inputBreakers={},breakers={},stages={},voltages={},sourceMeters={},
 maintenance={},config={entryRatio=5,target=2640},nominalTarget=2640}
for _,k in ipairs({'source','input','preStepUp','output'}) do d.voltages[k]={available=false} end
for _,k in ipairs({'current','power'}) do d.sourceMeters[k]={available=false} end
for _,height in ipairs({19,29,40}) do
 h=height; local ui=UI.new(screen,c); ui.draw(d)
 check(ui.event('mouse_click',1,1,2).kind=='emergency','portrait emergency')
 check(ui.event('mouse_click',1,1,h-5).kind=='maintenance','portrait maintenance')
 check(ui.event('mouse_click',1,1,h-4).kind=='resume','portrait reset')
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
-- The renderer may yield in a monitor write without blocking touch input.
local tasks,actions={},{}
local monitor=setmetatable({setTextScale=function(scale) check(scale==0.5,'monitor scale') end,
 write=function() coroutine.yield('monitor_write') end},{__index=screen})
local env=setmetatable({term=screen,colors=c,peripheral={wrap=function() return monitor end},
 os={pullEvent=function() return coroutine.yield('event') end},
 sleep=function() coroutine.yield('sleep') end,
 parallel={waitForAny=function(...) for _,fn in ipairs({...}) do tasks[#tasks+1]=coroutine.create(fn) end end}}, {__index=_G})
local R={role='master',node={monitor='monitor_0'},config={settings={}},U={},state={},events={},modules={ui=UI},
 trip=function(code) actions[#actions+1]=code end}
assert(loadfile('Powerplant/distributed/interface.lua','t',env))().run(R)
check(coroutine.resume(tasks[1]),'input startup')
local ok,wait=coroutine.resume(tasks[3]); check(ok and wait=='monitor_write','renderer did not yield')
ok,wait=coroutine.resume(tasks[1],'monitor_touch','monitor_0',1,2)
check(ok and wait=='event' and actions[1]=='emergency_stop','touch blocked by monitor drawing')
print(('PASS: %d portrait monitor UI checks'):format(n))
