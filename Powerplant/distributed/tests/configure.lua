-- Run the actual commissioning wizard without disk configs or Minecraft.
local base='Powerplant/distributed/'
local common=dofile(base..'common.lua')
local count=0; local function check(v,m) assert(v,m); count=count+1 end
local mapping={inputGauge='in',outputGauge='out',inputBreakers='input-breaker',plusBreaker='plus',minusBreaker='minus',
 gearA='drive-a',gearB='drive-b',gearC='drive-c',variacsA='a1,a2',variacsB='b',variacsC='c'}
local function run(saved,legacy,answers,startup,role)
 local files=startup or {}
 local U=common.copy(common); local written,label,observed
 observed={}
 U.read=function(path) if path=='distributed-node.json' then return saved else return legacy end end
 U.write=function(path,node) written=node end
 U.isolated=function() return true end; U.idle=function() return true end
 local D={modems=function() return {'wired'},{} end,open=function() end,host=function() end,
 find=function(_,role) return role=='master' and 1 or role=='regulation' and 2 or 3 end}
 local env=setmetatable({fs={combine=function(a,b) return a..'/'..b end,
 exists=function(path) return files[path]~=nil end,
 open=function(path) return {write=function(bytes) files[path]=bytes end,close=function() end} end,
 makeDir=function(path) files[path]={} end,getName=function(path) return path:match('[^/]+$') end,
 move=function(from,to) assert(files[from] and not files[to]); files[to]=files[from]; files[from]=nil end},
 shell={getRunningProgram=function() return 'transformer-fixed/transformer.lua' end,
 resolve=function(path) return path end,dir=function() return '' end},
 loadfile=function(path) return function() return path:match('common.lua$') and U or D end end,
 os={getComputerID=function() return role=='regulation' and 2 or role=='protection' and 3 or 1 end},
 rednet={send=function() end,receive=function() return 1,{kind='config_bundle',data={config=saved.config}} end},
 peripheral={getNames=function() return {} end}, print=function() end,
 write=function(text)
   label=text:match('^(.-) %[')
   for key,field in pairs(U.fields) do if field.label==label then label=key; break end end
   observed[label]=text
 end,
 read=function() return (answers or {})[label] or '' end},{__index=_G})
 local ok,why=pcall(assert(loadfile(base..'app.lua','t',env)),base,'configure',role or 'master')
 return ok,written,observed,why,files
end
local ok,node,shown,why,files=run(nil,nil,mapping)
check(ok and node~=nil,'fresh wizard failed: '..tostring(why))
check(files['/startup.lua'] and files['/startup.lua']:find('/transformer-fixed/transformer.lua',1,true),'startup did not use stable launcher')
local called,dir
assert(load(files['/startup.lua'],'startup','t',{shell={setDir=function(d) dir=d end,run=function(path,command) called={path,command} end}}))()
check(dir=='' and called[2]=='run','startup did not restore config directory/run role')
check(pcall(common.validate,node.config),'fresh configuration invalid')
check(#node.config.settings.variacsA==2,'parallel variac assignment lost')
check(node.config.settings.thermalGraceSeconds==5 and node.config.settings.maxInputVolts==2800,'protection defaults missing')
check(shown.entryRatio and shown.stepUp and shown.maxInputVolts,'ratios/limits not prompted')
check(shown.inputGauge:find('Voltage entering variacs',1,true),'raw inputGauge label shown')
check(shown.sourceGauge:find('Generator / source voltage',1,true),'source gauge unclear')
for _,key in ipairs(common.editable) do check(common.fields[key] and #common.fields[key].help>0,'undocumented setting '..key) end
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
local existing={['/startup.lua']='old program',['/startup']={legacy='old folder'}}
local updated,_,_,_,backups=run(custom,nil,{},existing)
check(updated and backups['/transformer-startup-backup-1/startup.lua']=='old program' and type(backups['/transformer-startup-backup-1/startup'])=='table','startup backup missing')
local declined={['Back up existing startup and enable transformer autostart? yes/no']='no'}
local untouched,_,_,_,kept=run(custom,nil,declined,{['/startup.lua']='keep me'})
check(untouched and kept['/startup.lua']=='keep me','declined startup replacement ignored')
for _,role in ipairs({'regulation','protection'}) do
 local worker,savedWorker,_,why,boot=run(node,nil,{},nil,role)
 check(worker and savedWorker.role==role and boot['/startup.lua'],'worker autostart failed: '..tostring(why))
end
print(('PASS: %d commissioning checks'):format(count))
