require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"

local function propsOf(object)
    local spr = object and object:getSprite()
    return spr and spr:getProperties() or nil
end

local function isHighLightSwitch(object)
    if not object or not instanceof(object, "IsoLightSwitch") then
        return false
    end
    local props = propsOf(object)
    return props and props:has("IsHigh") and true or false
end

local function hasRealWall(light)
    local spr = light and light:getSprite()
    if not spr or not light:getSquare() then
        return false
    end
    local mp = ISMoveableSpriteProps.new(spr)
    if not mp or not mp.facing then
        return false
    end
    return mp:getWallForFacing(light:getSquare(), mp.facing) and true or false
end

local function chebyshev(playerObj, square)
    local psq = playerObj and (playerObj:getSquare() or playerObj:getCurrentSquare())
    if not psq or not square then
        return 999
    end
    if psq:getZ() ~= square:getZ() then
        return 999
    end
    local dx = math.abs(psq:getX() - square:getX())
    local dy = math.abs(psq:getY() - square:getY())
    return math.max(dx, dy)
end

local function nearbyOrWalk(playerObj, square)
    if chebyshev(playerObj, square) <= 2 then
        return true
    end
    return luautils.walkAdj(playerObj, square) and true or false
end

local function forEachWorldObject(worldobjects, fn)
    if not worldobjects then
        return
    end
    if type(worldobjects) == "table" then
        for i = 1, #worldobjects do
            local obj = worldobjects[i]
            if obj then
                fn(obj)
            end
        end
        return
    end
    if worldobjects.size and worldobjects.get then
        for i = 0, worldobjects:size() - 1 do
            fn(worldobjects:get(i))
        end
    end
end

local function copyWorldObjects(worldobjects)
    local list = {}
    forEachWorldObject(worldobjects, function(obj)
        table.insert(list, obj)
    end)
    return list
end

local function collectHighLightsNear(playerObj, worldobjects)
    if not playerObj then
        return {}
    end
    local cell = getCell()
    if not cell then
        return {}
    end

    local squareSet = {}
    local function mark(square)
        if square then
            squareSet[square] = true
        end
    end

    mark(playerObj:getSquare() or playerObj:getCurrentSquare())

    forEachWorldObject(worldobjects, function(obj)
        if obj.getSquare then
            mark(obj:getSquare())
        end
    end)

    -- Mouse square at the player's floor (mesh floors often pick wrong Z otherwise).
    local mx = (getMouseXScaled and getMouseXScaled()) or getMouseX()
    local my = (getMouseYScaled and getMouseYScaled()) or getMouseY()
    local z = playerObj:getZ()
    local playerNum = playerObj:getPlayerNum()
    if screenToIsoX and screenToIsoY then
        mark(cell:getGridSquare(screenToIsoX(playerNum, mx, my, z), screenToIsoY(playerNum, mx, my, z), z))
    end
    if ISCoordConversion and ISCoordConversion.ToWorld then
        local zoom = getCore():getZoom(playerNum)
        local wx, wy = ISCoordConversion.ToWorld(mx * zoom, my * zoom, z)
        mark(cell:getGridSquare(wx, wy, z))
    end

    local scan = {}
    for square, _ in pairs(squareSet) do
        local x, y, zz = square:getX(), square:getY(), square:getZ()
        for dx = -1, 1 do
            for dy = -1, 1 do
                local sq = cell:getGridSquare(x + dx, y + dy, zz)
                if sq then
                    scan[sq] = true
                end
            end
        end
    end

    local lights, seen = {}, {}
    for square, _ in pairs(scan) do
        local objects = square:getObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if isHighLightSwitch(obj) and not seen[obj] and chebyshev(playerObj, square) <= 2 then
                    seen[obj] = true
                    table.insert(lights, obj)
                end
            end
        end
    end
    return lights
end

local function pickBestLight(playerObj, worldobjects)
    local lights = collectHighLightsNear(playerObj, worldobjects)
    local best, bestDist = nil, 999
    for i = 1, #lights do
        local light = lights[i]
        local d = chebyshev(playerObj, light:getSquare())
        -- Prefer floating / railing lamps over ordinary wall ones when both exist.
        if hasRealWall(light) then
            d = d + 0.1
        end
        if d < bestDist then
            bestDist = d
            best = light
        end
    end
    return best
end

local function contextHasOptionNamed(context, name)
    if not context or not name or not context.options then
        return false
    end
    local n = context.numOptions or 0
    for i = 1, n do
        local opt = context.options[i]
        if opt and opt.name == name then
            return true
        end
    end
    return false
end

--- Force the light into fetch BEFORE menu entries are built.
local function onPreFill(player, context, worldobjects, test)
    if not LayeredPlacement.allowLightInteract() then
        return
    end
    local fetch = ISWorldObjectContextMenu.fetchVars
    if not fetch then
        return
    end
    local playerObj = getSpecificPlayer(player)
    local light = pickBestLight(playerObj, worldobjects)
    if not light then
        return
    end
    if not fetch.lightSwitch then
        fetch.lightSwitch = light
        if ISWorldObjectContextMenuLogic and ISWorldObjectContextMenuLogic.fetch then
            ISWorldObjectContextMenuLogic.fetch(fetch, light, player, true)
        end
        LayeredPlacement.log("prefill light " .. tostring(light:getSprite() and light:getSprite():getName()))
    end
end

--- If vanilla still didn't add the lamp row, add it ourselves.
local function onFill(player, context, worldobjects, test)
    if not LayeredPlacement.allowLightInteract() or not context then
        return
    end
    local playerObj = getSpecificPlayer(player)
    local light = pickBestLight(playerObj, worldobjects)
    if not light then
        return
    end
    local fetch = ISWorldObjectContextMenu.fetchVars
    if fetch then
        fetch.lightSwitch = light
    end
    local title = light:getTileName()
    if contextHasOptionNamed(context, title) then
        return
    end
    if test then
        ISWorldObjectContextMenu.Test = true
        return true
    end
    ISWorldObjectContextMenu.doLightSwitchOption(false, context, player)
    LayeredPlacement.log("fill light menu " .. tostring(title))
end

Events.OnPreFillWorldObjectContextMenu.Add(onPreFill)
Events.OnFillWorldObjectContextMenu.Add(onFill)

-- Keep createMenu inject, but always pass a Lua table (Java lists ignore table.insert).
local _createMenu = ISWorldObjectContextMenu.createMenu

function ISWorldObjectContextMenu.createMenu(player, worldobjects, x, y, test)
    if not LayeredPlacement.allowLightInteract() then
        return _createMenu(player, worldobjects, x, y, test)
    end
    local list = copyWorldObjects(worldobjects)
    local playerObj = getSpecificPlayer(player)
    local lights = collectHighLightsNear(playerObj, list)
    for i = 1, #lights do
        local light = lights[i]
        local found = false
        for j = 1, #list do
            if list[j] == light then
                found = true
                break
            end
        end
        if not found then
            table.insert(list, light)
        end
    end
    return _createMenu(player, list, x, y, test)
end

local function isFloatingHighLight(light)
    return isHighLightSwitch(light) and not hasRealWall(light)
end

local _onToggleLight = ISWorldObjectContextMenu.onToggleLight

function ISWorldObjectContextMenu.onToggleLight(worldobjects, light, player)
    if LayeredPlacement.allowLightInteract() and isFloatingHighLight(light) then
        local playerObj = getSpecificPlayer(player)
        if not playerObj or light:getObjectIndex() == -1 then
            return
        end
        local sq = light:getSquare()
        if sq and nearbyOrWalk(playerObj, sq) then
            ISTimedActionQueue.add(ISToggleLightAction:new(playerObj, light))
        end
        return
    end
    return _onToggleLight(worldobjects, light, player)
end

local _onLightBulb = ISWorldObjectContextMenu.onLightBulb

function ISWorldObjectContextMenu.onLightBulb(worldobjects, light, player, remove, bulbitem)
    if LayeredPlacement.allowLightInteract() and isFloatingHighLight(light) then
        local playerObj = getSpecificPlayer(player)
        local sq = light:getSquare()
        if not (playerObj and sq and nearbyOrWalk(playerObj, sq)) then
            return
        end
        if remove then
            ISTimedActionQueue.add(ISLightActions:new("RemoveLightBulb", playerObj, light))
        else
            ISWorldObjectContextMenu.transferIfNeeded(playerObj, bulbitem)
            ISTimedActionQueue.add(ISLightActions:new("AddLightBulb", playerObj, light, bulbitem))
        end
        return
    end
    return _onLightBulb(worldobjects, light, player, remove, bulbitem)
end

local _isSomethingTo = ISWorldObjectContextMenu.isSomethingTo

function ISWorldObjectContextMenu.isSomethingTo(item, player)
    if LayeredPlacement.allowLightInteract() and isFloatingHighLight(item) then
        local playerObj = getSpecificPlayer(player)
        if playerObj and item:getSquare() and chebyshev(playerObj, item:getSquare()) <= 2 then
            return false
        end
    end
    return _isSomethingTo(item, player)
end

local clickHooked = false

local function hookClickHandler()
    if clickHooked then
        return
    end
    if not ISObjectClickHandler or not ISObjectClickHandler.doClickLightSwitch then
        return
    end
    clickHooked = true

    local _doClickLightSwitch = ISObjectClickHandler.doClickLightSwitch
    local _doClickSpecificObject = ISObjectClickHandler.doClickSpecificObject

    function ISObjectClickHandler.doClickLightSwitch(object, playerNum, playerObj)
        if LayeredPlacement.allowLightInteract() and isFloatingHighLight(object) then
            if object:getSquare() and object:getSquare():DistToProper(playerObj) < 2.5 then
                ISTimedActionQueue.addGetUpAndThen(playerObj, ISToggleLightAction:new(playerObj, object))
                return true
            end
            return false
        end
        return _doClickLightSwitch(object, playerNum, playerObj)
    end

    if _doClickSpecificObject then
        function ISObjectClickHandler.doClickSpecificObject(object, playerNum, playerObj)
            if LayeredPlacement.allowLightInteract() and object and not instanceof(object, "IsoLightSwitch") then
                local light = pickBestLight(playerObj, { object })
                if light and isFloatingHighLight(light) and object:getSquare() and light:getSquare() then
                    local sameOrTouching = chebyshev(playerObj, light:getSquare()) <= 2
                        and math.abs(object:getSquare():getX() - light:getSquare():getX()) <= 1
                        and math.abs(object:getSquare():getY() - light:getSquare():getY()) <= 1
                        and object:getSquare():getZ() == light:getSquare():getZ()
                    if sameOrTouching and (object:getContainer() == nil)
                        and not instanceof(object, "IsoDoor")
                        and not instanceof(object, "IsoWindow")
                    then
                        -- Only steal the click from non-interactive props (rails, etc.).
                        local name = object:getSprite() and object:getSprite():getName() or ""
                        local hoppable = object.isHoppable and object:isHoppable()
                        if hoppable or string.find(name, "rail", 1, true) or string.find(name, "fence", 1, true) then
                            return ISObjectClickHandler.doClickLightSwitch(light, playerNum, playerObj)
                        end
                    end
                end
            end
            return _doClickSpecificObject(object, playerNum, playerObj)
        end
    end

    LayeredPlacement.log("light click hook ready")
end

Events.OnGameBoot.Add(hookClickHandler)
Events.OnGameStart.Add(hookClickHandler)

LayeredPlacement.log("light interact hooks ready")
