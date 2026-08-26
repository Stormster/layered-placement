require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"

--- Server-side decor place/pickup for pure MP clients (dedicated players and
--- co-op hosts alike). Moveable timed actions only ever complete on the client,
--- so anything the client cannot persist is requested here instead.

local MODULE = LayeredPlacement.MOD_ID

--- Tell the requesting client what happened. Silence is the one outcome we
--- cannot explain later, so every handler answers exactly once.
local function reply(player, request, args, ok, reason)
    if not sendServerCommand or not player then
        return
    end
    sendServerCommand(player, MODULE, "requestResult", {
        request = request,
        x = args and args.x,
        y = args and args.y,
        z = args and args.z,
        spriteName = args and args.spriteName,
        ok = ok and true or false,
        reason = reason,
    })
end

--- Non-members must not decorate someone else's safehouse. Mirrors the check
--- ISMoveablesAction:isValid runs on the client for normal place/pickup.
local function blockedBySafehouse(player, square)
    if not SafeHouse or not SafeHouse.isSafeHouse or not player or not square then
        return false
    end
    local blocked = false
    pcall(function()
        if SafeHouse.isSafeHouse(square, player:getUsername(), true)
            and SafeHouse.isSafehouseAllowLoot
            and not SafeHouse.isSafehouseAllowLoot(square, player)
        then
            blocked = true
        end
    end)
    return blocked
end

--- Coordinates arrive over the wire and everything downstream trusts them, so
--- reject whatever is not a whole number before the world ever sees it. A
--- non-number used to reach the square lookup and the create call as-is.
local function coordsFromArgs(args)
    if not args then
        return nil
    end
    local x, y, z = args.x, args.y, args.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    if x ~= math.floor(x) or y ~= math.floor(y) or z ~= math.floor(z) then
        return nil
    end
    return x, y, z
end

--- Creating a missing square here is safe only because resolveRequest has
--- already confirmed the coordinates are within the player's reach -- a few
--- tiles, the same footing vanilla building has. force=true stays on purpose:
--- railing and catwalk edge tiles are exactly the ones the engine calls invalid
--- and the mod places on anyway.
local function squareFromCoords(x, y, z)
    local cell = getCell()
    if not cell then
        return nil
    end
    local square = cell:getGridSquare(x, y, z)
    if square then
        return square
    end
    return LayeredPlacement.ensureGridSquare(x, y, z, true)
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

--- "floating" = hanging Object decor (lamps, string lights) owned by the
--- railing/catwalk helper. "wall" = WallObject/WallOverlay/WindowObject decor
--- owned by the stacking helper. Each answers to its own Sandbox option.
local function decorKind(props)
    if LayeredPlacement.isHangingDecor(props) then
        return "floating", "floatingPlace"
    end
    if LayeredPlacement.isWallDecor(props) then
        return "wall", "layeredPlace"
    end
    return nil, nil
end

--- Shared gate for every world-action command. Returns props + square when the
--- request is allowed, or nil plus the reason to log and send back.
local function resolveRequest(request, player, args, allowedKinds)
    if not player or not instanceof(player, "IsoPlayer") then
        return nil, nil, "no player"
    end
    if args and args.version and args.version ~= LayeredPlacement.VERSION then
        LayeredPlacement.log("version mismatch: client " .. tostring(args.version)
            .. " vs server " .. LayeredPlacement.VERSION)
    end
    local x, y, z = coordsFromArgs(args)
    if x == nil then
        return nil, nil, "bad coordinates"
    end
    local props = propsFromArgs(args)
    if not props then
        return nil, nil, "bad square/props"
    end
    local kind, option = decorKind(props)
    if not kind or not allowedKinds[kind] then
        return nil, nil, "not supported decor for " .. request
    end
    if not LayeredPlacement.serverAllows(option) then
        return nil, nil, "disabled by Sandbox settings"
    end
    -- Reach is checked on the coordinates, before anything is allowed to touch
    -- the world. The square lookup used to run first and would create a missing
    -- square, so a request that was about to be refused had already dropped an
    -- empty square into the cell -- at whatever coordinates a client sent, which
    -- is the same way the chunk-load restore used to eat real map data.
    -- Hanging decor may be reached from a catwalk one level up; wall decor keeps
    -- the same-floor rule the client-side action uses.
    local inReach
    if kind == "floating" then
        inReach = LayeredPlacement.withinReachXYZ(
            player, x, y, z, LayeredPlacement.CHEAT_REACH, LayeredPlacement.BRUSH_MAX_Z
        )
    else
        inReach = LayeredPlacement.withinReachXYZ(
            player, x, y, z, LayeredPlacement.REACH_DIST
        )
    end
    if not inReach then
        return nil, nil, "out of reach"
    end
    local square = squareFromCoords(x, y, z)
    if not square then
        return nil, nil, "bad square/props"
    end
    if blockedBySafehouse(player, square) then
        return nil, nil, "blocked by safehouse"
    end
    return props, square, nil
end

local function finish(request, player, args, ok, detail)
    LayeredPlacement.log("server " .. request .. " " .. (ok and "ok" or "refused")
        .. " @ " .. tostring(args and args.x) .. "," .. tostring(args and args.y)
        .. "," .. tostring(args and args.z)
        .. " sprite=" .. tostring(args and args.spriteName)
        .. (detail and (" (" .. detail .. ")") or ""))
    reply(player, request, args, ok, detail)
end

local PLACE_FLOATING_KINDS = { floating = true }
local PICKUP_KINDS = { floating = true, wall = true }
local PLACE_LAYERED_KINDS = { wall = true }

local function onPlaceFloating(player, args)
    local props, square, reason = resolveRequest("placeFloating", player, args, PLACE_FLOATING_KINDS)
    if not props then
        return finish("placeFloating", player, args, false, reason)
    end
    -- origSpriteName = inventory item; spriteName/props = rotated face being placed.
    local orig = args.origSpriteName or args.spriteName
    local ok, result = pcall(function()
        return props:placeMoveable(player, square, orig)
    end)
    if not ok then
        return finish("placeFloating", player, args, false, "error: " .. tostring(result))
    end
    if not result then
        return finish("placeFloating", player, args, false, "nothing placed; item kept")
    end
    LayeredPlacement.markConstruction(square)
    finish("placeFloating", player, args, true, "face=" .. tostring(args.cursorFacing))
end

--- Find the inventory item this request would consume. Also the idempotency
--- guard: once the item is gone, a duplicate or replayed request does nothing.
local function findRequestItem(props, player, orig)
    if props.isMultiSprite then
        local grid = props.sprite and props.sprite:getSpriteGrid()
        local max = grid and grid:getSpriteCount() or 1
        local label = props.isForceSingleItem
            and (props.name .. " (1/1)")
            or (props.name .. " (1/" .. tostring(max) .. ")")
        return props:findInInventoryMultiSprite(player, label)
    end
    return props:findInInventory(player, orig)
end

--- Authoritative layered WallObject/WallOverlay placement. Vanilla refuses the
--- occupied tile (wall cabinet over a fridge, second poster on one wall), and a
--- client cannot persist the object it would create, so the server does both the
--- placement and the inventory removal here.
local function onPlaceLayered(player, args)
    local props, square, reason = resolveRequest("placeLayered", player, args, PLACE_LAYERED_KINDS)
    if not props then
        return finish("placeLayered", player, args, false, reason)
    end
    if not LayeredPlacement.hasPlaceRequirements(props, player) then
        return finish("placeLayered", player, args, false, "missing skill or tool")
    end

    local orig = args.origSpriteName or args.spriteName
    if not findRequestItem(props, player, orig) then
        return finish("placeLayered", player, args, false, "item already gone or unavailable")
    end

    local ok, err = pcall(function()
        props:placeMoveable(player, square, orig, true)
    end)
    if not ok then
        return finish("placeLayered", player, args, false, "error: " .. tostring(err))
    end
    -- Vanilla placeMoveable returns nil either way, so judge by the item: it is
    -- only removed once the object is actually in the world.
    if findRequestItem(props, player, orig) then
        return finish("placeLayered", player, args, false, "nothing placed; item kept")
    end
    LayeredPlacement.markConstruction(square)
    if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
        ISMoveableCursor.clearCacheForAllPlayers()
    end
    finish("placeLayered", player, args, true, "face=" .. tostring(args.cursorFacing))
end

--- Pickup for both decor families: a client has no authority to delete a world
--- object, and vanilla's own pickup gives up on stacked/partner-less decor.
local function onPickUpFloating(player, args)
    local props, square, reason = resolveRequest("pickUpFloating", player, args, PICKUP_KINDS)
    if not props then
        return finish("pickUpFloating", player, args, false, reason)
    end
    -- Read the footprint before the object goes. Afterwards there is nothing
    -- left to read the partner offsets from, and any partner still carrying its
    -- tag respawns this light on the next chunk load.
    local target = LayeredPlacement.findSpriteObject(square, args.spriteName)
    local originX, originY, originZ, parts
    if target then
        originX, originY, originZ, parts = LayeredPlacement.gridOriginOf(target)
    end
    local ok, result = pcall(function()
        return props:pickUpMoveable(player, square, true, true)
    end)
    if not ok then
        return finish("pickUpFloating", player, args, false, "error: " .. tostring(result))
    end
    if result == nil or result == false then
        return finish("pickUpFloating", player, args, false, "object already gone or unavailable")
    end
    if parts then
        local cleared = LayeredPlacement.clearMultiGridTags(originX, originY, originZ, parts)
        if cleared > 0 then
            LayeredPlacement.log("cleared " .. tostring(cleared)
                .. " leftover multi-grid tag(s) after pickup")
        end
    end
    LayeredPlacement.markConstruction(square)
    if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
        ISMoveableCursor.clearCacheForAllPlayers()
    end
    finish("pickUpFloating", player, args, true, nil)
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then
        return
    end
    if command == "placeFloating" then
        onPlaceFloating(player, args)
    elseif command == "placeLayered" then
        onPlaceLayered(player, args)
    elseif command == "pickUpFloating" then
        onPickUpFloating(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)

--- Restore marked floating lights when the authoritative world square loads.
--- This file also loads on clients (vanilla puts gameplay code under server/),
--- so skip it there: a client re-applying light state on every chunk load only
--- fights the server copy and floods it with sync packets.
local function onLoadSquare(square)
    if not square or not square.getObjects or not LayeredPlacement.canMutateWorld() then
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
            -- Re-evaluate battery vs building power (indoor table lights must
            -- not stay stuck in battery mode from older place paths).
            if md and (md.lpBatteryLight or md.lpWantOn ~= nil or md.lpGrid) then
                LayeredPlacement.preparePlacedLight(obj, md.lpWantOn)
            end
        end
    end
    -- Rebuild missing halves of multi-tile hanging lights (rail/void partners
    -- often fail to persist across chunk unload / server restart).
    LayeredPlacement.restoreMultiGridOnSquare(square)
end

Events.LoadGridsquare.Add(onLoadSquare)
LayeredPlacement.log("world-action handlers ready (" .. LayeredPlacement.environment() .. ")")
