local M={protocol='transformer.cluster.v1',release='distributed-1.1.18',roles={'master','regulation','protection'}}
M.editable={'target','stepUp','entryRatio','inputGauge','outputGauge','sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge','sourceCurrentTripAmps','inputBreakers','plusBreaker','minusBreaker','variacsA','variacsB','variacsC','gearA','gearB','gearC','travelDegrees','accuracyVolts','fallbackVolts','moveTimeout','chargeTimeout','positionToleranceDegrees','maxInputVolts','outputTripPercent','thermalMaxAgeSeconds','thermalGraceSeconds','thermalCoolSeconds','rampVoltsPerSecond','maxRampStepVolts','pollSeconds','settleSeconds'}
M.fields={
  inputGauge={label="Voltage entering variacs",help="Required. Voltage gauge AFTER the entry transformer, BEFORE stage A."},
  outputGauge={label="Final output voltage",help="Required. Voltage gauge AFTER the exit transformer, on the transformer side of the output breakers."},
  sourceGauge={label="Generator / source voltage",help="Optional. Voltage gauge BEFORE the entry transformer. Enter - for none."},
  preStepUpGauge={label="Voltage before exit transformer",help="Optional. Voltage gauge AFTER stage C, BEFORE the exit transformer. Enter - for none."},
  sourceCurrentGauge={label="Generator / source current",help="Optional. Current gauge BEFORE the entry transformer. Enter - for none."},
  sourcePowerGauge={label="Generator / source power",help="Optional. Power gauge BEFORE the entry transformer. Enter - for none."},
  inputBreakers={label="Input isolation breakers",help="Required. Breakers that disconnect the incoming supply for maintenance and homing. List all names separated by commas."},
  plusBreaker={label="Positive output breaker",help="Required. Breaker on the positive output connection to the bus / load."},
  minusBreaker={label="Negative output breaker",help="Required. Breaker on the negative output connection to the bus / load."},
  target={label="Desired output voltage (V)",help="Voltage to maintain at the final output gauge."},
  entryRatio={label="Entry transformer reduction ratio",help="Source volts divided by volts entering the variacs. Example: 7500 V to 2500 V = 3. Use 1 with no entry transformer."},
  stepUp={label="Exit transformer voltage multiplier",help="Final output volts divided by volts before the exit transformer. Example: 1000 V to 2500 V = 2.5. Use 1 with no exit transformer."},
  sourceCurrentTripAmps={label="Source current trip limit (A)",help="Limit at the source current gauge, BEFORE the entry transformer. 0 disables this software current limit. Native breaker protection is unchanged."},
  travelDegrees={label="Full variac travel (degrees)",help="Shaft rotation needed to move a variac from minimum to maximum."},
  accuracyVolts={label="Preferred output accuracy (V)",help="Preferred difference from the desired output voltage."},
  fallbackVolts={label="Acceptable output error (V)",help="Allowed difference if the available variac positions cannot achieve the preferred accuracy. Also checked before output connection."},
  moveTimeout={label="Drive movement timeout (seconds)",help="Maximum wait for a sequenced gearbox movement to finish."},
  chargeTimeout={label="Breaker connection timeout (seconds)",help="Maximum wait for protection to connect the requested input or output breaker group."},
  positionToleranceDegrees={label="Movement verification tolerance (degrees)",help="Allowed destination error after a verified move in the commanded direction; a completely missed move always trips. This does NOT allow spread within a parallel bank: those positions must match exactly. Different stages may use different positions."},
  maxInputVolts={label="Maximum voltage entering variacs (V)",help="Trip limit measured AFTER the entry transformer, BEFORE stage A. This is not the generator voltage or spark-gap setting."},
  outputTripPercent={label="Output overvoltage trip margin (%)",help="Trip when measured output exceeds the active target by this percentage."},
  thermalMaxAgeSeconds={label="Temperature reading age limit (seconds)",help="Maximum age of a temperature sample before it is considered stale."},
  thermalGraceSeconds={label="Overheat curve time scale (seconds)",help="Default 5 allows five seconds in the 125-126 C band. Hotter bands allow less time; 140 C trips immediately."},
  thermalCoolSeconds={label="Thermal recovery wait (seconds)",help="Required cooling period at or below 125 C for thermal recovery."},
  rampVoltsPerSecond={label="Target voltage ramp speed (V/s)",help="Maximum speed for changing the active target toward the requested voltage."},
  maxRampStepVolts={label="Maximum target step (V)",help="Maximum target change in one regulation step."},
  pollSeconds={label="Regulation check interval (seconds)",help="Delay between regulation cycles. Protection runs independently."},
  settleSeconds={label="Voltage settling delay (seconds)",help="Wait after a variac movement before checking voltage again."},
  gearA={label="Stage 1 (A) drive gearbox",help="Required. Sequenced gearbox driving every variac in this stage."},
  variacsA={label="Stage 1 (A) variacs",help="Required. All parallel variacs driven by this stage gearbox. Separate their peripheral names with commas."},
  gearB={label="Stage 2 (B) drive gearbox",help="Required. Sequenced gearbox driving every variac in this stage."},
  variacsB={label="Stage 2 (B) variacs",help="Required. All parallel variacs driven by this stage gearbox. Separate their peripheral names with commas."},
  gearC={label="Stage 3 (C) drive gearbox",help="Required. Sequenced gearbox driving every variac in this stage."},
  variacsC={label="Stage 3 (C) variacs",help="Required. All parallel variacs driven by this stage gearbox. Separate their peripheral names with commas."},
}
function M.finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.copy(v) if type(v)~='table' then return v end; local r={} for k,x in pairs(v) do r[k]=M.copy(x) end return r end
function M.canonical(v)
  if type(v)~='table' then return type(v)..':'..(type(v)=='string' and string.format('%q',v) or tostring(v)) end
  local keys={}; for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return type(a)..tostring(a)<type(b)..tostring(b) end)
  local out={'{'}; for _,k in ipairs(keys) do out[#out+1]=M.canonical(k)..'='..M.canonical(v[k])..';' end
  out[#out+1]='}'; return table.concat(out)
end
local configFiles={['distributed-startup.json']=true,['distributed-node.json']=true,['distributed-state.json']=true,['distributed-thermal.json']=true,['dual-variac-config.json']=true}
function M.configPath(path) return configFiles[path] and '/config/'..path or path end
function M.read(path)
  local original=path; path=M.configPath(path)
  local recovery=fs.exists(path..'.tmp') and path..'.tmp' or path
  if not fs.exists(recovery) then
    -- One-time import keeps the original as a backup, including its recovery file.
    local legacy=fs.exists(original..'.tmp') and original..'.tmp' or original
    if path==original or not fs.exists(legacy) then return nil end
    local f=assert(fs.open(legacy,'r')); local text=f.readAll(); f.close()
    local value=assert(textutils.unserializeJSON(text),'Invalid JSON: '..legacy)
    M.write(path,value); return value
  end
  local f=assert(fs.open(recovery,'r')); local text=f.readAll(); f.close()
  return assert(textutils.unserializeJSON(text),'Invalid JSON: '..path)
end
function M.write(path,value)
  path=M.configPath(path)
  local parent=fs.getDir(path); if parent~='' and not fs.exists(parent) then fs.makeDir(parent) end
  local f=assert(fs.open(path..'.tmp','w')); f.write(textutils.serializeJSON(value)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path..'.tmp',path)
end
function M.validate(c)
  assert(type(c)=='table' and c.schema==1 and type(c.ids)=='table','Invalid cluster configuration')
  if c.cluster~=nil then assert(type(c.cluster)=='string' and c.cluster:match('^[%w_-]+$'),'Invalid cluster name') end
  local ids={}; for _,role in ipairs(M.roles) do local id=c.ids[role]; assert(M.finite(id) and id>=0 and id%1==0 and not ids[id],'Unique computer IDs required'); ids[id]=true end
  assert(type(c.revision)=='number' and c.revision>=1 and c.revision%1==0,'Invalid configuration revision')
  local s=assert(c.settings,'Missing transformer settings')
  for _,key in ipairs({'target','stepUp','entryRatio','travelDegrees','maxInputVolts','accuracyVolts','fallbackVolts','moveTimeout','chargeTimeout','thermalMaxAgeSeconds','thermalGraceSeconds','thermalCoolSeconds','rampVoltsPerSecond','maxRampStepVolts','outputTripPercent'}) do
    assert(M.finite(s[key]) and s[key]>0,'Invalid '..key)
  end
  assert(M.finite(s.positionToleranceDegrees) and s.positionToleranceDegrees>=0,'Invalid movement verification tolerance')
  assert(s.target/(s.stepUp*.99999^3)<s.maxInputVolts,'Target exceeds input range')
  assert(s.fallbackVolts>=s.accuracyVolts and s.outputTripPercent<100,'Invalid voltage tolerance')
  assert(type(s.inputBreakers)=='table' and #s.inputBreakers>0,'Input isolation breakers required')
  local names={}
  local function name(n) assert(type(n)=='string' and n~='' and not names[n],'Missing/duplicate peripheral: '..tostring(n)); names[n]=true end
  name(s.inputGauge); name(s.outputGauge); name(s.plusBreaker); name(s.minusBreaker)
  for _,n in ipairs(s.inputBreakers) do name(n) end
  for _,key in ipairs({'A','B','C'}) do
    name(s['gear'..key]); assert(type(s['variacs'..key])=='table' and #s['variacs'..key]>0,'Empty bank '..key)
    for _,n in ipairs(s['variacs'..key]) do name(n) end
  end
  for _,key in ipairs({'sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge'}) do
    assert(type(s[key])=='string','Invalid '..key); if s[key]~='' then name(s[key]) end
  end
  assert(M.finite(s.sourceCurrentTripAmps) and s.sourceCurrentTripAmps>=0,'Invalid source current limit')
  assert(s.sourceCurrentTripAmps==0 or s.sourceCurrentGauge~='','Current limit needs a gauge')
  return c
end
function M.names(s)
  local n={s.plusBreaker,s.minusBreaker}; for _,name in ipairs(s.inputBreakers) do n[#n+1]=name end; return n
end
function M.device(name) return assert(peripheral.wrap(name),'Missing peripheral '..name) end
function M.openAll(s)
  -- All attempts precede verification; a failed contact does not skip another.
  local errors={}
  for _,name in ipairs(M.names(s)) do local ok,e=pcall(function() M.device(name).open() end); if not ok then errors[#errors+1]=tostring(e) end end
  for _,name in ipairs(M.names(s)) do local ok,e=pcall(function() assert(M.device(name).isClosed()==false,name..' not verified open') end); if not ok then errors[#errors+1]=tostring(e) end end
  return #errors==0,table.concat(errors,'; ')
end
function M.isolated(s)
  for _,name in ipairs(M.names(s)) do if M.device(name).isClosed()~=false then return false end end
  return true
end
function M.idle(s)
  for _,key in ipairs({'A','B','C'}) do if M.device(s['gear'..key]).isRunning()~=false then return false end end
  return true
end
function M.positions(s)
  local banks={}
  for i,key in ipairs({'A','B','C'}) do
    local bank={members={},low=1,high=0,moving=false}; banks[i]=bank
    for _,name in ipairs(s['variacs'..key]) do
      local v=M.device(name).getStatus()
      assert(type(v)=='table' and M.finite(v.position) and v.position>=0 and v.position<=1,'Invalid position '..name)
      assert(M.finite(v.ratio) and math.abs(v.ratio-(.01+.99*v.position))<.001,'Invalid ratio '..name)
      assert(M.finite(v.shaftSpeed),'Invalid shaftSpeed '..name)
      bank.moving=bank.moving or v.shaftSpeed~=0
      bank.members[#bank.members+1]={name=name,position=v.position,shaftSpeed=v.shaftSpeed}; bank.low=math.min(bank.low,v.position); bank.high=math.max(bank.high,v.position)
    end
    bank.position=bank.members[1].position
    bank.aligned=bank.high==bank.low -- Parallel members must report identical positions.
  end
  return banks
end
-- Two consecutive snapshots avoid comparing positions from opposite sides
-- of a movement boundary. A gearbox reporting idle alone is not enough.
function M.stationaryBanks(s)
  local idle={}
  for i,key in ipairs({'A','B','C'}) do idle[i]=M.device(s['gear'..key]).isRunning()==false end
  local before,after=M.positions(s),M.positions(s)
  local all=true
  for i,bank in ipairs(after) do
    bank.stationary=idle[i] and M.device(s['gear'..string.char(64+i)]).isRunning()==false and not before[i].moving and not bank.moving
    for j,member in ipairs(bank.members) do
      if member.position~=before[i].members[j].position then bank.stationary=false end
    end
    all=all and bank.stationary
  end
  return after,all
end
function M.aligned(s,banks)
  banks=banks or M.stationaryBanks(s)
  for i,bank in ipairs(banks) do
    assert(bank.stationary,'Variacs still moving: stage '..i)
    assert(bank.aligned,'bank_misaligned: stage '..i)
  end
end
function M.checkAlignment(s)
  local banks,stationary=M.stationaryBanks(s)
  for i,bank in ipairs(banks) do
    if bank.stationary then assert(bank.aligned,'bank_misaligned: stage '..i) end
  end
  return banks,stationary
end
function M.voltage(name) local v=M.device(name).voltage(); assert(M.finite(v),'Invalid voltage '..name); return math.abs(v) end
function M.contacts(s)
  local out={}; for _,name in ipairs(M.names(s)) do local v=M.device(name).getStatus(); assert(type(v)=='table' and type(v.closed)=='boolean','Invalid breaker '..name); out[name]=v end; return out
end
-- Fresh boot sessions and monotonically increasing sequences exclude delayed
-- commands from a previous worker instance. This is not rednet authentication.
function M.accept(c,peers,id,m,now,allowOtherVersions)
  if type(m)~='table' or m.schema~=1 or m.revision~=c.revision or (m.release~=M.release and not (allowOtherVersions and type(m.release)=='string' and m.release:match('^distributed%-%d+%.%d+%.%d+$'))) or c.ids[m.role]~=id then return false end
  if type(m.session)~='string' or #m.session>100 or not M.finite(m.seq) or m.seq<1 or m.seq%1~=0 then return false end
  if not M.finite(m.sentAt) or now-m.sentAt>2000 or m.sentAt-now>250 then return false end
  if m.kind=='heartbeat' and type(m.data)~='table' then return false end
  local old=peers[m.role]
  if old and old.session==m.session and m.seq<=old.seq then return false end
  if old and old.session~=m.session and m.kind~='hello' then return false end
  if not old and m.kind~='hello' then return false end
  peers[m.role]={session=m.session,seq=m.seq,seen=now,release=m.release,dataAt=m.kind=='heartbeat' and now or old and old.session==m.session and old.dataAt or nil,data=m.kind=='heartbeat' and m.data or old and old.session==m.session and old.data or nil}
  return true,old and old.session~=m.session
end
return M
