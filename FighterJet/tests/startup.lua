-- Execute routing with an old saved startup file present: normal launch must assist.
local actualLoad=loadfile
local start=assert(actualLoad('FighterJet/startup.lua'))
local invoked
fs={getDir=function() return 'FighterJet' end,combine=function(a,b) return a..'/'..b end,
    exists=function() error('Legacy startup mode should no longer be read') end}
shell={getRunningProgram=function() return 'FighterJet/startup.lua' end,
    run=function(...) invoked={...}; return true end}
local id=5
os.getComputerID=function() return id end
loadfile=function(path)
    assert(path=='FighterJet/jet_paths.lua')
    return function() return {module=function() return {flightID=5,hudID=6} end} end
end
start()
assert(invoked[1]=='FighterJet/flight.lua' and invoked[2]=='assist')
start('preview'); assert(invoked[2]=='preview')
start('commission','20'); assert(invoked[2]=='commission' and invoked[3]=='20')
id=6; start(); assert(invoked[1]=='FighterJet/hud.lua')
print('Startup defaults to assistance; explicit diagnostics and HUD routing passed')
