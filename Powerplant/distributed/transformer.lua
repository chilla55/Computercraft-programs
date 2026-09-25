-- Stable launcher. Release activation changes a pointer, never running files.
local command,role=...
local root=fs.getDir(shell.getRunningProgram())
local pointer=fs.combine(root,'active-release.json')
local function read(path)
  if path=='distributed-node.json' then
    local destination='/config/'..path
    if fs.exists(destination) or fs.exists(destination..'.tmp') then path=destination end
  end
  local p=fs.exists(path..'.tmp') and path..'.tmp' or path
  if not fs.exists(p) then return nil end
  local f=assert(fs.open(p,'r')); local result=textutils.unserializeJSON(f.readAll()); f.close(); return assert(result,'Invalid '..p)
end
local function write(path,v)
  if path=='distributed-node.json' then
    if not fs.exists('/config') then fs.makeDir('/config') end
    path='/config/'..path
  end
  local f=assert(fs.open(path..'.tmp','w')); f.write(textutils.serializeJSON(v)); f.close()
  if fs.exists(path) then fs.delete(path) end; fs.move(path..'.tmp',path)
end
local active=read(pointer)
local function folder(version)
  if not version or version=='bundled' then return root end
  assert(type(version)=='string' and version:match('^distributed%-%d+%.%d+%.%d+$'),'Invalid active release')
  return fs.combine(root,'releases/'..version)
end
local function isolated()
  local node=assert(read('distributed-node.json'),'Missing node configuration'); local s=node.config.settings
  local names={s.plusBreaker,s.minusBreaker}; for _,name in ipairs(s.inputBreakers) do names[#names+1]=name end
  for _,name in ipairs(names) do assert(peripheral.wrap(name).isClosed()==false,'Open every breaker before rollback') end
  for _,key in ipairs({'A','B','C'}) do assert(peripheral.wrap(s['gear'..key]).isRunning()==false,'Wait for drives before rollback') end
end
if command=='rollback' then
  assert(active and active.version~='bundled','Already using the original installed fallback'); isolated()
  local previous='bundled'
  active={version=previous,pending=false}; write(pointer,active)
  local node=read('distributed-node.json'); node.autoUpdate=false; write('distributed-node.json',node)
  print('Selected '..previous..'; automatic updates disabled locally. Run transformer.lua run to start stopped.'); return
end
local directory=folder(active and active.version)
local app,why=loadfile(fs.combine(directory,'app.lua'),'t',_ENV)
if not app then
  -- No automatic change to another release without verifying physical isolation.
  error('Release cannot load: '..tostring(why)..'; use transformer.lua rollback after isolation',0)
end
return app(directory,command,role,{launcher=shell.getRunningProgram(),working=shell.dir()})
