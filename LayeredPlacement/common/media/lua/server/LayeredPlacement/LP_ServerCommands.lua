require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"

--- Server-side floating decor place/pickup for pure MP clients.
--- Client brush path sends these commands so objects are created authoritatively
--- (client AddSpecialObject ghosts vanish on rejoin).

local MODULE = "LayeredPlacement"

local function squareFromArgs(args)
    if not args or args.x == nil or args.y == nil or args.z == nil then
        return nil
    end
    local cell = getCell()
    if not cell then
        return nil
    end
    local square = cell:getGridSquare(args.x, args.y, args.z)
    if square then
        return square
    end
    return LayeredPlacement.ensureGridSquare(args.x, args.y, args.z, true)
end

local function propsFromArgs(args)
    if not args or not args.spriteName then
        return nil
    end
    local props = ISMoveableSpriteProps.new(args.spriteName)
    if not props or not props.isMoveable then
        return nil
    end
    -- Restore the player's chosen rotation (face sprite and/or cursorFacing).
    if args.cursorFacing then
        props.cursorFacing = args.cursorFacing
    end
    return props
end

local function onPlaceFloating(player, args)
    if not player or not instanceof(player, "IsoPlayer") then
        return
    end
    local square = squareFromArgs(args)
    local props = propsFromArgs(args)
    if not square or not props then
        LayeredPlacement.log("server placeFloating: bad square/props")
        return
    end
    if not LayeredPlacement.isFloatingDecor(props) then
        LayeredPlacement.log("server placeFloating: not floating decor")
        return
    end
    if not LayeredPlacement.withinBrushReach(player, square) then
        LayeredPlacement.log("server placeFloating: out of reach")
        return
    end
    -- origSpriteName = inventory item; spriteName/props = rotated face being placed.
    local orig = args.origSpriteName or args.spriteName
    local ok = props:placeMoveable(player, square, orig)
    if ok then
        LayeredPlacement.markConstruction(square)
        LayeredPlacement.log("server placeFloating ok @ "
            .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z)
            .. " sprite=" .. tostring(args.spriteName)
            .. " face=" .. tostring(args.cursorFacing))
    else
        LayeredPlacement.log("server placeFloating failed")
    end
end

local function onPickUpFloating(player, args)
    if not player or not instanceof(player, "IsoPlayer") then
        return
    end
    local square = squareFromArgs(args)
    local props = propsFromArgs(args)
    if not square or not props then
        LayeredPlacement.log("server pickUpFloating: bad square/props")
        return
    end
    if not LayeredPlacement.isFloatingDecor(props) then
        LayeredPlacement.log("server pickUpFloating: not floating decor")
        return
    end
    if not LayeredPlacement.withinBrushReach(player, square) then
        LayeredPlacement.log("server pickUpFloating: out of reach")
        return
    end
    props:pickUpMoveable(player, square, true)
    LayeredPlacement.markConstruction(square)
    if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
        ISMoveableCursor.clearCacheForAllPlayers()
    end
    LayeredPlacement.log("server pickUpFloating @ "
        .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z))
end

local function lightFromArgs(square, args)
    if not square then
        return nil
    end
    local objects = square:getObjects()
    if not objects then
        return nil
    end
    local index = tonumber(args and args.objectIndex)
    if index and index >= 0 and index < objects:size() then
        local obj = objects:get(index)
        if obj and instanceof(obj, "IsoLightSwitch") then
            return obj
        end
    end
    local spriteName = args and args.spriteName
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and instanceof(obj, "IsoLightSwitch") then
            local objSprite = obj:getSprite()
            if not spriteName or (objSprite and objSprite:getName() == spriteName) then
                return obj
            end
        end
    end
    return nil
end

--- Dedicated-server authority for high/floating light interaction. The vanilla
--- client timed action toggles the light but does not persist our desired state
--- on the server, which made lights revert after a relog.
local function onSetLightState(player, args)
    if not player or not instanceof(player, "IsoPlayer") then
        return
    end
    local square = squareFromArgs(args)
    if not square or not LayeredPlacement.withinBrushReach(player, square) then
        LayeredPlacement.log("server setLightState: bad square/out of reach")
        return
    end
    local light = lightFromArgs(square, args)
    if not light then
        LayeredPlacement.log("server setLightState: light not found")
        return
    end
    local desired = args.desired and true or false
    if LayeredPlacement.preparePlacedLight(light, desired) then
        LayeredPlacement.log("server setLightState=" .. tostring(desired) .. " @ "
            .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z))
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then
        return
    end
    if command == "placeFloating" then
        onPlaceFloating(player, args)
    elseif command == "pickUpFloating" then
        onPickUpFloating(player, args)
    elseif command == "setLightState" then
        onSetLightState(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)

--- Restore marked floating lights when the authoritative world square loads.
--- Client-only restoration cannot make the state survive a server restart.
local function onLoadSquare(square)
    if not square or not square.getObjects then
        return
    end
    local objects = square:getObjects()
    if not objects then
        return
    end
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and instanceof(obj, "IsoLightSwitch") and obj.getModData then
            local md = obj:getModData()
            if md and md.lpBatteryLight then
                LayeredPlacement.preparePlacedLight(obj, md.lpWantOn)
            end
        end
    end
end

Events.LoadGridsquare.Add(onLoadSquare)
LayeredPlacement.log("server commands ready")
