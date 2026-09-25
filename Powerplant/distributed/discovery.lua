-- Role discovery uses the same wired modem as shared peripherals. An ender
-- modem, if installed on the UI, is reserved for a future external uplink.
local M={protocol='transformer.discovery.v1'}
function M.modems()
  local wired,wireless={},{}
  for _,name in ipairs(peripheral.getNames()) do
    local device=peripheral.wrap(name)
    if device and type(device.isWireless)=='function' then
      local ok,value=pcall(device.isWireless)
      if ok then local list=value and wireless or wired; list[#list+1]=name end
    end
  end
  table.sort(wired); table.sort(wireless); return wired,wireless
end
function M.open(name)
  local modem=assert(peripheral.wrap(name),'Missing wired modem '..tostring(name))
  assert(type(modem.isWireless)=='function' and modem.isWireless()==false,'Local transformer communication requires a wired modem')
  rednet.close() -- Rednet sends on all open modems; keep the ender uplink separate.
  rednet.open(name)
end
function M.host(cluster,role)
  assert(type(cluster)=='string' and cluster:match('^[%w_-]+$'),'Use letters, numbers, underscores or hyphens for cluster name')
  assert(role=='master' or role=='regulation' or role=='protection','Unknown discovery role')
  rednet.host(M.protocol,cluster..':'..role)
end
function M.find(cluster,role)
  local ids={rednet.lookup(M.protocol,cluster..':'..role)}
  assert(#ids<=1,'Multiple '..role..' computers advertise this cluster; resolve duplicate roles first')
  return ids[1]
end
return M
