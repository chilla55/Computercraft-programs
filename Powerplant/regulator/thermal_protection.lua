-- Pure per-member thermal policy. All times use the caller's persistent clock.
local M={}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function copy(v)
  if type(v)~='table' then return v end
  local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
function M.new(banks,options)
  options=options or {}
  local warning,trip=options.warningC or 125,options.tripC or 140
  local grace,maxAge=options.graceSeconds or 5,options.maxAgeSeconds or .25
  local coolSeconds=options.coolSeconds or 5
  local confirmSeconds,hysteresis=.25,.25
  assert(warning==125 and trip==140,'Curve requires 125/140 C thresholds')
  assert(finite(grace) and grace>0 and finite(maxAge) and maxAge>0
    and finite(coolSeconds) and coolSeconds>0,'Invalid thermal timing')
  local curve={{temperatureC=126,seconds=grace},{temperatureC=130,seconds=grace*.4},
    {temperatureC=135,seconds=grace*.1},{temperatureC=140,seconds=0}}
  local function allowance(t)
    if t<=warning then return nil end
    if t>=trip then return 0 end
    if t<=126 then return grace end
    for i=2,#curve do
      local a,b=curve[i-1],curve[i]
      if t<=b.temperatureC then
        return a.seconds+(b.seconds-a.seconds)*(t-a.temperatureC)/(b.temperatureC-a.temperatureC)
      end
    end
  end
  local members,ordered,fault={},{},nil
  for stage,bank in ipairs(banks) do
    assert(type(bank)=='table' and #bank>0,'Empty thermal bank')
    for _,name in ipairs(bank) do
      assert(type(name)=='string' and name~='' and not members[name],'Duplicate/missing thermal member')
      local m={stage=stage,stageName=string.char(64+stage),member=name,available=false,
        exposure=0,recoveryUsed={},recoveryArmed={}}
      members[name]=m; ordered[#ordered+1]=m
    end
  end
  assert(#ordered>0,'No thermal members')
  local function latch(m,code,reason)
    if not fault then
      fault={code=code,stage=m.stage,stageName=m.stageName,member=m.member,
        temperatureC=m.temperatureC,temperatureSource=m.temperatureSource,
        aboveSince=m.aboveSince,warningC=warning,tripC=trip,graceSeconds=grace,
        exposure=m.exposure,recoveryUsed=copy(m.recoveryUsed),reason=reason}
    end
    return copy(fault)
  end
  local function timeout(m)
    if m.exposure>=1-1e-9 then
      return latch(m,'thermal_hot_timeout',('Stage %d %s exhausted its thermal curve allowance'):format(m.stage,m.member))
    end
  end
  local function advance(m,now)
    if m.accountAt and now>=m.accountAt and m.accountTemperature then
      local seconds=allowance(m.accountTemperature)
      if seconds and seconds>0 then m.exposure=m.exposure+(now-m.accountAt)/seconds end
    end
    m.accountAt=now
    -- An already exhausted budget cannot be rescued by a later cool sample.
    if m.accountTemperature and m.accountTemperature>warning then timeout(m) end
  end
  local function fresh(m,now)
    return m.available and finite(m.sampledAt) and now>=m.sampledAt and now-m.sampledAt<=maxAge
  end
  local function unavailable(m)
    return latch(m,'thermal_reading_unavailable','Missing, stale or invalid temperature: '..m.member)
  end
  local policy={}
  function policy.update(name,t,now,source)
    local m=assert(members[name],'Unknown thermal member: '..tostring(name))
    assert(finite(now),'Invalid sample time')
    if not finite(t) or t< -273.15 or (source~='measured' and source~='calculated')
      or (m.accountAt and now<m.accountAt) then
      m.available=false; m.coolSince=nil; m.pendingRecovery=nil
      return unavailable(m)
    end
    if m.sampledAt and now-m.sampledAt>maxAge then
      m.available=false; m.coolSince=nil; m.pendingRecovery=nil; unavailable(m)
    end
    local previous=m.accountTemperature
    advance(m,now)
    m.temperatureC=t; m.sampledAt=now; m.temperatureSource=source; m.available=true
    m.accountTemperature=t
    if t>=trip then
      latch(m,'thermal_overtemperature',('Stage %d %s reached %.3f C (trip %.3f C)'):format(m.stage,name,t,trip))
    end
    if t>warning then
      m.aboveSince=m.aboveSince or now; m.coolSince=nil
      for i=1,3 do
        local level=curve[i].temperatureC; local key=tostring(level)
        if t>=level+hysteresis then m.recoveryArmed[key]=true end
      end
      local level
      for i=1,3 do if t<=curve[i].temperatureC then level=curve[i].temperatureC; break end end
      local pending=m.pendingRecovery
      if pending and (level~=pending.level or (previous and t>previous)) then pending=nil end
      if not pending and level and previous and previous>level and t<=level
        and m.recoveryArmed[tostring(level)] and not m.recoveryUsed[tostring(level)] then
        pending={level=level,since=now}
      end
      if pending and now-pending.since>=confirmSeconds-1e-9 then
        local key=tostring(pending.level)
        if not fault and not m.recoveryUsed[key] then
          m.exposure=math.max(0,m.exposure-.5); m.recoveryUsed[key]=true
        end
        pending=nil
      end
      m.pendingRecovery=pending
      timeout(m)
    else
      m.pendingRecovery=nil
      m.coolSince=m.coolSince or now
      if now-m.coolSince>=coolSeconds-1e-9 then
        m.exposure=0; m.recoveryUsed={}; m.recoveryArmed={}; m.aboveSince=nil
      end
    end
    return copy(fault)
  end
  function policy.check(now)
    assert(finite(now),'Invalid check time')
    for _,m in ipairs(ordered) do
      if not fresh(m,now) then unavailable(m) else advance(m,now) end
    end
    return copy(fault)
  end
  function policy.reset(now)
    assert(finite(now),'Invalid reset time')
    for _,m in ipairs(ordered) do
      if not fresh(m,now) then return false,'Fresh temperatures required for every variac' end
      if m.temperatureC>warning then return false,'Every variac must cool to '..warning..' C or below' end
    end
    -- Clearing a latch does not replenish credits; sustained cooling does that.
    fault=nil; return true
  end
  function policy.export()
    local data={version=2,fault=copy(fault),members={}}
    for _,m in ipairs(ordered) do
      if m.aboveSince or m.exposure>0 then
        data.members[m.member]={aboveSince=m.aboveSince,exposure=m.exposure,
          accountAt=m.accountAt,accountTemperature=m.accountTemperature,
          recoveryUsed=copy(m.recoveryUsed),recoveryArmed=copy(m.recoveryArmed)}
      end
    end
    return data
  end
  function policy.restore(data)
    assert(type(data)=='table' and (data.version==1 or data.version==2) and type(data.members)=='table','Invalid thermal checkpoint')
    if data.fault~=nil then
      assert(type(data.fault)=='table' and type(data.fault.code)=='string' and type(data.fault.reason)=='string','Invalid saved thermal fault')
      fault=copy(data.fault)
    end
    for name,s in pairs(data.members) do
      assert(type(name)=='string' and type(s)=='table' and finite(s.aboveSince),'Invalid saved hot interval')
      local m=members[name]
      if data.version==2 then
        assert(finite(s.exposure) and s.exposure>=0 and finite(s.accountAt) and s.accountAt>=s.aboveSince
          and finite(s.accountTemperature) and s.accountTemperature>=-273.15,'Invalid saved exposure')
        for _,map in ipairs({s.recoveryUsed or false,s.recoveryArmed or false}) do
          assert(type(map)=='table','Invalid saved recovery credits')
          for k,v in pairs(map) do assert((k=='126' or k=='130' or k=='135') and v==true,'Invalid saved recovery level') end
        end
      end
      if m then
        m.aboveSince=s.aboveSince
        m.exposure=data.version==2 and s.exposure or 0
        m.accountAt=data.version==2 and s.accountAt or s.aboveSince
        m.accountTemperature=data.version==2 and s.accountTemperature or 126
        m.recoveryUsed=copy(s.recoveryUsed or {}); m.recoveryArmed=copy(s.recoveryArmed or {})
      end
    end
    -- Never restore fresh readings, cooling confirmation or a pending credit.
  end
  function policy.status(now)
    assert(finite(now),'Invalid status time')
    local result={warningC=warning,tripC=trip,graceSeconds=grace,maxAgeSeconds=maxAge,
      coolSeconds=coolSeconds,recoveryConfirmSeconds=confirmSeconds,recoveryHysteresisC=hysteresis,
      curve=copy(curve),fault=copy(fault),members={}}
    for i,m in ipairs(ordered) do
      local item=copy(m); item.available=fresh(m,now)
      local projected=m.exposure
      local seconds=m.accountTemperature and allowance(m.accountTemperature)
      if item.available and seconds and seconds>0 and now>=m.accountAt then projected=projected+(now-m.accountAt)/seconds end
      item.exposure=projected; item.allowanceSeconds=m.temperatureC and allowance(m.temperatureC)
      item.remainingSeconds=item.allowanceSeconds and math.max(0,1-projected)*item.allowanceSeconds or nil
      item.aboveSeconds=m.aboveSince and math.max(0,now-m.aboveSince) or 0
      item.coolSeconds=m.coolSince and math.max(0,now-m.coolSince) or 0
      item.accountAt=nil; item.accountTemperature=nil
      result.members[i]=item
    end
    return result
  end
  return policy
end
return M
