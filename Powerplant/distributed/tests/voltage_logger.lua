local count=0
local function check(v,m) assert(v,m); count=count+1 end
local function run(terminate,zeroStop)
 local now,calls,closed,flushed=1000,0,false,0
 local rows={}
 local env=setmetatable({},{__index=_G})
 env.os={epoch=function() return now end}
 env.print=function() end
 env.sleep=function() now=now+50 end
 env.peripheral={getNames=function() return {'gauge','breaker'} end,
  getMethods=function(n) return n=='gauge' and {'voltage'} or {'close'} end,
  call=function(name,method)
   check(name=='gauge' and method=='voltage','unexpected hardware call')
   calls=calls+1; now=now+50
   if terminate and calls==4 then error('Terminated',0) end
   if calls==2 then error('Gauge "missing"',0) end
   if calls==3 then return 0/0 end
   if zeroStop then
    if calls==1 or calls==6 then return 0 end
    if calls==4 then return -1056 end
   end
   return calls==1 and -1056 or 1700
  end}
 env.fs={exists=function(p) return p=='/voltage-logs' end,
  getFreeSpace=function() return 20480 end,
  open=function(path,mode)
   check(mode=='w' and path:match('^/voltage%-logs/pre%-exit%-%d+%.csv$'),'bad log path')
   return {writeLine=function(line) rows[#rows+1]=line end,flush=function() flushed=flushed+1 end,close=function() closed=true end}
  end}
 env.parallel={waitForAny=function(sample) sample() end}
 assert(loadfile('Powerplant/distributed/tools/log-pre-exit-voltage.lua','t',env))('gauge')
 check(closed and flushed>=2,'log not flushed/closed')
 if zeroStop then
  check(#rows==4 and rows[2]:find(',-1056,',1,true) and rows[4]:find(',0,',1,true),'trigger or final zero sample wrong')
  return calls
 end
 check(rows[2]:find(',-1056,',1,true),'signed voltage was lost')
 check(rows[3]:find('"Gauge ""missing"""',1,true),'peripheral error not escaped')
 check(rows[4]:find('Invalid voltage',1,true),'invalid voltage not logged')
 local bytes=0; for _,row in ipairs(rows) do bytes=bytes+#row+1 end
 check(bytes<=4096,'disk budget exceeded')
 return calls
end
check(run(false)>20,'recorder did not continue after read errors')
check(run(true)==4,'termination did not stop recorder')
check(run(false,true)==6,'zero voltage did not stop recording')
print(('PASS: %d standalone voltage logger checks'):format(count))
