local arguments={...}
-- Copy as startup.lua on each computer, alongside the fighter Lua files.
local dir=fs.getDir(shell.getRunningProgram())
local paths=assert(loadfile(fs.combine(dir,'jet_paths.lua')))()
if arguments[1]=='remap' then
    assert(os.getComputerID()==5 or os.getComputerID()==6,'Run remap on computer 5 or 6')
    local map=paths.remap(dir,table.unpack(arguments,2))
    print('Saved rear-view thruster mapping:')
    print('Bottom '..map.bottom..'; top '..map.top)
    print('Left '..map.left..'; right '..map.right)
    print('No actuator writes. Restart the program to use this mapping.')
    return
end
local c=paths.module(dir,'jet_config')
if os.getComputerID()==c.flightID then
    -- Normal startup always assists; explicit diagnostics remain available.
    -- Legacy startup_mode.lua is preserved on disk but no longer selects flight mode.
    local mode=arguments[1] or 'assist'
    assert(mode=='preview' or mode=='live' or mode=='assist' or mode=='commission' or mode=='thruster','Invalid startup mode')
    if arguments[2] then shell.run(fs.combine(dir,'flight.lua'),mode,arguments[2])
    else shell.run(fs.combine(dir,'flight.lua'),mode) end
elseif os.getComputerID()==c.hudID then
    assert(#arguments==0,'Flight testing runs on computer 5 only')
    shell.run(fs.combine(dir,'hud.lua'))
else error('Unconfigured computer ID') end
