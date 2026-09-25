local M={}
local function number(v,unit) return type(v)=='number' and v==v and math.abs(v)<math.huge and string.format('%.2f%s',v,unit or '') or '--' end
local function contacts(s)
  local b=s and s.breakers or {}
  local function pole(v) return v and (v.closed==true and 'CLOSED' or v.closed==false and 'OPEN' or '?') or '?' end
  return '+ '..pole(b[1])..' / - '..pole(b[2])
end
function M.new(screen,palette)
  local ui={selected=1,page='transformers',buttons={},notice=''}
  local C=palette or colors
  local function line(y,text,fg,bg)
    local w,h=screen.getSize(); if y<1 or y>h then return end
    screen.setCursorPos(1,y); screen.setBackgroundColor(bg or C.black); screen.setTextColor(fg or C.white)
    screen.write((text..string.rep(' ',w)):sub(1,w))
  end
  function ui.attach(device) screen=device end
  function ui.draw(state)
    local w,h=screen.getSize(); ui.buttons={}
    screen.setBackgroundColor(C.black); screen.clear()
    if w<51 or h<22 then line(1,'Monitor needs 51 x 22 text cells',C.red); line(2,'Use a larger monitor; scale is already 0.5'); return end
    local function button(x,y,width,label,action,id,color)
      screen.setCursorPos(x,y); screen.setBackgroundColor(color or C.gray); screen.setTextColor(C.white)
      screen.write((' '..label..string.rep(' ',width)):sub(1,width))
      ui.buttons[#ui.buttons+1]={x=x,y=y,w=width,action=action,id=id}
    end
    line(1,'POWER PLANT  |  '..(ui.page=='transformers' and 'TRANSFORMERS' or 'GENERATORS'),C.cyan)
    local selected=ui.page=='transformers' and state.transformers[ui.selected]
    local g=selected and selected.grid or state.grid; local current=state.current
    if selected then for _,bus in ipairs(state.buses or {}) do if bus.id==selected.bus then current=bus.current end end end
    line(2,'Grid '..(g.available and number(g.voltage,' V') or 'UNAVAILABLE')..' | Draw '..(current.available and number(current.amps,' A') or '--'),g.healthy and C.lime or C.red)
    line(3,g.healthy and (g.energizingDeadBus and 'Ready for explicitly permitted dead-circuit startup' or 'Bus ready | controls use actual breaker feedback') or ('INHIBITED: '..tostring(g.reason)),g.healthy and C.lightGray or C.orange)
    local tx=state.transmission or {}
    if tx.configured then line(4,'Transmission: '..(tx.input.available and number(tx.input.volts,' V') or '--')..' -> '..(tx.output.available and number(tx.output.volts,' V') or '--')..' | ratio '..number(tx.measuredRatio),C.lightGray) end
    button(w-12,1,13,ui.page=='transformers' and 'Generators' or 'Transformers','tab')
    if ui.page=='generators' then
      line(5,'Generator telemetry (read only)',C.cyan)
      local perPage=math.max(1,math.floor((h-10)/2))
      local offset=math.floor((ui.selected-1)/perPage)*perPage
      if #state.generators==0 then line(7,'No generator telemetry nodes configured',C.lightGray) end
      for i=offset+1,math.min(#state.generators,offset+perPage) do
        local r=state.generators[i]
        line(5+2*(i-offset),r.name..' #'..r.id..': '..(r.available and number(r.voltage,' V')..' / '..number(r.current,' A') or 'OFFLINE / STALE'),r.available and C.white or C.orange)
        line(6+2*(i-offset),'  Power '..(r.powerAvailable and number(r.currentPowerWatts,' W')..' / max '..number(r.maxPowerWatts,' W') or '-- / max --'),C.lightGray)
      end
      line(h-4,'Clutch control is not implemented.',C.lightGray)
    else
      ui.selected=math.max(1,math.min(ui.selected,#state.transformers))
      local offset=math.floor((ui.selected-1)/5)*5
      for i=offset+1,math.min(offset+5,#state.transformers) do
        local n=state.transformers[i]; local s=n.status or {}; local row=4+i-offset
        local label=('%s #%d %s | %s | %s'):format(i==ui.selected and '>' or ' ',n.id,n.name,n.online and tostring(s.phase) or 'OFFLINE',contacts(s))
        line(row,label,not n.online and C.orange or s.fault and C.red or C.white,i==ui.selected and C.gray or C.black)
        ui.buttons[#ui.buttons+1]={x=1,y=row,w=w,action='select',id=i}
      end
      local n=state.transformers[ui.selected]
      if n then
        local s=n.status or {}; local t=s.thermal or {}
        line(10,n.name..' ['..tostring(n.role or 'generator')..'/'..tostring(n.bus or 'local')..'] | '..(n.desired and 'ENABLE' or 'DISABLE')..' | '..(n.online and 'ONLINE' or 'STALE'),C.cyan)
        line(11,'Input '..number(s.inputVoltage,' V')..' | Output '..number(s.outputVoltage,' V'))
        line(12,'Target '..number(s.configuredTarget or s.nominalTarget,' V')..' | Active '..number(s.currentTarget or s.target,' V')..' | Bus '..number(n.grid and n.grid.voltage,' V'))
        line(13,'Source '..number(s.sourceVoltage,' V')..' / '..number(s.sourceCurrentAmps,' A')..' | '..contacts(s))
        for stage=1,3 do
          local bank=(s.stages or {})[stage] or (s.variacs or {})[stage] or {}
          local hottest; local used=0; local unavailable=0
          for _,member in ipairs(t.members or {}) do
            if member.stage==stage then
              if member.available and type(member.temperatureC)=='number' then hottest=math.max(hottest or member.temperatureC,member.temperatureC) else unavailable=unavailable+1 end
              for _ in pairs(member.recoveryUsed or {}) do used=used+1 end
            end
          end
          local temp=t.enabled and (' | max '..number(hottest,' C')..' | credits used '..used..(unavailable>0 and ' !missing temp' or '')) or ' | thermal off/unavailable'
          line(13+stage,string.char(64+stage)..' '..number(bank.position and bank.position*100,'%')..' ('..#(bank.members or {})..' variacs)'..temp)
        end
        local fault=s.faultDetails or {}; local reason=s.fault or (n.event and n.event.sentAt>=(s.sentAt or 0) and n.event.reason)
        line(17,reason and ('Fault: '..tostring(fault.member or '')..' '..tostring(reason)) or 'No current fault reported',reason and C.red or C.lime)
        line(18,(n.transition and ('Shutdown prep '..n.transition.id..(n.transitionAtTarget and ' AT TARGET | ' or ' RAMPING | ')) or '')..(n.resetPending and 'RESET PENDING | ' or '')..tostring(n.notice or ''),C.orange)
        button(1,h-2,16,'Enable','enable',n.id,C.green)
        button(18,h-2,16,'Disable','disable',n.id,C.gray)
        button(35,h-2,16,'Reset fault','reset',n.id,C.orange)
      end
    end
    line(h-3,state.network and not state.network.available and ('Ender link offline: '..tostring(state.network.reason)) or ui.notice,C.yellow)
    button(1,h,16,'Previous','previous')
    button(18,h,16,'Next','next')
    button(35,h,16,'DISABLE ALL','stop',nil,C.red)
  end
  function ui.touch(x,y)
    for _,b in ipairs(ui.buttons) do if y==b.y and x>=b.x and x<b.x+b.w then return b.action,b.id end end
  end
  return ui
end
return M
