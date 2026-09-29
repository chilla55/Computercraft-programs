-- Copy as startup.lua on each computer, alongside the fighter Lua files.
local dir=fs.getDir(shell.getRunningProgram())
local paths=assert(loadfile(fs.combine(dir,'jet_paths.lua')))()
local c=paths.module(dir,'jet_config')
if os.getComputerID()==c.flightID then
    -- Preview until the installer explicitly selects live in startup_mode.lua.
    local mode='preview'
    local path=fs.combine(paths.root(dir),'startup_mode.lua')
    if fs.exists(path) then mode=assert(loadfile(path))() end
    assert(mode=='preview' or mode=='live','Invalid startup mode')
    shell.run(fs.combine(dir,'flight.lua'),mode)
elseif os.getComputerID()==c.hudID then shell.run(fs.combine(dir,'hud.lua'))
else error('Unconfigured computer ID') end
