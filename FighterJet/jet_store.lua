-- Small bounded two-slot configuration store. Interrupted writes leave the other slot usable.
local M={}
function M.load(path)
    local best,gen={},0
    for _,suffix in ipairs({'.a','.b'}) do
        if fs.exists(path..suffix) then
            local f=fs.open(path..suffix,'r')
            if f then
                local raw=f.readAll(); f.close()
                local ok,v=pcall(textutils.unserialize,raw)
                if ok and type(v)=='table' and type(v.generation)=='number' and v.generation%1==0 and v.generation<9007199254740991 and v.generation>gen and type(v.data)=='table' then
                    best,gen=v.data,v.generation
                end
            end
        end
    end
    return best,gen
end
function M.save(path, data)
    local _,gen=M.load(path)
    local raw=textutils.serialize({generation=gen+1,data=data})
    assert(#raw<4096,'Configuration too large')
    local f,err=fs.open(path..((gen+1)%2==0 and '.a' or '.b'),'w')
    assert(f,err or 'Cannot save configuration'); f.write(raw); f.close()
end
return M
