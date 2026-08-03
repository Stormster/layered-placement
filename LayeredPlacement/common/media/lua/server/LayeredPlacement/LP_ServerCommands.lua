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
    local orig = args.origSpriteName or args.spriteName
    local ok = props:placeMoveable(player, square, orig)
    if ok then
        LayeredPlacement.markConstruction(square)
        LayeredPlacement.log("server placeFloating ok @ "
            .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z))
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

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then
        return
    end
    if command == "placeFloating" then
        onPlaceFloating(player, args)
    elseif command == "pickUpFloating" then
        onPickUpFloating(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
LayeredPlacement.log("server commands ready")
