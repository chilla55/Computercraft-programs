-- Resolve persistent settings separately from versioned program files.
local M={}
function M.root(directory)
    local root=fs.combine(directory,'../..')
    if fs.exists(fs.combine(root,'.fighter-managed')) then return root end
    return directory
end
local function validate(map)
    assert(type(map)=='table' and map.schema==1,'Invalid saved thruster map; run remap again')
    local seen={}
    for _,side in ipairs({'bottom','top','left','right'}) do
        local n=map[side]
        assert(type(n)=='string' and n:match('^thruster_%d+$') and not seen[n],'Invalid/duplicate thruster in map')
        seen[n]=true
    end
    return map
end
function M.remap(directory,...)
    local args={...}
    assert(#args==4,'Usage: /fighter/run remap BOTTOM TOP LEFT RIGHT')
    local map={schema=1}
    for i,side in ipairs({'bottom','top','left','right'}) do
        local name=tostring(args[i])
        map[side]=name:match('^%d+$') and ('thruster_'..name) or name
    end
    validate(map)
    -- Discovery only: remapping never fires or reconfigures an actuator.
    for _,side in ipairs({'bottom','top','left','right'}) do
        local name=map[side]
        assert(peripheral.isPresent(name),'Missing '..name)
        local methods={}; for _,method in ipairs(peripheral.getMethods(name) or {}) do methods[method]=true end
        assert(methods.getThrottle and methods.setThrottle,'Not a thruster: '..name)
    end
    local store=assert(loadfile(fs.combine(directory,'jet_store.lua')))()
    store.save(fs.combine(M.root(directory),'thruster_map'),map)
    return map
end
function M.module(directory,name)
    local root=M.root(directory)
    local persistent=name=='jet_config' or name=='hardware' or name=='startup_mode'
    local path=fs.combine(persistent and root or directory,name..'.lua')
    local value=assert(loadfile(path))()
    if name=='jet_config' or name=='hardware' then
        local prefix=fs.combine(root,'thruster_map')
        if fs.exists(prefix..'.a') or fs.exists(prefix..'.b') then
            local store=assert(loadfile(fs.combine(directory,'jet_store.lua')))()
            local map=validate(store.load(prefix))
            value.thrusters={map.bottom,map.top,map.right,map.left}
            if name=='jet_config' and value.vectoring~=false then
                value.vectoring=value.vectoring or {}
                for _,side in ipairs({'bottom','top','left','right'}) do value.vectoring[side]=map[side] end
            elseif name=='hardware' then
                value.thrusterPositions={bottom=map.bottom,top=map.top,left=map.left,right=map.right}
            end
        end
    end
    return value
end
return M
