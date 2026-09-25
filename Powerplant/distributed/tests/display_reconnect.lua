local checks=0; local function check(v,m) assert(v,m); checks=checks+1 end
local function scenario(configured,names)
 local tasks,saved,selected,actions={},nil,nil,{}
 local terminal={getSize=function() return 51,19 end,clear=function() end,setCursorPos=function() end}
 local monitor={getSize=function() return 57,29 end,setTextScale=function() end}
 local R={role='master',node={monitor=configured},config={settings={}},state={},events={},now=function() return 0 end,
 fresh=function() end,updatePeer=function() end,trip=function(code) actions[#actions+1]=code end,
 U={roles={},read=function() end,write=function(_,node) saved=node.monitor end},modules={ui={new=function(screen)
  selected=select(1,screen.getSize())
  return {draw=function() end,animating=function() return false end,editing=function() end,
  event=function(event) if event=='switch' then return {kind='display_switch'} end; if event=='mouse_click' then return {kind='emergency'} end end}
 end}}}
 local env=setmetatable({term=terminal,colors={},print=function() end,
 peripheral={getNames=function() return names end,hasType=function() return true end,
 wrap=function(name) for _,n in ipairs(names) do if name==n then return monitor end end end},
 os={pullEvent=function() return coroutine.yield() end},sleep=function() coroutine.yield() end,
 parallel={waitForAny=function(...) for _,fn in ipairs({...}) do tasks[#tasks+1]=coroutine.create(fn) end end}},{__index=_G})
 assert(loadfile('Powerplant/distributed/interface.lua','t',env))().run(R)
 assert(coroutine.resume(tasks[3])); assert(coroutine.resume(tasks[1]))
 return R,saved,selected,tasks,actions
end
local R,saved,width,tasks,actions=scenario('old_monitor',{'new_monitor'})
check(R.node.monitor=='new_monitor' and saved=='new_monitor' and width==57,'replacement monitor was not selected and saved')
assert(coroutine.resume(tasks[1],'monitor_touch','new_monitor',1,1))
check(actions[1]=='emergency_stop','touch events on replacement monitor did not reach UI')
assert(coroutine.resume(tasks[1],'switch')); assert(coroutine.resume(tasks[3]))
check(R.displayTerminal==true,'UI did not switch to terminal')
assert(coroutine.resume(tasks[1],'monitor_touch','new_monitor',1,2))
check(actions[2]=='emergency_stop','inactive monitor lost emergency stop')
assert(coroutine.resume(tasks[1],'monitor_touch','new_monitor',1,4)); assert(coroutine.resume(tasks[3]))
check(R.displayTerminal==false,'inactive monitor could not restore UI')
R,saved,width=scenario(nil,{'new_monitor'})
check(R.node.monitor==nil and saved==nil and width==51,'explicit headless mode was overridden')
R,saved,width=scenario('old_monitor',{'one','two'})
check(R.node.monitor=='old_monitor' and saved==nil and width==51,'ambiguous monitor was selected')
R,saved,width=scenario('old_monitor',{})
check(width==51 and saved==nil,'missing monitor did not fall back to terminal')
print(('PASS: %d display reconnect checks'):format(checks))
