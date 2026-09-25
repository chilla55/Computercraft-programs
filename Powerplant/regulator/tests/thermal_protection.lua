local thermal=dofile('Powerplant/regulator/thermal_protection.lua')
local checks=0
local function check(ok,message) assert(ok,message); checks=checks+1 end
local function near(a,b) return math.abs(a-b)<1e-7 end
local function new(options) return thermal.new({{'a1','a2'},{'b1'},{'c1'}},options or {maxAgeSeconds=60}) end
local function sample(p,t,temp)
  local f=p.update('a1',temp,t,'measured')
  for _,n in ipairs({'a2','b1','c1'}) do p.update(n,100,t,'measured') end
  return f
end
local function member(p,t) return p.status(t).members[1] end
-- Constant-temperature limits and interpolation, including near the hard trip.
for _,point in ipairs({{125.1,5},{126,5},{128,3.5},{130,2},{132.5,1.25},{135,.5},{137.5,.25},{139.9,.01}}) do
  local p=new(); sample(p,0,point[1])
  check(near(member(p,0).remainingSeconds,point[2]),'curve allowance incorrect')
  check(not sample(p,point[2]-.00001,point[1]),'curve expired early')
  local f=sample(p,point[2],point[1])
  check(f and f.code=='thermal_hot_timeout' and f.member=='a1','curve deadline missed')
end
local p=new(); local f=p.update('c1',140,0,'measured')
check(f and f.code=='thermal_overtemperature' and f.stage==3,'hard trip not immediate')
-- Exposure carries into hotter levels: half spent at 130 leaves .25 s at 135.
p=new(); sample(p,0,130); sample(p,1,135)
check(near(member(p,1).remainingSeconds,.25),'heating reset exposure')
check(sample(p,1.25,135).code=='thermal_hot_timeout','mixed exposure deadline')
-- Cooling through a level grants half a budget after .25 s confirmation.
p=new(); sample(p,0,136); sample(p,.05,135); sample(p,.29,135)
check(not member(p,.29).recoveryUsed['135'],'credit granted before confirmation')
sample(p,.30,135)
check(member(p,.30).recoveryUsed['135'] and near(member(p,.30).exposure,.125),'135 credit incorrect')
-- Reheat/cool through the same point: no repeat credit.
sample(p,.31,136); sample(p,.32,135); sample(p,.57,135)
check(near(member(p,.57).exposure,.67),'135 credit granted twice')
-- Each cooler level has its own independent credit.
sample(p,.58,130); sample(p,.83,130)
check(member(p,.83).recoveryUsed['130'] and near(member(p,.83).exposure,.315),'130 independent credit missing')
sample(p,.84,126); sample(p,1.09,126)
check(member(p,1.09).recoveryUsed['126'] and member(p,1.09).exposure==0,'126 credit missing or overfilled')
local saved=p.export(); local resumed=new(); resumed.restore(saved)
check(not member(resumed,1.09).available,'checkpoint restored live availability')
sample(resumed,1.10,126)
check(member(resumed,1.10).recoveryUsed['135'] and member(resumed,1.10).recoveryUsed['130'] and member(resumed,1.10).recoveryUsed['126'],'restart restored credits')
-- A brief cool dip retains all used credits/exposure, including after reset.
sample(resumed,1.2,125); check(resumed.reset(1.2),'fresh cool reset rejected')
sample(resumed,2,126)
check(member(resumed,2).recoveryUsed['126'] and member(resumed,2).exposure>0,'brief cooling erased episode')
sample(resumed,2.1,125); sample(resumed,7.09,125)
check(member(resumed,7.09).recoveryUsed['126'],'credits reset before sustained cooling')
sample(resumed,7.1,125)
check(next(member(resumed,7.1).recoveryUsed)==nil and member(resumed,7.1).exposure==0,'cool confirmation failed to reset credits')
-- Noise around a level cannot arm a credit without .25 C headroom.
p=new(); sample(p,0,130.1); sample(p,.1,130); sample(p,.35,130)
check(not member(p,.35).recoveryUsed['130'],'noise armed a recovery credit')
-- A warming sample cancels pending recovery; crossing again is required.
p=new(); sample(p,0,131); sample(p,.1,129.8); sample(p,.2,129.9); sample(p,.4,129.9)
check(not member(p,.4).recoveryUsed['130'],'warming confirmed a cooling credit')
-- Skipping levels grants only the reached level, never stacked credits.
p=new(); sample(p,0,136); sample(p,.05,126); sample(p,.30,126)
check(member(p,.30).recoveryUsed['126'] and not member(p,.30).recoveryUsed['130'] and not member(p,.30).recoveryUsed['135'],'skipped levels stacked recovery')
-- Recovery cannot rescue an already expired budget or the 140 C hard trip.
p=new(); sample(p,0,135); check(sample(p,.5,130).code=='thermal_hot_timeout','late cooling revived expired budget')
p=new(); sample(p,0,131); sample(p,.1,130); sample(p,.35,130)
check(sample(p,.36,140).code=='thermal_overtemperature','recovery bypassed hard trip')
-- Missing/invalid samples, freshness and backward time retain fail-closed behavior.
p=new({maxAgeSeconds=.25}); sample(p,0,125)
check(not p.check(.25),'freshness boundary rejected')
check(p.check(.251).code=='thermal_reading_unavailable','stale data accepted')
p=new(); check(p.check(0).code=='thermal_reading_unavailable','missing members accepted')
for _,bad in ipairs({0/0,math.huge,-274}) do
  p=new(); check(p.update('a1',bad,0,'measured').code=='thermal_reading_unavailable','invalid temperature accepted')
end
p=new(); sample(p,1,100); check(sample(p,.9,100).code=='thermal_reading_unavailable','clock reversal accepted')
-- Persistent accounting charges offline hot time; pending/cool confirmations do not survive restart.
p=new(); sample(p,0,130); sample(p,.5,130); saved=p.export()
resumed=new(); resumed.restore(saved)
check(sample(resumed,2,130).code=='thermal_hot_timeout','offline time granted new allowance')
p=new(); sample(p,0,131); sample(p,.1,130); resumed=new(); resumed.restore(p.export()); sample(resumed,.4,130)
check(not member(resumed,.4).recoveryUsed['130'],'offline time confirmed recovery')
p=new(); sample(p,0,126); sample(p,1,125); resumed=new(); resumed.restore(p.export()); sample(resumed,10,125)
check(member(resumed,10).exposure>0,'offline time confirmed sustained cooling')
-- v14 checkpoint migration preserves elapsed exposure and faults.
p=new(); p.restore({version=1,members={a1={aboveSince=0}}})
check(sample(p,5,126).code=='thermal_hot_timeout','legacy checkpoint lost elapsed time')
resumed=new(); resumed.restore(p.export()); sample(resumed,6,125)
check(resumed.status(6).fault~=nil,'restart cleared a latch')
check(resumed.reset(6),'fresh cool readings failed to reset latch')
sample(resumed,11,125); check(not resumed.check(11),'cooled reset retained fault')
local exposed=resumed.status(11); exposed.members[1].recoveryUsed['130']=true
check(not member(resumed,11).recoveryUsed['130'],'telemetry mutated credits')

-- Recovery accounting belongs to the individual member, never to the whole stage.
p=new(); sample(p,0,131); p.update('a2',131,0,'measured')
sample(p,.1,130); p.update('a2',131,.1,'measured'); sample(p,.35,130)
check(member(p,.35).recoveryUsed['130'] and not p.status(.35).members[2].recoveryUsed['130'],'one member donated a recovery credit to another')
-- Configured grace scales the curve; configured cooling duration is honored.
p=new({maxAgeSeconds=60,graceSeconds=10,coolSeconds=2}); sample(p,0,130)
check(member(p,0).allowanceSeconds==4,'custom grace failed to scale curve')
sample(p,1,125); sample(p,2.99,125); check(member(p,2.99).exposure>0,'custom cooling reset early')
sample(p,3,125); check(member(p,3).exposure==0,'custom cooling reset late')
-- Damaged saved state is rejected, including unknown credit levels.
p=new(); sample(p,0,130); saved=p.export(); saved.members.a1.recoveryUsed['139']=true
resumed=new(); check(not pcall(resumed.restore,saved),'unknown checkpoint recovery level accepted')
print(('PASS: %d thermal policy checks'):format(checks))
