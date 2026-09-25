-- Terminal and input checks without Minecraft peripherals.
local UI=dofile('Powerplant/regulator/regulator_ui.lua')
keys={enter=257,backspace=259,escape=256,up=265,down=264}
local count=0
local function check(v,m) assert(v,m); count=count+1 end
local c={white=1,black=2,gray=3,cyan=4,red=5,blue=6,yellow=7,lightGray=8}
local row,col,lines=1,1,{}
local writes,clears=0,0
local screen={getSize=function() return 51,19 end,clear=function() lines={}; clears=clears+1 end,
 setCursorPos=function(x,y) col,row=x,y end,setTextColor=function() end,setBackgroundColor=function() end,
 write=function(s) writes=writes+1; assert(row<=19 and #s<=52-col,'screen overflow'); lines[row]=(lines[row] or '')..s end}
local ui=UI.new(screen,c)
local d={phase='maintenance',inputBreakers={},breakers={},stages={},voltages={},sourceMeters={},
 maintenance={active=true,verified=true,drivesIdle=true},config={target=2640,entryRatio=5},message='Ready'}
for _,k in ipairs({'source','input','preStepUp','output'}) do d.voltages[k]={available=false} end
for _,k in ipairs({'current','power'}) do d.sourceMeters[k]={available=false} end
ui.draw(d)
check(ui.event('char','e').kind=='emergency','keyboard emergency')
check(ui.event('mouse_click',1,50,1).kind=='emergency','mouse emergency')
ui.event('mouse_click',1,32,2); ui.draw(d) -- Settings tab
ui.event('mouse_click',1,1,4) -- target row
ui.event('char','2'); ui.event('char','5'); ui.event('char','0'); ui.event('char','0')
local edit=ui.event('key',keys.enter)
check(edit.kind=='setting' and edit.key=='target' and edit.value=='2500','editable target')
ui.draw(d); ui.event('mouse_click',1,1,3)
check(ui.event('mouse_click',1,50,1).kind=='emergency','emergency while editing')
ui.event('key',keys.escape)
check(ui.event('char','q').kind=='stop','quit shortcut')
for _,x in ipairs({1,12,22,32}) do ui.event('mouse_click',1,x,2); ui.draw(d); ui.event('mouse_scroll',1); ui.draw(d) end
check(lines[19]~=nil,'footer missing')
-- Identical frames must not touch the terminal; editing should not clear it.
ui.draw(d)
local beforeWrites,beforeClears=writes,clears
ui.draw(d)
check(writes==beforeWrites and clears==beforeClears,'unchanged frame repainted')

-- Exercise the actual controller input loop while its sampling coroutine is
-- blocked inside a simulated native peripheral call. All input must survive.
do
  local f=assert(io.open('Powerplant/regulator/transformer_controller.lua')); local source=f:read('*a'); f:close()
  local start=assert(source:find('local function userInterface()',1,true))
  local finish=assert(source:find('local function telemetry()',start,true))
  local tasks,actions,queued={},{},{}
  local env=setmetatable({uiActive=true,C={target=2640,entryRatio=5},nominalTarget=2640,phase='live',
    uiMessage='',maintenanceRequested=false,emergencyStopped=false,reloadRequested=false,
    term=screen,colors=c,
    fs={combine=function(a,b) return b end,getDir=function() return '' end},
    shell={getRunningProgram=function() return 'controller' end},
    loadfile=function() return function() return UI end end,
    uiSnapshot=function() coroutine.yield('native_wait'); return d end,
    uiAction=function(action) actions[#actions+1]=action end,
    os={pullEvent=function() return coroutine.yield('event') end,
      queueEvent=function(name) queued[#queued+1]=name end},
    sleep=function() coroutine.yield('sleep') end,
    parallel={waitForAny=function(...) for _,fn in ipairs({...}) do tasks[#tasks+1]=coroutine.create(fn) end end}}, {__index=_G})
  assert(load(source:sub(start,finish-1)..'return userInterface','ui-loop','t',env))()()
  local ok,wait=coroutine.resume(tasks[1]); check(ok and wait=='event','input did not start immediately')
  ok,wait=coroutine.resume(tasks[2]); check(ok and wait=='native_wait','sampler did not block as expected')
  local function input(...)
    local success,filter=coroutine.resume(tasks[1],...)
    check(success and filter=='event','input blocked or failed: '..tostring(filter))
  end
  input('mouse_click',1,32,2)
  input('mouse_click',1,1,4)
  input('char','2'); input('char','5'); input('char','0'); input('char','0')
  input('key',keys.enter)
  check(actions[1].kind=='setting' and actions[1].value=='2500','typing lost while sample blocked')
  input('mouse_click',1,50,1)
  check(actions[2].kind=='emergency','emergency delayed by sampler')
  ok,wait=coroutine.resume(tasks[2]); check(ok and wait=='sleep' and queued[1]=='regulator_ui_update','snapshot not published')
  input('regulator_ui_update')
end
print(('PASS: %d local UI checks'):format(count))
