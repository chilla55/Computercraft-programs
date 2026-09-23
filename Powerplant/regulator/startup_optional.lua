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
shell.run("transformer_controller.lua", "run")
