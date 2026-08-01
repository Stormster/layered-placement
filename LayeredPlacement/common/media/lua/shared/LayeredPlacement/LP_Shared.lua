LayeredPlacement = LayeredPlacement or {}

LayeredPlacement.MOD_ID = "LayeredPlacement"
LayeredPlacement.VERSION = "1.4.2"

--- Feature flags (defaults on). Dedicated servers keep these defaults;
--- clients override from Mod Options.
LayeredPlacement.options = LayeredPlacement.options or {
    layeredPlace = true,   -- lights over furniture/posters, multiple highs, wall decor together
    floatingPlace = true,  -- railings / catwalks / wall lamps without a solid wall
    meshFloorAim = true,   -- Place aims at your floor when the mouse falls through mesh
    catwalkReach = true,   -- place when you're next to a tile but pathing fails
    lightInteract = true,  -- easier turn on/off and right-click for railing lamps
}

function LayeredPlacement.log(msg)
    if getDebug and getDebug() then
        print("[LayeredPlacement] " .. tostring(msg))
    end
end

local function flag(name)
    local opts = LayeredPlacement.options
    if not opts then
        return true
    end
    return opts[name] ~= false
end

function LayeredPlacement.allowLayeredPlace()
    return flag("layeredPlace")
end

function LayeredPlacement.allowFloatingPlace()
    return flag("floatingPlace")
end

function LayeredPlacement.allowMeshFloorAim()
    return flag("meshFloorAim")
end

function LayeredPlacement.allowCatwalkReach()
    return flag("catwalkReach")
end

function LayeredPlacement.allowLightInteract()
    return flag("lightInteract")
end

--- Any placement helper that changes what Place will accept.
function LayeredPlacement.isPlaceHelpEnabled()
    return LayeredPlacement.allowLayeredPlace() or LayeredPlacement.allowFloatingPlace()
end

--- Back-compat for older checks.
function LayeredPlacement.isEnabled()
    return LayeredPlacement.isPlaceHelpEnabled()
        or LayeredPlacement.allowMeshFloorAim()
        or LayeredPlacement.allowCatwalkReach()
        or LayeredPlacement.allowLightInteract()
end

--- Coerce Mod Options / UI values to a real boolean.
function LayeredPlacement.coerceBool(value, default)
    if value == nil then
        return default ~= false
    end
    if value == true or value == false then
        return value
    end
    if value == "true" or value == "1" then
        return true
    end
    if value == "false" or value == "0" then
        return false
    end
    return value and true or false
end

function LayeredPlacement.setOption(name, value)
    LayeredPlacement.options = LayeredPlacement.options or {}
    LayeredPlacement.options[name] = LayeredPlacement.coerceBool(value, true)
end

function LayeredPlacement.setEnabled(value)
    -- Legacy single switch: turn the main place helpers on/off together.
    local on = value and true or false
    LayeredPlacement.setOption("layeredPlace", on)
    LayeredPlacement.setOption("floatingPlace", on)
end

function LayeredPlacement.hasPlaceRequirements(props, character)
    if not character or not instanceof(character, "IsoPlayer") then
        return true
    end
    if ISMoveableDefinitions.cheat or character:isMovablesCheat() then
        return true
    end
    local hasSkill = props:hasRequiredSkill(character, "place")
    local hasTool = (not props.placeTool) and true or props:hasTool(character, "place")
    return hasSkill and hasTool
end

--- High/low decor can float (brush-like). If the mouse fell through to a lower Z
--- while you're upstairs, prefer the square at your floor for that XY.
function LayeredPlacement.resolveFloatingSquare(character, square, props)
    if not LayeredPlacement.allowMeshFloorAim() then
        return square
    end
    if not square or not props then
        return square
    end
    if not (props.isHigh or props.isLow) then
        return square
    end
    if not character then
        return square
    end
    local charSq = character:getSquare()
    if not charSq then
        return square
    end
    local pz = charSq:getZ()
    if square:getZ() >= pz then
        return square
    end
    local cell = getCell()
    if not cell then
        return square
    end
    local x, y = square:getX(), square:getY()
    local atPlayer = cell:getGridSquare(x, y, pz)
    if not atPlayer and getWorld and getWorld():isValidSquare(x, y, pz) then
        atPlayer = cell:createNewGridSquare(x, y, pz, true)
    end
    if atPlayer then
        LayeredPlacement.log("float Z " .. tostring(square:getZ()) .. " -> " .. tostring(pz))
        return atPlayer
    end
    return square
end
