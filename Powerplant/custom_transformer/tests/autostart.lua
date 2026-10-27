local function install(files, target)
    local booted, directories = nil, {}
    local env = setmetatable({print = function() end}, {__index = _G})
    env.shell = {resolve = function(path) return path end,
        run = function(path, command) booted = {path, command} end}
    env.fs = {
        exists = function(path) return files[path] ~= nil or directories[path] end,
        isDir = function(path) return directories[path] == true end,
        makeDir = function(path) directories[path] = true end,
        open = function(path, mode)
            return {readAll = function() return files[path] end,
                write = function(text) assert(mode == "w"); files[path] = text end,
                close = function() end}
        end,
    }
    local ok, why = pcall(assert(loadfile("Powerplant/custom_transformer/autostart.lua", "t", env)), "install", target)
    if ok then
        assert(load(files["/startup/custom_transformer.lua"], "startup", "t", env))()
    end
    return ok, why, booted
end
local files = {["/transformer.lua"] = "controller", ["/startup.lua"] = "existing startup"}
local ok, why, booted = install(files)
assert(ok, why); assert(booted[1] == "/transformer.lua" and booted[2] == "run")
assert(files["/startup.lua"] == "existing startup")
ok, why = install(files); assert(ok, why) -- updating our own entry is supported
files = {["/transformer.lua"] = "controller", ["/startup/custom_transformer.lua"] = "someone else's entry"}
assert(not install(files)); assert(files["/startup/custom_transformer.lua"] == "someone else's entry")
files = {["/transformer.lua"] = "controller", ["/startup"] = "existing boot file"}
assert(not install(files)); assert(files["/startup"] == "existing boot file")
assert(not install({}))
files = {["/nested/a'\"b.lua"] = "controller"}
ok, why, booted = install(files, "nested/a'\"b.lua")
assert(ok, why); assert(booted[1] == "/nested/a'\"b.lua")
print("Custom transformer autostart: install, owned updates, preservation, missing files and path quoting passed")
