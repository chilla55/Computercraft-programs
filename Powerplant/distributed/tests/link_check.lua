local count=0
local function check(v,m) assert(v,m); count=count+1 end
local function run(messages)
 local time,report=0,nil
 local config={ids={master=0,regulation=1,protection=2},revision=8,cluster='plant'}
 local env=setmetatable({},{__index=_G})
 env.os={epoch=function() return time end,getComputerID=function() return 0 end}
 env.print=function() end
 env.fs={combine=function(a,b) return a..'/'..b end,exists=function() return false end,
 open=function(path,mode) return {readAll=function() return 'config' end,write=function() check(path=='/config/transformer-link-check.json','modified another file') end,close=function() end} end}
 env.textutils={unserializeJSON=function() return {role='master',modem='back',config=config} end,serializeJSON=function(v) report=v; return 'report' end}
 env.peripheral={wrap=function(name) check(name=='back','accessed a hardware component'); return {isWireless=function() return false end} end}
 env.rednet={isOpen=function() return true end,open=function() end,close=function() error('closed an already open modem') end,
 receive=function() time=time+500; local entry=table.remove(messages,1); if entry then return entry[1],entry[2] end end,
 send=function() error('sent control traffic') end}
 env.loadfile=function(path)
  return function()
   if path:find('sha256',1,true) then return function() return 'expected' end end
   return {protocol='transformer.cluster.v1',release='distributed-1.1.24',canonical=function() return '' end}
  end
 end
 assert(loadfile('Powerplant/distributed/tools/check-transformer-link.lua','t',env))()
 return report
end
local report=run({
 {1,{kind='hello',role='regulation',release='distributed-1.1.24',revision=8,digest='expected',sentAt=0}},
 {1,{kind='heartbeat',role='regulation',release='distributed-1.1.24',revision=8,digest='expected',sentAt=500,data={phase='stopped',latched=true}}},
 {2,{kind='heartbeat',role='protection',release='distributed-1.1.24',revision=8,digest='different',sentAt=1000,data={message='Configuration requires maintenance'}}},
 {7,{kind='hello',role='regulation',release='distributed-1.1.25',revision=7,digest='different',sentAt=1500}}
})
check(report.peers['1:regulation'].configMatches and report.peers['1:regulation'].messages==2,'healthy peer misreported')
check(report.peers['2:protection'].revisionMatches and not report.peers['2:protection'].configMatches,'equal revision/different config not detected')
check(report.peers['2:protection'].message=='Configuration requires maintenance','sync rejection omitted')
check(not report.peers['7:regulation'].idMatches and not report.peers['7:regulation'].releaseMatches,'wrong ID/version not detected')
check(next(run({}).peers)==nil,'silent network invented a peer')
print(('PASS: %d passive link inspection checks'):format(count))
