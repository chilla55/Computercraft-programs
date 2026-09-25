local scenario=(...) or 'normal'
-- Execute the real launcher with cooperative tasks, fake peripherals and monitor events.
local path='Powerplant/controller/plant_controller.lua'
local f=assert(io.open(path)); local source=f:read('*a'); f:close()
local t,sent,screenWrites=0,{},0
local c={version=1,monitor='monitor_0',modem='back',voltageGauge='grid_v',currentGauge='',
 nominalVoltage=2640,gridMinVoltage=2376,gridMaxVoltage=2904,currentLimitAmps=0,
 sampleMaxAgeMs=1000,nodeTimeoutMs=2000,upstreamId=20,transformers={{id=7,name='Transformer'}},generators={},
 transmission={inputGauge='',outputGauge='',ratio=0}}
local monitor={setTextScale=function() end,getSize=function() return 60,24 end,
 setBackgroundColor=function() end,setTextColor=function() end,clear=function() end,
 setCursorPos=function(x,y) assert(x>=1 and x<=60 and y>=1 and y<=24,'UI out of bounds') end,
 write=function(s) assert(#s<=60,'UI row overflow'); screenWrites=screenWrites+1 end}
local devices={back={isWireless=function() return true end},monitor_0=monitor,grid_v={voltage=function() return 2640 end}}
if scenario=='wired' then devices.back.isWireless=function() return false end end
if scenario=='late_modem' then devices.back=nil end
if scenario=='late_monitor' then devices.monitor_0=nil end
local modemOpened=false
local remote={enabled=scenario=='autonomous_exit',lastSeq=-1}; local lastStatus=-1
local env=setmetatable({}, {__index=_G})
env.colors={black=1,white=2,gray=3,cyan=4,lime=5,red=6,orange=7,lightGray=8,yellow=9,green=10}
env.keys={q=1,space=2,left=3,right=4,tab=5}
env.shell={getRunningProgram=function() return path end}
env.fs={getDir=function(p) return p:match('^(.*)/') end,combine=function(a,b) return a..'/'..b end,
 exists=function() return true end,open=function() return {readAll=function() return 'CONFIG' end,close=function() end} end}
env.textutils={unserializeJSON=function() return c end}
env.loadfile=function(p) local h=assert(io.open(p)); local code=h:read('*a'); h:close(); return load(code,'@'..p,'t',env) end
env.peripheral={wrap=function(name) return devices[name] end}
env.sleep=function(dt) coroutine.yield(dt) end
env.print=function() end; env.printError=function(s) error(s,0) end
local events={{(scenario=='late_modem' or scenario=='late_monitor') and 1.75 or .75,'monitor_touch','monitor_0',2,22},{2,'monitor_touch','monitor_0',40,24},{3,'key',1}}
if scenario=='autonomous_exit' then events={{.75,'monitor_touch','monitor_0',2,22},{3,'key',1}} end
env.os={epoch=function() return math.floor(t*1000+.5) end,getComputerID=function() return 1 end,
 pullEvent=function()
  local e=table.remove(events,1); assert(e,'No input event'); if e[1]>t then coroutine.yield(e[1]-t) end
  return table.unpack(e,2)
 end}
env.rednet={close=function() modemOpened=false end,isOpen=function() return modemOpened end,open=function(name) assert(name=='back'); modemOpened=true end,
 send=function(id,m,protocol)
  sent[#sent+1]={id=id,m=m,protocol=protocol,time=t}
  if id==20 and scenario=='upstream_down' then error('Upstream send failure',0) end
  if id==7 then
    assert(protocol=='powerplant.regulator.v1' and m.node==7 and m.session=='remote-session','bad dispatch envelope')
    assert(m.seq>remote.lastSeq,'non-increasing dispatch sequence')
    remote.lastSeq=m.seq
    if m.type=='dispatch' then remote.enabled=m.enabled end
  end
  return true
 end,
 receive=function(_,timeout)
  if not modemOpened or not devices.back then coroutine.yield(timeout); return nil end
  if t-lastStatus>=.49 then
    lastStatus=t
    return 7,{schema=1,type='status',node=7,session='remote-session',sentAt=math.floor(t*1000+.5),
      autonomousFallback=scenario=='autonomous_exit',lastSeq=remote.lastSeq,phase=remote.enabled and 'live' or 'standby',enabled=remote.enabled,
      inputVoltage=1500,outputVoltage=2640,nominalTarget=2640,target=2640,
      breakers={{closed=remote.enabled},{closed=remote.enabled}}},'powerplant.regulator.v1'
  end
  coroutine.yield(timeout); return nil
 end}
env.parallel={waitForAny=function(...)
 local tasks={}; for _,fn in ipairs({...}) do tasks[#tasks+1]={co=coroutine.create(fn),wake=t} end
 while true do
  local nextWake=math.huge
  for _,task in ipairs(tasks) do
   if task.wake<=t then
    local ok,delay=coroutine.resume(task.co); assert(ok,delay)
    if coroutine.status(task.co)=='dead' then return end
    task.wake=t+(delay or .01)
   end
   nextWake=math.min(nextWake,task.wake)
  end
  t=nextWake
  if scenario=='late_modem' and t>=1.5 then devices.back={isWireless=function() return true end} end
  if scenario=='late_monitor' and t>=1.5 then devices.monitor_0=monitor end
  assert(t<8,'Runtime failed to stop')
 end
end}
assert(load(source,'@'..path,'t',env))('run')
local enabled,disabled,telemetry=false,false,false
for _,event in ipairs(sent) do
 if event.id==7 and event.m.enabled then enabled=true end
 if event.id==7 and event.time>=2 and event.m.enabled==false then disabled=true end
 if event.id==20 and event.m.type=='plant_status' then telemetry=true; assert(event.m.grid.voltage==nil or event.m.grid.voltage==2640) end
end
if scenario=='autonomous_exit' then
 assert(enabled and remote.enabled and screenWrites>0,'supervisor exit stopped autonomous unit')
 local released=false; for _,event in ipairs(sent) do if event.id==7 then assert(event.m.enabled~=false,'unsolicited disable'); if event.m.type=='release' then released=true end end end
 assert(released,'supervisor exit did not release control')
elseif scenario=='wired' then assert(#sent==0 and screenWrites>0,'Wired rednet used or local monitor stopped')
else assert(enabled and disabled and telemetry and screenWrites>0 and not remote.enabled,'Runtime controls/telemetry/cleanup failed: '..scenario) end
print('PASS: launcher/monitor/rednet integration ('..scenario..')')
