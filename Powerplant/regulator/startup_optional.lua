-- Optional launcher: place beside transformer_controller.lua in computer root.
-- Rename to startup.lua only after configuring/testing. Do not overwrite an
-- existing startup file blindly. Standalone mode can automatically connect.
if not fs.exists("dual-variac-config.json") then
  print("Configure first: transformer_controller.lua configure")
  return
end
if not fs.exists("transformer_controller.lua") then
  printError("Missing transformer_controller.lua in computer root")
  return
end
if not fs.exists("thermal_protection.lua") then
  printError("Missing thermal_protection.lua beside controller")
  return
end
if not fs.exists("regulator_ui.lua") then
  printError("Missing regulator_ui.lua beside controller")
  return
end
shell.run("transformer_controller.lua", "run")
