-- Local advanced-computer UI. Hardware stays owned by transformer_controller.
local M={}
function M.new(screen,c,clock)
  clock=clock or os.clock
  local tab,offset,editing='Diagram',0,nil
  local tabs={'Diagram','Variacs','Gauges','Settings','Incidents','Updates'}
  local hits={}
  local frame,lastRows={},{}
  local lastWidth,lastHeight
  local scrolling,animated={},false
  local frameTime=0
  local function fmt(v,unit) return type(v)=='number' and string.format('%.1f%s',v,unit or '') or '--' end
  local function value(v)
    if type(v)=='table' then return table.concat(v,',') end
    return tostring(v)
  end
  local function put(x,y,text,fg,bg,limit,fixed)
    local w,h=screen.getSize(); if y<1 or y>h then return end
    local width=math.max(0,math.min(limit or w,w-x+1))
    text=tostring(text)
    local key=tab..':'..x..':'..y
    if #text>width and width>0 and not fixed then
      animated=true
      local old=scrolling[key]
      if not old or old.text~=text or old.width~=width then
        old={text=text,width=width,since=frameTime}; scrolling[key]=old
      end
      local distance=#text-width
      -- Pause at both ends; scroll slowly enough to read a narrow monitor.
      local duration=distance*.2
      local elapsed=math.max(0,frameTime-old.since)%(duration+3)
      local start=math.min(distance,math.max(0,math.floor((elapsed-1.5)/.2)))
      text=text:sub(start+1,start+width)
    else
      scrolling[key]=nil; text=text:sub(1,width)
    end
    frame[y]=frame[y] or {}
    frame[y][#frame[y]+1]={x=x,text=text,fg=fg or c.white,bg=bg or c.black}
  end
  local function button(x,y,label,action,bg)
    put(x,y,label,c.white,bg or c.gray,nil,true)
    hits[#hits+1]={x=x,y=y,width=#label,action=action}
  end
  local api={}
  function api.draw(data)
    local w,h=screen.getSize(); hits={}
    frame={}; animated=false; frameTime=clock()
    if w~=lastWidth or h~=lastHeight then
      screen.setBackgroundColor(c.black); screen.clear(); lastRows={}; scrolling={}
      lastWidth,lastHeight=w,h
    end
    local compact=w<45
    if compact then
      put(1,1,string.upper(data.phase or 'TRANSFORMER'),c.cyan)
      button(1,2,' E-STOP ',{kind='emergency'},c.red)
      button(1,3,'<',{kind='page',delta=-1})
      put(3,3,tab,c.cyan,nil,w-4)
      button(w,3,'>',{kind='page',delta=1})
    else
      put(1,1,'TRANSFORMER '..string.upper(data.phase or '?'),c.cyan,nil,w-14)
      button(math.max(1,w-13),1,' EMERGENCY STOP',{kind='emergency'},c.red)
      if w<56 then
        button(1,2,'<',{kind='page',delta=-1}); put(3,2,tab,c.cyan,nil,w-4)
        button(w,2,'>',{kind='page',delta=1})
      else
        local x=1
        for _,name in ipairs(tabs) do
          button(x,2,' '..name..' ',{kind='tab',name=name},name==tab and c.blue or c.gray); x=x+#name+2
        end
      end
    end
    local rows,actions={},{}
    local function row(text) rows[#rows+1]=text end
    if compact and tab=='Diagram' then
      row('Source '..fmt(data.sourceVoltage,'V'))
      row(' | Gap 7500V')
      row('Input breakers')
      for _,breaker in ipairs(data.inputBreakers) do row(' '..(breaker.available and breaker.status and (breaker.status.closed and 'CLOSED' or 'OPEN') or '?')) end
      row('Entry '..fmt(data.entryRatio,':1'))
      row('In '..fmt(data.inputVoltage,'V'))
      for i,stage in ipairs(data.stages) do
        local member=stage.members[1]
        row(string.char(64+i)..': '..fmt(member and member.position and member.position*100,'%')..' x'..#stage.members)
      end
      row('Pre '..fmt(data.preStepUpVoltage,'V'))
      row('Exit x'..fmt(data.stepUp))
      row('Out '..fmt(data.outputVoltage,'V'))
      for i,breaker in ipairs(data.breakers) do row('Out '..i..' '..(breaker.closed and 'CLOSED' or 'OPEN')) end
      row('Tgt '..fmt(data.nominalTarget,'V'))
    elseif tab=='Diagram' then
      row('Generator / source '..fmt(data.sourceVoltage,' V'))
      row('  | Spark gap 7500 V (generator protection)')
      row('  | Input isolation breakers: '..#data.inputBreakers)
      for _,b in ipairs(data.inputBreakers) do row('    '..b.name..': '..(b.available and b.status and (b.status.closed and 'CLOSED' or 'OPEN') or 'UNKNOWN')) end
      row('  v Entry transformer '..fmt(data.entryRatio,':1'))
      row('  | Regulator input '..fmt(data.inputVoltage,' V'))
      for i,s in ipairs(data.stages) do row('  v Stage '..i..' ['..#s.members..' variacs] '..fmt(s.members[1] and s.members[1].position and s.members[1].position*100,'%')) end
      row('  | Pre-exit '..fmt(data.preStepUpVoltage,' V'))
      row('  v Exit transformer x'..fmt(data.stepUp))
      row('  | Output '..fmt(data.outputVoltage,' V'))
      local a,b=data.breakers[1],data.breakers[2]
      row('  v Output contacts: '..(a and (a.closed and 'CLOSED' or 'OPEN') or '?')..' / '..(b and (b.closed and 'CLOSED' or 'OPEN') or '?'))
      row('Bus | Target '..fmt(data.nominalTarget,' V')..' active '..fmt(data.target,' V'))
    elseif tab=='Variacs' then
      for i,s in ipairs(data.stages) do
        row(compact and ('Stage '..i) or ('Stage '..i..' / '..s.gear))
        if s.targetDegrees then row('Goal '..fmt(s.targetDegrees,' deg')) end
        for _,m in ipairs(s.members) do
          row(' '..m.name)
          row((compact and '' or '   ')..fmt(m.position and m.position*100,'%')..(compact and ' ' or '   ')..fmt(m.temperature,'C'))
        end
      end
    elseif tab=='Gauges' then
      for _,key in ipairs({'source','input','preStepUp','output'}) do
        local sample=data.voltages[key]; if compact then row(key); row(fmt(sample.volts,' V')) else row(key..': '..fmt(sample.volts,' V')) end
        row(' '..tostring(sample.peripheral or 'unassigned')..(sample.available and '' or ' [unavailable]'))
      end
      for _,key in ipairs({'current','power'}) do
        local sample=data.sourceMeters[key]; if compact then row('Source '..key); row(fmt(sample.amps or sample.watts,key=='current' and ' A' or ' W')) else row('Source '..key..': '..fmt(sample.amps or sample.watts,key=='current' and ' A' or ' W')) end
        row(' '..tostring(sample.peripheral or 'unassigned')..(sample.available and '' or ' [unavailable]'))
      end
    elseif tab=='Updates' then
      local function version(v) return v and v:gsub('^distributed%-','') or '--' end
      if data.updateCanApprove and not data.updateChecking and not data.updateApplying then
        row(' Check now '); actions[#rows]={kind='update_check'}
      else row(data.updateChecking and 'Checking...' or data.updateApplying and 'Applying...' or 'Check on master') end
      row('Running: '..version(data.runningVersion))
      row('Latest: '..version(data.availableUpdate))
      row('Staged: '..version(data.updateReady))
      row(data.autoUpdate and 'Auto: every 5 min' or 'Auto checks: off')
      row(data.updateMessage or 'Press Check now to query GitHub.')
      for _,role in ipairs({'regulation','protection'}) do
        local peer=(data.updateWorkers or {})[role] or {}
        row(role..': '..(peer.online and version(peer.version) or 'offline'))
        if peer.ready then row(' Staged: '..version(peer.ready)) end
      end
      row('Apply requires maintenance and both workers ready.')
    elseif tab=='Incidents' then
      for i=#(data.events or {}),1,-1 do
        local e=data.events[i]; row((e.origin or '?')..': '..(e.resolvedBy and 'opening explained' or e.code or 'unknown'))
        row(' '..tostring(e.resolvedCause or e.reason)); row(' '..tostring(e.id))
      end
    else
      local keys={}
      for k in pairs(data.config) do if k~='version' and not k:match('^variac[ABC]$') then keys[#keys+1]=k end end
      table.sort(keys)
      api.settingKeys={}
      for _,k in ipairs(keys) do
        row(compact and k or k..' = '..value(data.config[k])); api.settingKeys[#rows]=k
        if compact then row(' '..value(data.config[k])); api.settingKeys[#rows]=k end
      end
      api.config=data.config
    end
    local top=compact and 4 or 2
    local height=math.max(1,h-(compact and 11 or 7)); offset=math.max(0,math.min(offset,math.max(0,#rows-height)))
    for j=1,height do
      local index=offset+j
      if rows[index] then
        if actions[index] then button(1,j+top,rows[index],actions[index],c.blue)
        else put(1,j+top,rows[index]) end
        if tab=='Settings' then hits[#hits+1]={x=1,y=j+top,width=w,action={kind='edit',key=api.settingKeys[index]}} end
      end
    end
    local status=data.emergencyStopped and 'EMERGENCY STOP LATCHED' or data.maintenance.active and
      (data.maintenance.verified and data.maintenance.drivesIdle and 'MAINTENANCE: contacts open, drives idle' or 'MAINTENANCE: isolation not yet verified') or data.message
    local function statusLine(y)
      if data.fault or data.tripPending then
        put(1,y,'TRIP: ',c.red,nil,6,true)
        put(7,y,data.tripPending and 'Checking reason...' or data.fault,c.red)
      else put(1,y,status or '',data.emergencyStopped and c.red or c.yellow) end
    end
    if compact then
      button(1,h-6,' Up ',{kind='scroll',delta=-1})
      button(math.max(6,w-5),h-6,' Down ',{kind='scroll',delta=1})
      button(1,h-5,' Maintenance ',{kind='maintenance'})
      button(1,h-4,' Resume/reset ',{kind='resume'})
      statusLine(h-3)
      if data.updateReady then
        put(1,h-2,'Ready '..(data.updateReady:match('%d+%.%d+%.%d+') or data.updateReady),c.yellow)
        if data.updateCanApprove and not data.updateApplying and not data.updateChecking then
          button(1,h-1,'Apply',{kind='update_apply',version=data.updateReady},c.blue)
          button(math.max(7,w-4),h-1,'Later',{kind='update_later',version=data.updateReady})
        else put(1,h-1,data.updateApplying and 'Applying...' or data.updateChecking and 'Checking...' or 'Await master',c.lightGray) end
      else
        put(1,h-2,'Tgt '..fmt(data.nominalTarget,'V'),c.cyan)
        button(1,h-1,' Quit ',{kind='stop'})
      end
      put(1,h,editing and editing.text:sub(-w) or (data.updateDeferred and 'Update postponed' or 'Tap; type on PC'),c.lightGray)
    else
    statusLine(h-4)
    put(1,h-3,data.maintenance.reason or data.message or '',c.lightGray)
    button(1,h-2,' Maintenance ',{kind='maintenance'})
    button(15,h-2,' Resume/reset ',{kind='resume'})
    button(31,h-2,' Quit ',{kind='stop'})
    put(1,h-1,'Scroll: wheel/up/down | E: emergency | Q: quit',c.lightGray)
    if editing then put(1,h,editing.key..': '..editing.text,c.yellow)
    else put(1,h,tab=='Settings' and 'Click setting. Wiring changes require maintenance.' or 'Contacts open does not prove absence of voltage.',c.lightGray) end
    if data.updateReady then
      -- Footer prompt leaves emergency stop and maintenance controls available.
      put(1,h-1,string.rep(' ',w))
      put(1,h-1,'Update ready: '..data.updateReady,c.yellow)
      if not editing then
        put(1,h,string.rep(' ',w))
        if data.updateCanApprove and not data.updateApplying and not data.updateChecking then
          button(1,h,' Apply ',{kind='update_apply',version=data.updateReady},c.blue)
          button(10,h,' Later ',{kind='update_later',version=data.updateReady})
          put(19,h,data.updateDeferred and 'Postponed; files retained.' or 'Requires isolation + restart.',c.lightGray)
        else put(1,h,data.updateApplying and 'Applying approved update...' or data.updateChecking and 'Checking and staging update...' or 'Staged only; waiting for UI master approval.',c.lightGray) end
      end
    end
    end
    -- Repaint only changed rows: periodic samples should not flash the screen
    -- or rewrite unchanged controls while the operator is typing.
    for y=1,h do
      local signature={}
      for _,part in ipairs(frame[y] or {}) do
        signature[#signature+1]=table.concat({part.x,part.fg,part.bg,#part.text,part.text},':')
      end
      local fingerprint=table.concat(signature,'|')
      if fingerprint~=lastRows[y] then
        screen.setCursorPos(1,y); screen.setBackgroundColor(c.black); screen.setTextColor(c.white)
        screen.write(string.rep(' ',w))
        for _,part in ipairs(frame[y] or {}) do
          screen.setCursorPos(part.x,y); screen.setTextColor(part.fg); screen.setBackgroundColor(part.bg); screen.write(part.text)
        end
        lastRows[y]=fingerprint
      end
    end
  end
  function api.event(event,a,b,d)
    if event=='mouse_click' then
      for _,hit in ipairs(hits) do if d==hit.y and b>=hit.x and b<hit.x+hit.width then
        local action=hit.action
        if action.kind=='page' then
          local index=1; for i,name in ipairs(tabs) do if name==tab then index=i end end
          tab=tabs[(index-1+action.delta)%#tabs+1]; offset=0; editing=nil
        elseif action.kind=='scroll' then offset=math.max(0,offset+action.delta)
        elseif action.kind=='tab' then tab=action.name; offset=0; editing=nil
        elseif action.kind=='edit' then editing={key=action.key,text=value(api.config[action.key]),replace=true}
        else return action end
        return
      end end
    elseif event=='mouse_scroll' then offset=math.max(0,offset+a)
    elseif event=='char' then
      if editing then editing.text=(editing.replace and '' or editing.text)..a; editing.replace=false
      elseif a:lower()=='e' then return {kind='emergency'}
      elseif a:lower()=='q' then return {kind='stop'} end
    elseif event=='paste' and editing then editing.text=(editing.replace and '' or editing.text)..a; editing.replace=false
    elseif event=='key' then
      -- Use the installed CC key mapping.
      if editing then
        if a==keys.enter then local out={kind='setting',key=editing.key,value=editing.text}; editing=nil; return out
        elseif a==keys.backspace then editing.text=editing.replace and '' or editing.text:sub(1,-2); editing.replace=false
        elseif a==keys.escape then editing=nil end
      elseif a==keys.up then offset=math.max(0,offset-1) elseif a==keys.down then offset=offset+1 end
    end
  end
  function api.animating() return animated end
  function api.editing() return editing end
  return api
end
return M
