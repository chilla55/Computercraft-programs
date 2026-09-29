-- Execute the actual HUD with timed mock peripherals and configuration acknowledgements.
local original={print=print,clock=os.clock,id=os.getComputerID,pull=os.pullEvent,timer=os.startTimer}
local clock,timer,scale,blits,reboots=0,0,1,0,0
local lastRequest,home,ack
local function pause(n)
    local _,main=coroutine.running()
    if main then clock=clock+math.max(n,0.05) else coroutine.yield(math.max(n,0.05)) end
end
sleep=pause; print=function() end; write=function() end
os.clock=function() return clock end
os.getComputerID=function() return 6 end
os.startTimer=function() timer=timer+1; return timer end
os.pullEvent=function() pause(0.25); return 'timer',timer end
local function tasks(all,...)
    local jobs={}
    for _,fn in ipairs({...}) do jobs[#jobs+1]={co=coroutine.create(fn),at=clock} end
    while #jobs>0 do
        assert(clock<20,'HUD did not exit')
        local i=1
        for n=2,#jobs do if jobs[n].at<jobs[i].at then i=n end end
        local job=jobs[i]
        if job.at>clock then pause(job.at-clock) end
        local ok,wait=coroutine.resume(job.co); assert(ok,wait)
        if coroutine.status(job.co)=='dead' then table.remove(jobs,i); if not all then return end
        else job.at=clock+wait end
    end
end
parallel={waitForAny=function(...) return tasks(false,...) end,waitForAll=function(...) return tasks(true,...) end}
local monitor={isColor=function() return true end,getTextScale=function() return scale end,
    setTextScale=function(v) scale=v end,getSize=function() return 15,10 end,
    setBackgroundColor=function() end,setTextColor=function() end,clear=function() end,
    setCursorPos=function() end,write=function() end,
    blit=function(a,b,c) assert(#a==15 and #b==15 and #c==15); blits=blits+1 end}
peripheral={wrap=function() return monitor end,call=function(name,method)
    if method=='getID' then assert(name=='right'); return 5 end
    if method=='reboot' then assert(name=='right'); reboots=reboots+1; return end
    assert(not method:find('set') and method~='pushItems','HUD must not write flight hardware')
    if method=='getHeight' then return 100 end
    if method=='getVelocity' then return 20 end
    if method=='getAngles' then return {0,0} end
    if method=='getStatus' then return {throttle=0} end
    if method=='list' then return {{name='minecraft:coal',count=64}} end
    if method=='getTargetDistance' then return -1 end
    if method=='getPosition' then return {x=1,y=100,z=2,space='world',dimension='minecraft:overworld'} end
    if method=='getTracks' then return {} end
    if method=='getRange' then return 250 end
    error('Unexpected method '..method)
end}
fs={exists=function() return false end,getDir=function() return 'FighterJet' end,combine=function(a,b) return a..'/'..b end}
shell={getRunningProgram=function() return 'FighterJet/hud.lua' end}
colors={black=32768,white=1}
local sequence=0
rednet={open=function() end,receive=function()
    pause(0.25); sequence=sequence+1
    return 5,{kind='status',boot='test',ticket=sequence,revision=home and 1 or 0,nextSequence=lastRequest and lastRequest.sequence+1 or 1,
        healthy=true,mode='MANUAL',live=false,altitude=150,home=home,ack=ack}
end,send=function(id,m)
    assert(id==5)
    if m.kind=='command' then
        assert(not lastRequest,'Request unexpectedly replayed')
        lastRequest=m; home=m.command.value
        assert(m.command.action=='home' and home.x==12 and home.y==90 and home.z==34)
        ack={sequence=m.sequence,ok=true,message='Accepted'}
    end
    return true
end}
local readCount=0
read=function()
    readCount=readCount+1
    pause(1)
    if readCount==1 then return 'home 12 90 34' end
    if readCount==2 then assert(reboots==0,'HUD must never automatically reboot flight'); return 'restart5' end
    return 'quit'
end
assert(loadfile('FighterJet/hud.lua'))()
assert(lastRequest and reboots==1 and blits>10 and scale==1)
print,os.clock,os.getComputerID,os.pullEvent,os.startTimer=original.print,original.clock,original.id,original.pull,original.timer
print('Actual HUD runtime: direct reads, rendering, acknowledged home entry, explicit-only reboot and cleanup passed')
