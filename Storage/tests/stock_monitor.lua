local m = dofile('Storage/stock_monitor.lua')
local function eq(a,b) assert(a == b, tostring(a)..' ~= '..tostring(b)) end
local function vault(slots, items, limit)
    return {size=function() return slots end, list=function() return items end,
        getItemLimit=function(i) return type(limit)=='table' and limit[i] or limit end}
end
local devices = {
    a=vault(4,{[2]={name="minecraft:stone",count=64},[4]={name="minecraft:stone",count=32}},64),
    b=vault(2,{[2]={name="minecraft:stone",count=16}},{64,16}),
    ticker={stock=function() return {{name="minecraft:stone",count=500},{name="minecraft:stone",count=12}} end,
        list=function() error('Do not read payment inventory') end},
}
local config={vaults={'a','b'},ticker='ticker'}
local function wrap(name) return devices[name] end
local r=m.sample(config,wrap)
eq(r.current,112); eq(r.capacity,336); eq(r.slots,6); eq(r.occupied,3)
eq(r.network,512); eq(r.ratio,1/3); eq(m.format(1234567),'1,234,567')
devices.a=nil
local ok,err=pcall(m.sample,config,wrap)
assert(not ok and err:find('Vault offline'))
devices.a=vault(4,{},64); devices.ticker=nil
r=m.sample(config,wrap); eq(r.current,16); assert(r.networkError and not r.network)
assert(not pcall(m.sample,{vaults={'a','a'}},wrap))
assert(not pcall(m.sample,{vaults={}},wrap))
devices.a=vault(0,{},64)
r=m.sample({vaults={'a'}},wrap); eq(r.ratio,0); eq(r.capacity,0)
devices.a=vault(1,{{name="minecraft:stone",count=64}},64)
eq(m.sample({vaults={'a'}},wrap).ratio,1)
devices.a=vault(1,{{name="minecraft:stone",count=-1}},64)
assert(not pcall(m.sample,{vaults={'a'}},wrap))
colors={black=1,white=2,cyan=3,red=4,orange=5,lime=6,lightGray=7}
local function screen(w,h)
    local lines,x,y={},1,1
    return {getSize=function() return w,h end,
        setBackgroundColor=function() end,setTextColor=function() end,
        clear=function() for i=1,h do lines[i]='' end end,
        setCursorPos=function(a,b)
            assert(a>=1 and a<=w and b>=1 and b<=h); x,y=a,b
        end,
        write=function(s) assert(x+#s-1<=w); lines[y]=s end},lines
end
for _,size in ipairs({{51,19},{26,10},{7,5}}) do
    local target,lines=screen(size[1],size[2])
    for _,current in ipairs({0,50,100,150}) do
        m.draw(target,{current=current,capacity=100,ratio=current/100,
            occupied=1,slots=2,network=current})
        if size[1]>=26 then
            eq(lines[7]:sub(1,1),'0'); eq(lines[7]:sub(-3),'100')
            if current==0 then assert(not lines[6]:find('#')) end
            if current>=100 then assert(not lines[6]:find('-',1,true)) end
        end
    end
    m.draw(target,nil,'Vault offline: a')
    if size[1]>=26 then eq(lines[3],'VAULT DATA UNAVAILABLE') end
end
print('stock_monitor: data, failures, capacity, and rendering checks passed')

-- Aggregate repeated stacks and variants without confusing different items.
local counts=m.items({{name='iron',count=10},{name='iron',count=5,nbt='variant'},
    [8]={name='gold',count=7}})
eq(counts.iron,15); eq(counts.gold,7)
local history={}
local t=m.trend(history,{iron=100,gold=20,coal=10},0)
eq(t.remaining,300); eq(#t.losses,0)
t=m.trend(history,{iron=90,gold=30,coal=10},120)
eq(t.remaining,180); eq(#t.losses,0)
t=m.trend(history,{iron=60,gold=30},300)
eq(t.remaining,0); eq(#t.losses,2)
eq(t.losses[1].name,'iron'); eq(t.losses[1].loss,40)
eq(t.losses[2].name,'coal'); eq(t.losses[2].loss,10); eq(t.losses[2].current,0)
t=m.trend(history,{iron=85,gold=30,coal=10},420)
eq(#t.losses,1); eq(t.losses[1].loss,5); eq(t.elapsed,300)
-- Replenishment cancels out earlier consumption in the net change.
t=m.trend(history,{iron=100,gold=40,coal=10},600)
eq(#t.losses,0)
assert(m.trend(history,nil,610).unavailable); eq(#history.samples,0)
eq(m.trend(history,{iron=1},620).remaining,300)
-- Clock moving backwards starts a new window.
eq(m.trend(history,{iron=1},600).remaining,300)
local bounded={}
for i=0,1000 do m.trend(bounded,{iron=i},i) end
eq(#bounded.samples,301)
-- Sampling jitter keeps the most recent baseline before the cutoff.
local jitter={}
m.trend(jitter,{iron=100},0); m.trend(jitter,{iron=95},7)
t=m.trend(jitter,{iron=70},306); eq(t.losses[1].loss,30); eq(t.elapsed,306)
t=m.trend(jitter,{iron=60},308); eq(t.losses[1].loss,35); eq(t.elapsed,301)
local data={current=10,capacity=100,ratio=0.1,occupied=1,slots=2,
    trendSource='stock network',trendPage=0,
    trend={remaining=0,elapsed=300,losses={}}}
for i=1,20 do data.trend.losses[i]={name='minecraft:item_'..i,loss=i} end
for _,size in ipairs({{51,19},{26,14},{26,10}}) do
    local target,lines=screen(size[1],size[2])
    m.draw(target,data,nil,true)
    assert(lines[4]:find('item_1',1,true)); assert(lines[size[2]-1]:find('Page 1/',1,true))
    data.trendPage=1
    m.draw(target,data,nil,true)
    assert(lines[size[2]-1]:find('Page 2/',1,true))
    data.trendPage=0
    m.draw(target,data,nil,false)
    if size[2]>=14 then eq(lines[11],'NET LOSSES / LAST 5 MIN') end
end
data.trend={remaining=123,losses={}}
local target,lines=screen(26,10)
m.draw(target,data,nil,true); eq(lines[4],'Collecting: 123s left')
data.trend={remaining=0,losses={}}
m.draw(target,data,nil,true); eq(lines[4],'No items decreasing')
data.trend={unavailable=true}
m.draw(target,data,nil,true); eq(lines[4],'Trend data unavailable')
-- Verify actual sampling chooses ticker data and never falls back on failure.
devices.a=vault(1,{{name='iron',count=10}},64)
devices.ticker={stock=function() return {{name='gold',count=25}} end}
r=m.sample({vaults={'a'},ticker='ticker'},wrap)
eq(r.trendItems.gold,25); eq(r.trendItems.iron,nil)
devices.ticker=nil
r=m.sample({vaults={'a'},ticker='ticker'},wrap); eq(r.trendItems,nil)
r=m.sample({vaults={'a'}},wrap); eq(r.trendItems.iron,10)
print('stock_monitor: rolling trends, recovery, sources, and paging checks passed')

local control,controlLines=screen(51,19)
m.drawConsole(control,{current=120,capacity=1000},nil,{vaults={'a','b'},ticker='ticker'},'Up to date')
eq(controlLines[1],'STORAGE CONTROL PANEL')
eq(controlLines[3],'Configured vaults: 2')
assert(controlLines[18]:find('C: configure',1,true))
assert(controlLines[18]:find('U: check updates',1,true))
eq(controlLines[8],'Up to date')
print('Computer control-panel layout checks passed')

-- Repeated paints must not keep changing scale and generating resize events.
local scale,changes=1,0
local sized={getTextScale=function() return scale end,
    setTextScale=function(value) scale=value; changes=changes+1 end}
for i=1,10 do m.fitMonitor(sized) end
eq(scale,0.5); eq(changes,1)
-- Capacity cache avoids repeated slot calls but refreshes on size/expiry.
local slotCalls,slots=0,100
local inventory={size=function() return slots end,list=function() return {} end,
    getItemLimit=function(slot) slotCalls=slotCalls+1; return slot%2==0 and 16 or 64 end}
local now=1000
os.epoch=function() return now*1000 end
local cache={}
local configuration={vaults={'test'}}
local function get() return inventory end
local sampled=m.sample(configuration,get,cache)
eq(sampled.capacity,4000); eq(slotCalls,100)
m.sample(configuration,get,cache); eq(slotCalls,100)
slots=101
m.sample(configuration,get,cache); eq(slotCalls,201)
now=1300
m.sample(configuration,get,cache); eq(slotCalls,302)
local batches=0
parallel={waitForAll=function(...)
    local workers={...}; assert(#workers<=32); batches=batches+1
    for _,worker in ipairs(workers) do worker() end
end}
eq(m.capacity(inventory,100),4000); eq(batches,4)
print('Stable monitor scale and bounded/cached capacity reads passed')
