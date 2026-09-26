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
eq(r.network,512); eq(r.nonVault,400); eq(r.ratio,1/3); eq(m.format(1234567),'1,234,567')
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
        write=function(s)
            assert(x+#s-1<=w)
            local old=lines[y] or ''
            lines[y]=old:sub(1,x-1)..string.rep(' ',math.max(0,x-1-#old))..s..old:sub(x+#s)
            x=x+#s
        end},lines
end
for _,size in ipairs({{51,19},{26,10},{7,5}}) do
    local target,lines=screen(size[1],size[2])
    for _,current in ipairs({0,50,100,150}) do
        m.draw(target,{current=current,capacity=100,ratio=current/100,
            occupied=1,slots=2,network=current})
        if size[1]>=26 then
            local percentage=string.format('%.1f%% full',current)
            eq(lines[7],string.rep(' ',math.floor((size[1]-#percentage)/2))..percentage)
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
local function change(trend,name)
    for _,item in ipairs(trend.changes) do if item.name==name then return item end end
end
local history={}
local t=m.trend(history,{iron=100,gold=20,coal=10},0)
eq(t.elapsed,0); eq(#t.changes,0)
t=m.trend(history,{iron=90,gold=30,coal=10},30)
eq(t.elapsed,30); eq(t.minuteElapsed,30)
eq(change(t,'iron').five,-10); eq(change(t,'gold').minute,10)
m.trend(history,{iron=80,gold=30,coal=10},240)
t=m.trend(history,{iron=60,gold=30,copper=40},300)
eq(t.elapsed,300); eq(t.minuteElapsed,60)
eq(change(t,'iron').five,-40); eq(change(t,'iron').minute,-20)
eq(change(t,'coal').five,-10); eq(change(t,'coal').current,0)
eq(change(t,'copper').five,40); eq(change(t,'copper').minute,40)
t=m.trend(history,{iron=85,gold=30,coal=10},330)
eq(t.elapsed,300); eq(t.minuteElapsed,90)
eq(change(t,'iron').five,-5); eq(change(t,'iron').minute,5)
-- Gains and losses between snapshots telescope to the endpoint net change.
local oscillating={}
m.trend(oscillating,{iron=100},0)
m.trend(oscillating,{iron=150},120)
m.trend(oscillating,{iron=140},240)
t=m.trend(oscillating,{iron=120},300)
eq(change(t,'iron').five,20); eq(change(t,'iron').minute,-20)
-- A zero five-minute net must still appear when the one-minute net is nonzero.
t=m.trend(oscillating,{iron=100},301)
eq(change(t,'iron').five,0); eq(change(t,'iron').minute,-40)
assert(m.trend(history,nil,610).unavailable); eq(#history.samples,0)
eq(m.trend(history,{iron=1},620).elapsed,0)
eq(m.trend(history,{iron=1},600).elapsed,0)
local bounded={}
for i=0,1000 do m.trend(bounded,{iron=i},i) end
eq(#bounded.samples,301)
local jitter={}
m.trend(jitter,{iron=100},0); m.trend(jitter,{iron=95},7)
t=m.trend(jitter,{iron=70},306); eq(change(t,'iron').five,-30); eq(t.elapsed,306)
t=m.trend(jitter,{iron=60},308); eq(change(t,'iron').five,-35); eq(t.elapsed,301)
local data={current=10,capacity=100,ratio=0.1,occupied=1,slots=2,
    trendSource='stock network',trendPage=0,
    trend={minuteElapsed=60,elapsed=300,changes={}}}
for i=1,20 do data.trend.changes[i]={name='minecraft:item_'..i,minute=i,five=-i} end
for _,size in ipairs({{51,19},{26,15},{26,10}}) do
    local target,lines=screen(size[1],size[2])
    m.draw(target,data,nil,true)
    assert(lines[5]:find('item_1',1,true)); assert(lines[5]:find('+1',1,true))
    assert(lines[5]:find('-1',1,true)); assert(lines[size[2]-1]:find('| 1/',1,true))
    data.trendPage=1
    m.draw(target,data,nil,true)
    assert(lines[size[2]-1]:find('| 2/',1,true))
    data.trendPage=0
    m.draw(target,data,nil,false)
    if size[2]>=15 then eq(lines[11],'NET CHANGE / 1 MIN + 5 MIN') end
end
local target,lines=screen(26,10)
data.trend={minuteElapsed=30,elapsed=30,changes={{name='iron',minute=5,five=5}}}
m.draw(target,data,nil,true)
assert(lines[4]:find('30s',1,true)); assert(lines[5]:find('+5',1,true))
data.trend={elapsed=0,minuteElapsed=0,changes={}}
m.draw(target,data,nil,true); eq(lines[4],'Waiting for next snapshot')
data.trend={elapsed=300,minuteElapsed=60,changes={}}
m.draw(target,data,nil,true); eq(lines[5],'No net changes')
data.trend={unavailable=true}
m.draw(target,data,nil,true); eq(lines[4],'Trend data unavailable')
data.trend={elapsed=300,minuteElapsed=60,changes={{name='iron',minute=12345678,five=-98765432}}}
m.draw(target,data,nil,true)
assert(lines[5]:find('+12.3M',1,true)); assert(lines[5]:find('-98.7M',1,true))
data.trend.changes[1].minute=999999999
m.draw(target,data,nil,true)
assert(lines[5]:find('+999.9M',1,true))
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
eq(controlLines[1]:sub(1,21),'STORAGE CONTROL PANEL')
eq(controlLines[1]:sub(-#m.version-1),'v'..m.version)
eq(#controlLines[1],51)
eq(controlLines[3],'Configured vaults: 2')
assert(controlLines[18]:find('C: configure',1,true))
assert(controlLines[18]:find('U: check updates',1,true))
eq(controlLines[8],'Up to date')
print('Computer control-panel layout checks passed')

-- Repeated paints must not keep changing scale and generating resize events.
local scale,changes=0.5,0
local sized={getTextScale=function() return scale end,
    setTextScale=function(value) scale=value; changes=changes+1 end}
for i=1,10 do m.fitMonitor(sized) end
eq(scale,1.0); eq(changes,1)
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

-- Doubled-size 3x2 layout retains counts, capacity, gauge and both net columns.
local compact,compactLines=screen(29,12)
m.draw(compact,{current=5000,capacity=10000,ratio=0.5,occupied=100,slots=200,
    network=6000,nonVault=1000,trendPage=0,
    trend={elapsed=300,minuteElapsed=60,changes={
        {name='minecraft:iron_ingot',minute=10,five=-100},
        {name='minecraft:gold_ingot',minute=-5,five=50},
        {name='minecraft:copper_ingot',minute=2,five=20},
    }}},nil,false)
eq(compactLines[1],'VAULTS / 50.0% FULL')
eq(compactLines[2],'Non-vault: ~1,000')
eq(compactLines[3],'Vault items: 5,000')
eq(compactLines[4],'Vault max: 10,000')
eq(compactLines[6],string.rep(' ',9)..'50.0% full')
assert(compactLines[8]:find('1 min',1,true)); assert(compactLines[8]:find('5 min',1,true))
assert(compactLines[9]:find('iron_ingot',1,true)); assert(compactLines[9]:find('+10',1,true))
assert(compactLines[9]:find('-100',1,true)); assert(compactLines[11]:find('1/2',1,true))
print('Doubled text scale and compact 3x2 dashboard checks passed')

-- Never present unmatched vault/network scopes as a non-vault count.
devices.a=vault(1,{{name='iron',count=10}},64)
devices.ticker={stock=function() return {{name='gold',count=100}} end}
r=m.sample({vaults={'a'},ticker='ticker'},wrap)
eq(r.nonVault,nil); assert(r.nonVaultError)
devices.ticker.stock=function() return {{name='iron',count=5}} end
r=m.sample({vaults={'a'},ticker='ticker'},wrap)
eq(r.nonVault,nil); assert(r.nonVaultError)
devices.ticker.stock=function() return {{name='iron',count=10}} end
r=m.sample({vaults={'a'},ticker='ticker'},wrap)
eq(r.nonVault,0)
r=m.sample({vaults={'a'}},wrap); eq(r.nonVault,nil)
print('Non-vault subtraction, mismatched scopes and zero remainder checks passed')

for _,width in ipairs({26,39,51}) do
    local small,rows=screen(width,19)
    m.drawConsole(small,nil,nil,{vaults={'a'}},'Ready')
    eq(#rows[1],width)
    eq(rows[1]:sub(-#m.version-1),'v'..m.version)
end
print('Running version aligned to terminal top-right at multiple widths')

local errorScreen,errorLines=screen(51,19)
m.drawConsole(errorScreen,nil,nil,{vaults={'a'}},'Up to date','Not enough disk space: history needs 2000 bytes')
eq(errorLines[7],'HISTORY SAVE ERROR')
assert(errorLines[8]:find('Not enough disk space',1,true))
print('Exact history save error appears in the terminal control panel')
