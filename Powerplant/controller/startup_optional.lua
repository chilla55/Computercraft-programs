-- Install beside the three controller files in computer root; rename after testing.
for _,path in ipairs({'plant_controller.lua','controller_core.lua','controller_ui.lua','plant-controller-config.json'}) do
  if not fs.exists(path) then printError('Missing '..path..'; install/configure the plant controller first'); return end
end
shell.run('plant_controller.lua','run')
