local files,objects={},{}
fs={exists=function(p) return files[p]~=nil end,open=function(p,mode)
    local raw=mode=='w' and '' or files[p]
    return {write=function(v) raw=raw..v end,readAll=function() return raw end,close=function() files[p]=raw end}
end}
textutils={serialize=function(v) objects[#objects+1]=v; return tostring(#objects) end,
    unserialize=function(s) return objects[tonumber(s)] end}
local store=dofile('FighterJet/jet_store.lua')
local empty,gen=store.load('state'); assert(gen==0 and next(empty)==nil)
store.save('state',{altitude=100}); store.save('state',{altitude=120})
assert(store.load('state').altitude==120)
files['state.a']='partial write'
assert(store.load('state').altitude==100,'Must recover prior valid slot')
store.save('state',{altitude=130})
assert(store.load('state').altitude==130)
assert(files['state.a'] and files['state.b'])
print('Bounded settings storage and interrupted-write recovery tests passed')
