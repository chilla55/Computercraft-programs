local M={protocol='transformer.cluster.v1',release='distributed-1.1.1',roles={'master','regulation','protection'}}
M.editable={'target','stepUp','entryRatio','inputGauge','outputGauge','sourceGauge','preStepUpGauge','sourceCurrentGauge','sourcePowerGauge','sourceCurrentTripAmps','inputBreakers','plusBreaker','minusBreaker','variacsA','variacsB','variacsC','gearA','gearB','gearC','travelDegrees','accuracyVolts','fallbackVolts','moveTimeout','chargeTimeout','positionToleranceDegrees','maxInputVolts','outputTripPercent','thermalMaxAgeSeconds','thermalGraceSeconds','thermalCoolSeconds','rampVoltsPerSecond','maxRampStepVolts','pollSeconds','settleSeconds'}
function M.finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.copy(v) if type(v)~='table' then return v end; local r={} for k,x in pairs(v) do r[k]=M.copy(x) end return r end
function M.canonical(v)
  if type(v)~='table' then return type(v)..':'..(type(v)=='string' and string.format('%q',v) or tostring(v)) end
  local keys={}; for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return type(a)..tostring(a)<type(b)..tostring(b) end)
  local out={'{'}; for _,k in ipairs(keys) do out[#out+1]=M.canonical(k)..'='..M.canonical(v[k])..';' end
  out[#out+1]='}'; return table.concat(out)
end
function M.read(path)
  local recovery=fs.exists(path..'.tmp') and path..'.tmp' or path
  if not fs.exists(recovery) then return nil end
  local f=assert(fs.open(recovery,'r')); local text=f.readAll(); f.close()
  return assert(textutils.unserializeJSON(text),'Invalid JSON: '..path)
end
function M.write(path,value)
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
  for _,key in ipairs({'target','stepUp','entryRatio','travelDegrees','maxInputVolts','accuracyVolts','fallbackVolts','moveTimeout','chargeTimeout','positionToleranceDegrees','thermalMaxAgeSeconds','thermalGraceSeconds','thermalCoolSeconds','rampVoltsPerSecond','maxRampStepVolts','outputTripPercent'}) do
    assert(M.finite(s[key]) and s[key]>0,'Invalid '..key)
  end
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
    local bank={members={},low=1,high=0}; banks[i]=bank
    for _,name in ipairs(s['variacs'..key]) do
      local v=M.device(name).getStatus()
      assert(type(v)=='table' and M.finite(v.position) and v.position>=0 and v.position<=1,'Invalid position '..name)
      assert(M.finite(v.ratio) and math.abs(v.ratio-(.01+.99*v.position))<.001,'Invalid ratio '..name)
      bank.members[#bank.members+1]={name=name,position=v.position}; bank.low=math.min(bank.low,v.position); bank.high=math.max(bank.high,v.position)
    end
    bank.position=bank.members[1].position
    bank.aligned=(bank.high-bank.low)*s.travelDegrees<=s.positionToleranceDegrees
  end
  return banks
end
function M.aligned(s,banks)
  for i,bank in ipairs(banks or M.positions(s)) do assert(bank.aligned,'bank_misaligned: stage '..i) end
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
