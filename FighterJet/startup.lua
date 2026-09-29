local arguments={...}
-- Copy as startup.lua on each computer, alongside the fighter Lua files.
local dir=fs.getDir(shell.getRunningProgram())
local paths=assert(loadfile(fs.combine(dir,'jet_paths.lua')))()
local c=paths.module(dir,'jet_config')
if os.getComputerID()==c.flightID then
    -- Preview until the installer explicitly selects live in startup_mode.lua.
    local mode=arguments[1] or 'preview'
    local path=fs.combine(paths.root(dir),'startup_mode.lua')
    if not arguments[1] and fs.exists(path) then mode=assert(loadfile(path))() end
    assert(mode=='preview' or mode=='live' or (arguments[1] and (mode=='commission' or mode=='thruster')),'Invalid startup mode')
    if arguments[2] then shell.run(fs.combine(dir,'flight.lua'),mode,arguments[2])
    else shell.run(fs.combine(dir,'flight.lua'),mode) end
elseif os.getComputerID()==c.hudID then
    assert(#arguments==0,'Flight testing runs on computer 5 only')
    shell.run(fs.combine(dir,'hud.lua'))
else error('Unconfigured computer ID') end
