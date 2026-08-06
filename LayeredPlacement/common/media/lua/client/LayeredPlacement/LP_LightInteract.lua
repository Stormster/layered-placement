require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"

--- High IsoLightSwitch helpers: railing/fence/catwalk lights are hard for vanilla
--- to target (isWallTo, canSwitchLight needs room power). We treat every IsHigh
--- lightswitch in reach as interactable, keep them on battery so outdoor placements
--- still switch after relog, and always expose Turn On/Off in the context menu.

local function propsOf(object)
    local spr = object and object:getSprite()
    return spr and spr:getProperties() or nil
end

local function isHighLightSwitch(object)
    if not object or not instanceof(object, "IsoLightSwitch") then
        return false
    end
    local md = object.getModData and object:getModData()
    if md and md.lpBatteryLight then
        return true
    end
    local props = propsOf(object)
    return props and props:has("IsHigh") and true or false
end

local function chebyshev(playerObj, square)
    local psq = playerObj and (playerObj:getSquare() or playerObj:getCurrentSquare())
    if not psq or not square then
        return 999
    end
    local dz = math.abs(psq:getZ() - square:getZ())
    if dz > LayeredPlacement.BRUSH_MAX_Z then
        return 999
    end
    local dx = math.abs(psq:getX() - square:getX())
    local dy = math.abs(psq:getY() - square:getY())
    return math.max(dx, dy) + dz
end

local function inLightReach(playerObj, square)
    return LayeredPlacement.withinBrushReach(playerObj, square)
end

local function nearbyOrWalk(playerObj, square)
    if inLightReach(playerObj, square) then
        return true
    end
    return luautils.walkAdj(playerObj, square) and true or false
end

--- Outdoor / railing lights have no room electricity. Battery mode keeps
--- canSwitchLight true and preserves on-state across chunk load / relog.
-- preparePlacedLight lives in LP_Shared (server + client place paths).

local function refreshBatteryLight(obj)
    if not obj or not instanceof(obj, "IsoLightSwitch") then
        return
    end
    local md = obj.getModData and obj:getModData()
    if not (md and md.lpBatteryLight) then
        return
    end
    -- Dedicated servers restore and synchronize these lights authoritatively.
    -- Avoid a client-only ghost toggle that gets overwritten on relog.
    if LayeredPlacement.canMutateWorld() then
        LayeredPlacement.preparePlacedLight(obj, md.lpWantOn)
    end
end

local function forEachWorldObject(worldobjects, fn)
    if not worldobjects then
        return
    end
    if type(worldobjects) == "table" then
        for i = 1, #worldobjects do
            if worldobjects[i] then
                fn(worldobjects[i])
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

local function mouseSquares(playerObj)
    local cell = getCell()
    if not cell or not playerObj then
        return {}
    end
    local mx = (getMouseXScaled and getMouseXScaled()) or getMouseX()
    local my = (getMouseYScaled and getMouseYScaled()) or getMouseY()
    local z = playerObj:getZ()
    local playerNum = playerObj:getPlayerNum()
    local list = {}
    if screenToIsoX and screenToIsoY then
        local sq = cell:getGridSquare(
            screenToIsoX(playerNum, mx, my, z), screenToIsoY(playerNum, mx, my, z), z
        )
        if sq then
            table.insert(list, sq)
        end
    end
    if ISCoordConversion and ISCoordConversion.ToWorld then
        local zoom = getCore():getZoom(playerNum)
        local wx, wy = ISCoordConversion.ToWorld(mx * zoom, my * zoom, z)
        local sq = cell:getGridSquare(wx, wy, z)
        if sq and sq ~= list[1] then
            table.insert(list, sq)
        end
    end
    return list
end

local function objectSquares(worldobjects)
    local list = {}
    forEachWorldObject(worldobjects, function(obj)
        if obj.getSquare then
            local sq = obj:getSquare()
            if sq then
                table.insert(list, sq)
            end
        end
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

    local clicked = objectSquares(worldobjects)
    for i = 1, #clicked do
        mark(clicked[i])
    end

    local hovered = mouseSquares(playerObj)
    for i = 1, #hovered do
        mark(hovered[i])
    end

    local scan = {}
    for square, _ in pairs(squareSet) do
        local x, y, zz = square:getX(), square:getY(), square:getZ()
        for dx = -LayeredPlacement.CHEAT_REACH, LayeredPlacement.CHEAT_REACH do
            for dy = -LayeredPlacement.CHEAT_REACH, LayeredPlacement.CHEAT_REACH do
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
                if isHighLightSwitch(obj) and not seen[obj] and inLightReach(playerObj, square) then
                    seen[obj] = true
                    table.insert(lights, obj)
                end
            end
        end
    end
    return lights
end

--- How far from the clicked tile we may still redirect to a light. Zero: only a
--- light on the very tile you clicked counts. Anything wider let a click on the
--- floor toggle a lamp the player was nowhere near aiming at.
local FOCUS_RANGE = 0

local function squareDist(a, b)
    if not a or not b then
        return 999
    end
    local dx = math.abs(a:getX() - b:getX())
    local dy = math.abs(a:getY() - b:getY())
    return math.max(dx, dy) + math.abs(a:getZ() - b:getZ())
end

local function focusDist(light, squares)
    local lsq = light and light:getSquare()
    if not lsq then
        return 999
    end
    local best = 999
    for i = 1, #squares do
        local d = squareDist(lsq, squares[i])
        if d < best then
            best = d
        end
    end
    return best
end

--- What the player pointed at. The engine already resolved sprite offsets when
--- it built the clicked-object list, so those squares beat the raw mouse tile:
--- a hanging lamp draws two tiles up from the square it actually occupies.
local function focusSquares(playerObj, worldobjects)
    local squares = objectSquares(worldobjects)
    if #squares > 0 then
        return squares
    end
    squares = mouseSquares(playerObj)
    if #squares > 0 then
        return squares
    end
    return { playerObj and (playerObj:getSquare() or playerObj:getCurrentSquare()) }
end

--- Lights the click actually landed on. A switch that is not IsHigh still counts
--- as a hit: vanilla targets those correctly, so we must leave the menu alone
--- instead of redirecting it to some other light nearby.
local function clickedLights(worldobjects)
    local high, anyLight = {}, false
    forEachWorldObject(worldobjects, function(obj)
        if instanceof(obj, "IsoLightSwitch") then
            anyLight = true
            if isHighLightSwitch(obj) then
                table.insert(high, obj)
            end
        end
    end)
    return high, anyLight
end

--- Pick the light the player aimed at, not the one nearest the player: ranking
--- by player distance turns a click on the lamp overhead into a toggle of
--- whichever light happens to be closest to where you stand.
local function pickBestLight(playerObj, worldobjects)
    if not playerObj then
        return nil
    end
    local candidates, anyLight = clickedLights(worldobjects)
    if #candidates == 0 then
        if anyLight then
            return nil
        end
        candidates = collectHighLightsNear(playerObj, worldobjects)
    end

    local focus = focusSquares(playerObj, worldobjects)
    local best, bestFocus, bestPlayer = nil, 999, 999
    for i = 1, #candidates do
        local light = candidates[i]
        local fd = focusDist(light, focus)
        if fd <= FOCUS_RANGE then
            local pd = chebyshev(playerObj, light:getSquare())
            if fd < bestFocus or (fd == bestFocus and pd < bestPlayer) then
                best, bestFocus, bestPlayer = light, fd, pd
            end
        end
    end
    return best
end

local function contextHasToggle(context)
    if not context or not context.options then
        return false
    end
    local turnOn = getText("ContextMenu_Turn_On")
    local turnOff = getText("ContextMenu_Turn_Off")
    local n = context.numOptions or 0
    for i = 1, n do
        local opt = context.options[i]
        if opt and (opt.name == turnOn or opt.name == turnOff) then
            return true
        end
        -- Submenus: option may have subOption numbers via context structure
    end
    if context.getSubMenu then
        -- Fall through — we'll still add a top-level toggle if unsure
    end
    return false
end

local function addDirectToggle(context, light, player, worldobjects)
    if not context or not light then
        return
    end
    local label = (light.isActivated and light:isActivated())
        and getText("ContextMenu_Turn_Off")
        or getText("ContextMenu_Turn_On")
    local opt = context:addGetUpOption(
        label,
        worldobjects,
        ISWorldObjectContextMenu.onToggleLight,
        light,
        player
    )
    if opt then
        opt.iconTexture = getTexture("Item_LightBulb")
    end
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
    refreshBatteryLight(light)
    fetch.lightSwitch = light
    if ISWorldObjectContextMenuLogic and ISWorldObjectContextMenuLogic.fetch then
        ISWorldObjectContextMenuLogic.fetch(fetch, light, player, true)
    end
    LayeredPlacement.trace("prefill light " .. tostring(light:getSprite() and light:getSprite():getName()))
end

--- Always expose Turn On/Off for high lights in reach (vanilla often skips when
--- canSwitchLight is false outdoors, or isSomethingTo sees a railing).
local function onFill(player, context, worldobjects, test)
    if not LayeredPlacement.allowLightInteract() or not context then
        return
    end
    local playerObj = getSpecificPlayer(player)
    local light = pickBestLight(playerObj, worldobjects)
    if not light then
        return
    end
    refreshBatteryLight(light)
    local fetch = ISWorldObjectContextMenu.fetchVars
    if fetch then
        fetch.lightSwitch = light
    end
    if test then
        ISWorldObjectContextMenu.Test = true
        return true
    end

    local title = light:getTileName()
    local hasRow = false
    local n = context.numOptions or 0
    for i = 1, n do
        local opt = context.options[i]
        if opt and opt.name == title then
            hasRow = true
            break
        end
    end
    if not hasRow then
        ISWorldObjectContextMenu.doLightSwitchOption(false, context, player)
    end

    -- Guarantee a working toggle even when canSwitchLight was false.
    if not contextHasToggle(context) then
        addDirectToggle(context, light, player, worldobjects)
        LayeredPlacement.trace("fill direct toggle " .. tostring(title))
    end
end

Events.OnPreFillWorldObjectContextMenu.Add(onPreFill)
Events.OnFillWorldObjectContextMenu.Add(onFill)

local _createMenu = ISWorldObjectContextMenu.createMenu

function ISWorldObjectContextMenu.createMenu(player, worldobjects, x, y, test)
    if not LayeredPlacement.allowLightInteract() then
        return _createMenu(player, worldobjects, x, y, test)
    end
    local list = copyWorldObjects(worldobjects)
    local playerObj = getSpecificPlayer(player)
    -- Only the aimed-at light gets added. Injecting every light in reach is what
    -- made a menu opened on one lamp show rows for lights across the room.
    local light = pickBestLight(playerObj, list)
    if light then
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

local _onToggleLight = ISWorldObjectContextMenu.onToggleLight

local function toggleHighLight(playerObj, light)
    if not playerObj or not light then
        return false
    end
    -- Stale menu refs can report objectIndex -1; re-resolve from the square.
    if light:getObjectIndex() == -1 then
        local sq = light:getSquare()
        local name = light:getSprite() and light:getSprite():getName()
        light = LayeredPlacement.findSpriteObject(sq, name) or light
        if not light or light:getObjectIndex() == -1 then
            return false
        end
    end
    if not inLightReach(playerObj, light:getSquare()) then
        return false
    end
    local desired = not (light.isActivated and light:isActivated())
    return LayeredPlacement.requestLightState(playerObj, light, desired)
end

function ISWorldObjectContextMenu.onToggleLight(worldobjects, light, player)
    if LayeredPlacement.allowLightInteract() and isHighLightSwitch(light) then
        local playerObj = getSpecificPlayer(player)
        if toggleHighLight(playerObj, light) then
            return
        end
        -- Fall through to vanilla walk+action if our path couldn't run.
    end
    return _onToggleLight(worldobjects, light, player)
end

local _onLightBulb = ISWorldObjectContextMenu.onLightBulb

function ISWorldObjectContextMenu.onLightBulb(worldobjects, light, player, remove, bulbitem)
    if LayeredPlacement.allowLightInteract() and isHighLightSwitch(light) then
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

--- Railing / fence between you and a high lamp must not block the menu toggle.
local _isSomethingTo = ISWorldObjectContextMenu.isSomethingTo

function ISWorldObjectContextMenu.isSomethingTo(item, player)
    if LayeredPlacement.allowLightInteract() and isHighLightSwitch(item) then
        local playerObj = getSpecificPlayer(player)
        if playerObj and item:getSquare() and inLightReach(playerObj, item:getSquare()) then
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
        if LayeredPlacement.allowLightInteract() and isHighLightSwitch(object) then
            return toggleHighLight(playerObj, object)
        end
        return _doClickLightSwitch(object, playerNum, playerObj)
    end

    if _doClickSpecificObject then
        function ISObjectClickHandler.doClickSpecificObject(object, playerNum, playerObj)
            if LayeredPlacement.allowLightInteract() and object then
                -- Prefer toggling a nearby high light over interacting with the
                -- railing/fence/mesh the click actually hit.
                -- pickBestLight already bounds this to the clicked tile's
                -- neighbourhood, so only the "is it worth stealing" test is left.
                local light = pickBestLight(playerObj, { object })
                if light and light ~= object and inLightReach(playerObj, light:getSquare()) then
                    local steal = instanceof(object, "IsoLightSwitch")
                        or (object.getContainer and object:getContainer() == nil
                            and not instanceof(object, "IsoDoor")
                            and not instanceof(object, "IsoWindow")
                            and not instanceof(object, "IsoThumpable"))
                    local name = object:getSprite() and object:getSprite():getName() or ""
                    local hoppable = object.isHoppable and object:isHoppable()
                    if steal or hoppable
                        or string.find(name, "rail", 1, true)
                        or string.find(name, "fence", 1, true)
                        or string.find(name, "mesh", 1, true)
                        or string.find(name, "catwalk", 1, true)
                    then
                        return ISObjectClickHandler.doClickLightSwitch(light, playerNum, playerObj)
                    end
                end
            end
            return _doClickSpecificObject(object, playerNum, playerObj)
        end
    end

    LayeredPlacement.log("light click hook ready")
end

--- After chunk load, re-apply battery power and desired on-state only for lights
--- we already marked (placed via our floating path or opted in when room power
--- could not switch them). Do not convert ordinary wall lamps.
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
        if isHighLightSwitch(obj) then
            local md = obj.getModData and obj:getModData()
            if md and md.lpBatteryLight then
                refreshBatteryLight(obj)
            end
        end
    end
end

Events.OnGameBoot.Add(hookClickHandler)
Events.OnGameStart.Add(hookClickHandler)
Events.LoadGridsquare.Add(onLoadSquare)

-- If another mod or vanilla queues the action directly, still persist the
-- resulting state through our authoritative path.
local _toggleComplete = ISToggleLightAction.complete
function ISToggleLightAction:complete()
    local result = _toggleComplete(self)
    -- Not gated on the easier controls: this only records the state of a light we
    -- already manage, and vanilla picked the target itself.
    if self.character and self.object and LayeredPlacement.managesLight(self.object) then
        local desired = self.object.isActivated and self.object:isActivated() or false
        LayeredPlacement.requestLightState(self.character, self.object, desired)
    end
    return result
end

LayeredPlacement.log("light interact hooks ready")
