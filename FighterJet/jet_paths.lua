-- Resolve persistent settings separately from versioned program files.
local M={}
function M.root(directory)
    local root=fs.combine(directory,'../..')
    if fs.exists(fs.combine(root,'.fighter-managed')) then return root end
    return directory
end
function M.module(directory,name)
    local root=M.root(directory)
    local persistent=name=='jet_config' or name=='hardware' or name=='startup_mode'
    local path=fs.combine(persistent and root or directory,name..'.lua')
    return assert(loadfile(path))()
end
return M
