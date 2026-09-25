-- Model CraftOS: shell exists in the program environment, not the global one.
local n=0; local function check(v,m) assert(v,m); n=n+1 end
for _,active in ipairs({false,'distributed-1.1.7'}) do
 local program={getRunningProgram=function() return 'transformer/transformer.lua' end,dir=function() return '' end}
 local env=setmetatable({shell=program,
 fs={getDir=function(path) return path:match('^(.*)/') or '' end,combine=function(a,b) return a..'/'..b end,
 exists=function(path) return active and path=='transformer/active-release.json' end,
 open=function() return {readAll=function() return 'pointer' end,close=function() end} end},
 textutils={unserializeJSON=function() return {version=active} end}},{__index=_G})
 local expected=active and 'transformer/releases/'..active or 'transformer'
 env.loadfile=function(path,mode,passed)
  check(path==expected..'/app.lua','wrong release path')
  -- Omitting the environment deliberately loses shell, reproducing the bug.
  return assert(load('return function(root,command,role,context) assert(shell); return root,command,role,context end','app',mode,passed or _G))()
 end
 local root,command,role,context=assert(loadfile('Powerplant/distributed/transformer.lua','t',env))('configure','master')
 check(root==expected and command=='configure' and role=='master','launch arguments lost')
 check(context.launcher=='transformer/transformer.lua' and context.working=='','stable launcher context missing')
end
print(('PASS: %d launcher environment checks'):format(n))
