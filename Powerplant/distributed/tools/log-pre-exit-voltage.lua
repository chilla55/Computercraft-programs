-- Standalone, read-only voltage recorder. No controller installation required.
-- Usage: log-pre-exit-voltage [peripheral name]
local requested=...
local threshold=1 -- Treat absolute readings <= 1 V as de-energized.
local names={}
for _,name in ipairs(peripheral.getNames()) do
 for _,method in ipairs(peripheral.getMethods(name) or {}) do
  if method=='voltage' then names[#names+1]=name; break end
 end
end
table.sort(names)
assert(#names>0,'No voltage gauges found. Enable peripheral sharing on the wired modems.')
local selected=requested
if not selected then for _,name in ipairs(names) do if name=='back' then selected=name end end end
if not selected then
 print('Choose the gauge AFTER bank C, BEFORE the exit transformer:')
 for i,name in ipairs(names) do print(i..': '..name) end
 write('Gauge number: ')
 selected=names[tonumber(read())]
end
local found=false
for _,name in ipairs(names) do if name==selected then found=true end end
assert(found,'Select a listed voltage gauge (or pass its exact peripheral name).')
local directory='/voltage-logs'
if not fs.exists(directory) then fs.makeDir(directory) end
local started=os.epoch('utc')
local stem=directory..'/pre-exit-'..started
local path=stem..'.csv'
local suffix=0
while fs.exists(path) do suffix=suffix+1; path=stem..'-'..suffix..'.csv' end
local free=fs.getFreeSpace(directory)
local limit=512*1024
if type(free)=='number' then limit=math.min(limit,free-16384) end
assert(limit>=4096,'Not enough free disk space for a recording. Copy old logs off this computer first.')
local file=assert(fs.open(path,'w'),'Cannot create '..path)
local bytes,count,errors=0,0,0
local minimum,maximum,peak,previous,maxStep
local lastFlush,lastDisplay=started,started
local reason='Stopped by operator'
local recording=false
local function csv(value)
 return '"'..tostring(value):gsub('"','""'):gsub('[\r\n]',' ')..'"'
end
local function append(line)
 if bytes+#line+1>limit then reason='Log size limit reached; recording preserved'; return false end
 file.writeLine(line); bytes=bytes+#line+1
 return true
end
append('sample,started_ms,finished_ms,voltage_v,error')
file.flush()
print('Armed on '..selected..'; waiting for voltage above '..threshold..' V')
print(path)
print('Q: stop and save. Ctrl+T also saves. No hardware controls.')
print('Stops when full; never overwrites previous recordings.')
local function sample()
 while true do
  local before=os.epoch('utc')
  local ok,value=pcall(peripheral.call,selected,'voltage')
  local after=os.epoch('utc')
  if not ok and tostring(value):find('Terminated',1,true) then error(value,0) end
  if ok and not (type(value)=='number' and value==value and math.abs(value)<math.huge) then
   ok=false; value='Invalid voltage: '..tostring(value)
  end
  if not recording and ok and math.abs(value)>threshold then
   recording=true; started=before
   print('Voltage detected: recording until voltage returns to <= '..threshold..' V')
  end
  if recording then
  count=count+1
  local row=count..','..before..','..after..','
  if ok then
   row=row..string.format('%.17g',value)..','
   minimum=math.min(minimum or value,value); maximum=math.max(maximum or value,value)
   peak=math.max(peak or 0,math.abs(value))
   if previous then maxStep=math.max(maxStep or 0,math.abs(value-previous)) end
   previous=value
  else
   errors=errors+1; previous=nil; row=row..','..csv(value)
  end
  if not append(row) then return end
  if ok and math.abs(value)<=threshold then reason='Voltage removed; recording complete'; return end
  -- Flush periodically, not once per sample. Abrupt power loss can lose the
  -- unflushed tail; a normal Q/Ctrl+T stop flushes and closes below.
  if after-lastFlush>=250 then file.flush(); lastFlush=after end
  if after-lastDisplay>=1000 then
   print(string.format('%d readings | %.1f/s | min %s max %s V | errors %d',count,
    count*1000/math.max(1,after-started),minimum and string.format('%.3f',minimum) or '--',
    maximum and string.format('%.3f',maximum) or '--',errors))
   lastDisplay=after
  end
  end -- recording
  -- Server-thread peripheral calls normally yield themselves. Only add a
  -- timer yield if this call completed within the same millisecond, or failed.
  if after==before or not ok then sleep(0) end
 end
end
local ok,why=pcall(function()
 parallel.waitForAny(sample,function()
  while true do local event,value=os.pullEvent(); if event=='char' and value:lower()=='q' then return end end
 end)
end)
local closed,closeError=pcall(function() file.flush(); file.close() end)
if not ok then reason=tostring(why) end
print(reason)
print('Saved: '..path)
print('Gauge: '..selected)
print('Peak absolute V: '..tostring(peak)..'; largest observed step V: '..tostring(maxStep))
if not closed then error('Could not finish saving log: '..tostring(closeError),0) end
