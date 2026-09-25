-- Run the actual commissioning wizard without disk configs or Minecraft.
local base='Powerplant/distributed/'
local common=dofile(base..'common.lua')
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local mapping={inputGauge='in',outputGauge='out',inputBreakers='input-breaker',plusBreaker='plus',minusBreaker='minus',
 gearA='drive-a',gearB='drive-b',gearC='drive-c',variacsA='a1,a2',variacsB='b',variacsC='c'}
local function run(saved,legacy,answers)
 local U=common.copy(common); local written,label,observed
 observed={}
 U.read=function(path) if path=='distributed-node.json' then return saved else return legacy end end
 U.write=function(path,node) written=node end
 U.isolated=function() return true end; U.idle=function() return true end
 local D={modems=function() return {'wired'},{} end,open=function() end,host=function() end,
 find=function(_,role) return role=='regulation' and 2 or 3 end}
 local env=setmetatable({fs={combine=function(a,b) return a..'/'..b end},
 loadfile=function(path) return function() return path:match('common.lua$') and U or D end end,
 os={getComputerID=function() return 1 end},
 peripheral={getNames=function() return {} end}, print=function() end,
 write=function(text) label=text:match('^([^ %[]+)'); observed[label]=text end,
 read=function() return (answers or {})[label] or '' end},{__index=_G})
 local ok,why=pcall(assert(loadfile(base..'app.lua','t',env)),base,'configure','master')
 return ok,written,observed,why
end
local ok,node,shown,why=run(nil,nil,mapping)
check(ok and node~=nil,'fresh wizard failed: '..tostring(why))
check(pcall(common.validate,node.config),'fresh configuration invalid')
check(#node.config.settings.variacsA==2,'parallel variac assignment lost')
check(node.config.settings.thermalGraceSeconds==5 and node.config.settings.maxInputVolts==2800,'protection defaults missing')
check(shown.entryRatio and shown.stepUp and shown.maxInputVolts,'ratios/limits not prompted')
check(not run(nil,nil,{}),'blank required mappings accepted')
local changed=common.copy(mapping); changed.entryRatio='3'; changed.stepUp='4'; changed.target='2400'
local good,custom=run(nil,nil,changed)
check(good and custom.config.settings.entryRatio==3 and custom.config.settings.stepUp==4 and custom.config.settings.target==2400,'custom ratios/target lost')
local goodAgain,again=run(custom,nil,{})
check(goodAgain and again.config.settings.entryRatio==3 and again.config.settings.target==2400 and again.config.revision==2,'saved defaults lost')
check(#again.config.settings.variacsA==2,'saved bank lost')
local old=common.copy(node.config.settings); old.variacsA=nil; old.variacA='legacy-a'; old.target=2500
local imported,import=run(nil,old,{})
check(imported and import.config.settings.variacsA[1]=='legacy-a' and import.config.settings.target==2500,'legacy import broken')
local preferred,current=run(custom,old,{})
check(preferred and current.config.settings.target==2400,'legacy overrides current configuration')
print(('PASS: %d commissioning checks'):format(count))
