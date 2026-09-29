local savedPrint = print
local function run(labelKind)
    local oldID, oldLabel = os.getComputerID, os.getComputerLabel
    os.getComputerID = function() return 5 end
    os.getComputerLabel = function()
        if labelKind == "none" then return end
        if labelKind == "nil" then return nil end
        return "Flight"
    end
    local lines, outputPath, closed = {}, nil, false
    _G.print = function() end
    _G.fs = { exists = function(path) return path == "fighter-setup-5.txt" end,
        open = function(path)
            outputPath = path
            return { writeLine = function(line) lines[#lines + 1] = line end,
                flush = function() end, close = function() closed = true end }
        end }
    _G.textutils = { serialize = function(value) return type(value) == "table" and "{}" or tostring(value) end,
        pagedPrint = function() end }
    _G.peripheral = { getNames = function() return { "computer_6" } end,
        getType = function() return "computer" end,
        call = function(name, method)
            assert(method:match("^get") or method == "isOn" or method == "isWireless"
                or method == "isColor" or method == "size" or method == "list", "Non-read method")
            if method == "getLabel" then return end
            if method == "getSize" then return 7, 5 end
            if method == "getRelativeAngle" then error("injected read error") end
            return nil
        end }
    local ok, err = pcall(assert(loadfile("FighterJet/probe_setup.lua")))
    os.getComputerID, os.getComputerLabel, _G.print = oldID, oldLabel, savedPrint
    assert(ok, err)
    assert(closed and outputPath == "fighter-setup-5-1.txt")
    local report = table.concat(lines, "\n")
    assert(report:find("Computer label: " .. (labelKind == "name" and "Flight" or "(unlabelled)"), 1, true))
    assert(report:find("(no return values)", 1, true))
    assert(report:find("Return 2: 5", 1, true))
    assert(report:find("ERROR:", 1, true))
    assert(report:find("create_radar:plane_radar_2.getRange", 1, true))
end
for _, kind in ipairs({ "none", "nil", "name" }) do run(kind) end
print("Setup probe checks passed")
