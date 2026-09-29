-- Session, revision, ticket-age and sequence checks. No command replay on reconnect.
local M={protocol='fighter.jet.v1'}
function M.server(boot) return {boot=boot, tickets={}, serial=0, lastCommand=0} end
function M.ticket(s, now)
    s.serial=s.serial+1; s.tickets[s.serial]=now
    s.tickets[s.serial-32]=nil
    return s.serial
end
function M.accept(s, m, revision, now, maxAge)
    if type(m)~='table' or m.boot~=s.boot or m.revision~=revision then return false,'State changed; refresh' end
    if type(m.ticket)~='number' or not s.tickets[m.ticket] or now-s.tickets[m.ticket]>maxAge then return false,'Request expired' end
    if type(m.sequence)~='number' or m.sequence%1~=0 or m.sequence<=s.lastCommand then return false,'Old request' end
    s.lastCommand=m.sequence
    return true
end
function M.recovery(w, now, last, c)
    if not c.autoRestartHUD or now-w.started<c.grace or now-(last or w.started)<c.timeout
        or now-(w.lastAttempt or -math.huge)<c.cooldown or w.attempts>=c.maxAttempts then return false end
    w.attempts=w.attempts+1; w.lastAttempt=now
    return true
end
return M
