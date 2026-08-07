LayeredPlacement = LayeredPlacement or {}

LayeredPlacement.MOD_ID = "LayeredPlacement"
LayeredPlacement.VERSION = "1.6.28"

--- ForceSingleItem multi-sprite moveables (Small Lights, etc.) report
--- CanBeDroppedOnFloor=false, so Drop / drag-to-ground no-ops and only Place
--- works. Vanilla wall pickups hit the same flag; floating pickup puts those
--- items in inventory more often, so mark them droppable after we create them.
function LayeredPlacement.makeMoveableDroppable(item)
    if not item or not instanceof(item, "Moveable") then
        return false
    end
    if item:CanBeDroppedOnFloor() then
        return true
    end
    -- Only multi-sprite ForceSingleItem items use spriteGrid + that flag.
    if not item:getSpriteGrid() then
        return false
    end
    if not getNumClassFields or not getClassField then
        return false
    end
    local ok = pcall(function()
        local n = getNumClassFields(item)
        for i = 0, n - 1 do
            local field = getClassField(item, i)
            if field and field:getName() == "canBeDroppedOnFloor" then
                field:setAccessible(true)
                field:setBoolean(item, true)
                return
            end
        end
    end)
    return ok and item:CanBeDroppedOnFloor()
end

--- Fix ForceSingleItem moveables already sitting in an inventory.
function LayeredPlacement.fixInventoryMoveableDrops(container)
    if not container or not container.getItems then
        return
    end
    local items = container:getItems()
    if not items then
        return
    end
    for i = 0, items:size() - 1 do
        LayeredPlacement.makeMoveableDroppable(items:get(i))
    end
end

--- Multi-tile hanging lights on rail/void tiles often lose a partner on chunk
--- reload (empty air squares may not persist). Tag each part so we can rebuild.

function LayeredPlacement.gridPartsFromSprite(sprite)
    if not sprite or not sprite.getSpriteGrid then
        return nil
    end
    local grid = sprite:getSpriteGrid()
    if not grid then
        return nil
    end
    local parts = {}
    for gx = 0, grid:getWidth() - 1 do
        for gy = 0, grid:getHeight() - 1 do
            local spr = grid:getSprite(gx, gy)
            if spr and spr.getName then
                table.insert(parts, { n = spr:getName(), x = gx, y = gy })
            end
        end
    end
    if #parts < 2 then
        return nil
    end
    return parts, grid
end

--- Where the multi-tile object that owns this sprite starts.
--- The sprite's own slot in its grid wins over a recorded origin: a light only
--- ever sits at one offset within its footprint, while a recorded origin can be
--- wrong (older versions stamped neighbouring lights with the wrong one, and
--- that tag persists in the save).
function LayeredPlacement.gridOriginOf(obj)
    local square = obj and obj.getSquare and obj:getSquare()
    if not square then
        return nil
    end
    local spr = obj.getSprite and obj:getSprite()
    local built, spriteGrid = LayeredPlacement.gridPartsFromSprite(spr)
    if built and spriteGrid then
        return square:getX() - spriteGrid:getSpriteGridPosX(spr),
            square:getY() - spriteGrid:getSpriteGridPosY(spr),
            square:getZ(),
            built
    end
    local md = obj.getModData and obj:getModData()
    local grid = md and md.lpGrid
    if grid and grid.parts and grid.ox ~= nil and grid.oy ~= nil and grid.oz ~= nil then
        return grid.ox, grid.oy, grid.oz, grid.parts
    end
    return nil
end

--- Does this object belong to the footprint that starts at the given origin?
--- Guards every by-sprite-name lookup: two string lights hung in a row share all
--- their sprite names, so name alone would let one light claim its neighbour.
function LayeredPlacement.sameGridOrigin(obj, originX, originY, originZ)
    local ox, oy, oz = LayeredPlacement.gridOriginOf(obj)
    if ox == nil then
        return false
    end
    return ox == originX and oy == originY and oz == originZ
end

--- True only when the object provably belongs to a *different* footprint. Used
--- where the old behaviour must stand for objects we cannot place (lit sprite
--- variants, untagged leftovers): those answer nil and are left alone.
function LayeredPlacement.foreignGridPart(obj, originX, originY, originZ)
    local ox, oy, oz = LayeredPlacement.gridOriginOf(obj)
    if ox == nil then
        return false
    end
    return ox ~= originX or oy ~= originY or oz ~= originZ
end

function LayeredPlacement.tagMultiGridObject(obj, originX, originY, originZ, parts)
    if not obj or not obj.getModData or not parts or #parts < 2 then
        return
    end
    if originX == nil or originY == nil or originZ == nil then
        return
    end
    local md = obj:getModData()
    md.lpGrid = {
        ox = originX,
        oy = originY,
        oz = originZ,
        parts = parts,
    }
    if obj.transmitModData then
        pcall(function()
            obj:transmitModData()
        end)
    end
end

--- Find an object on a square whose sprite name matches.
function LayeredPlacement.findSpriteObject(square, spriteName)
    if not square or not spriteName or not square.getObjects then
        return nil
    end
    local objects = square:getObjects()
    if not objects then
        return nil
    end
    for i = objects:size() - 1, 0, -1 do
        local obj = objects:get(i)
        local spr = obj and obj:getSprite()
        if spr and spr:getName() == spriteName then
            return obj
        end
    end
    return nil
end

--- Spawn one hanging-decor sprite (same path as floating place). Shared so
--- LoadGridsquare restore can rebuild missing multi-tile partners.
function LayeredPlacement.spawnDecorSprite(square, spriteName, desiredLightState)
    if not square or not spriteName or not LayeredPlacement.canMutateWorld() then
        return nil
    end
    local spr = getSprite(spriteName)
    if not spr then
        return nil
    end
    local obj = nil
    local ok, err = pcall(function()
        local tileType = spr:getType()
        if tileType == IsoObjectType.lightswitch then
            obj = IsoLightSwitch.new(getCell(), square, spr, square:getRoomID())
            if obj.addLightSourceFromSprite then
                obj:addLightSourceFromSprite()
            end
        else
            obj = IsoObject.new(getCell(), square, spr)
        end
        square:AddSpecialObject(obj)
        if obj and instanceof(obj, "IsoLightSwitch") and LayeredPlacement.preparePlacedLight then
            local md = obj.getModData and obj:getModData()
            local wantOn = desiredLightState
            if md and md.lpWantOn ~= nil then
                wantOn = md.lpWantOn and true or false
            end
            if wantOn == nil then
                wantOn = true
            end
            LayeredPlacement.preparePlacedLight(obj, wantOn)
        end
        if isServer() and obj and obj.transmitCompleteItemToClients then
            obj:transmitCompleteItemToClients()
        end
        if square.RecalcProperties then
            square:RecalcProperties()
        end
        if square.RecalcAllWithNeighbours then
            square:RecalcAllWithNeighbours(true)
        end
        LayeredPlacement.markConstruction(square)
        triggerEvent("OnObjectAdded", obj)
    end)
    if not ok then
        LayeredPlacement.log("spawnDecorSprite failed: " .. tostring(err))
        return nil
    end
    return obj
end

--- Rebuild any missing multi-tile partners recorded on this object.
function LayeredPlacement.restoreMultiGridPartners(obj)
    if not obj or not LayeredPlacement.canMutateWorld() then
        return false
    end
    local square = obj.getSquare and obj:getSquare()
    local spr = obj.getSprite and obj:getSprite()
    if not square or not spr then
        return false
    end

    local md = obj.getModData and obj:getModData()
    local desiredLightState = md and md.lpWantOn
    if desiredLightState == nil and instanceof(obj, "IsoLightSwitch") and obj.isActivated then
        desiredLightState = obj:isActivated() and true or false
    end

    local originX, originY, originZ, parts = LayeredPlacement.gridOriginOf(obj)
    if not parts then
        return false
    end

    local restored = 0
    for i = 1, #parts do
        local part = parts[i]
        if part and part.n and part.x ~= nil and part.y ~= nil then
            local sq = LayeredPlacement.ensureGridSquare(
                originX + part.x, originY + part.y, originZ, true
            )
            if sq then
                LayeredPlacement.markConstruction(sq)
                local existing = LayeredPlacement.findSpriteObject(sq, part.n)
                if not existing then
                    local spawned = LayeredPlacement.spawnDecorSprite(
                        sq, part.n, desiredLightState
                    )
                    if spawned then
                        LayeredPlacement.tagMultiGridObject(
                            spawned, originX, originY, originZ, parts
                        )
                        restored = restored + 1
                    end
                elseif LayeredPlacement.sameGridOrigin(existing, originX, originY, originZ) then
                    LayeredPlacement.tagMultiGridObject(
                        existing, originX, originY, originZ, parts
                    )
                    if desiredLightState ~= nil and instanceof(existing, "IsoLightSwitch")
                        and LayeredPlacement.preparePlacedLight
                    then
                        LayeredPlacement.preparePlacedLight(existing, desiredLightState)
                    end
                end
            end
        end
    end
    if restored > 0 then
        LayeredPlacement.tagMultiGridObject(obj, originX, originY, originZ, parts)
        LayeredPlacement.log("restored " .. tostring(restored) .. " multi-grid part(s)")
    end
    return restored > 0
end

function LayeredPlacement.restoreMultiGridOnSquare(square)
    if not square or not square.getObjects or not LayeredPlacement.canMutateWorld() then
        return
    end
    local objects = square:getObjects()
    if not objects then
        return
    end
    -- Copy refs first; restore may AddSpecialObject mid-loop.
    local candidates = {}
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local md = obj.getModData and obj:getModData()
            local spr = obj.getSprite and obj:getSprite()
            local grid = spr and spr.getSpriteGrid and spr:getSpriteGrid()
            -- Only objects this mod placed. Treating every vanilla multi-tile
            -- light as a candidate let the restore pass spawn and re-tag map
            -- lights it does not own.
            local owned = md and (md.lpGrid or md.lpBatteryLight or md.lpWantOn ~= nil)
            if owned and grid then
                table.insert(candidates, obj)
            end
        end
    end
    for i = 1, #candidates do
        LayeredPlacement.restoreMultiGridPartners(candidates[i])
    end
end

--- Per-player feature preferences (defaults on). Sandbox Options set the
--- server/world ceiling; clients may still opt out through Mod Options.
LayeredPlacement.options = LayeredPlacement.options or {
    layeredPlace = true,   -- lights over furniture/posters, multiple highs, wall decor together
    floatingPlace = true,  -- railings / catwalks / wall lamps without a solid wall
    meshFloorAim = true,   -- Place/Pickup aim at your floor when the mouse falls through mesh
    catwalkReach = true,   -- place/pickup when you're next to a tile but pathing fails
    lightInteract = true,  -- easier turn on/off and right-click for railing lamps
}

--- Support-facing log: one line per real event (boot, place, pickup, server
--- command, rejection). Always printed so a player can send console.txt without
--- launching the game in debug mode.
function LayeredPlacement.log(msg)
    print("[LayeredPlacement] " .. tostring(msg))
end

--- Verbose diagnostics for paths that run every render frame or every context
--- menu build. Debug-only: always printing these floods console.txt.
LayeredPlacement.DEBUG = false

function LayeredPlacement.trace(msg)
    if LayeredPlacement.DEBUG or (getDebug and getDebug()) then
        LayeredPlacement.log(msg)
    end
end

function LayeredPlacement.environment()
    if isServer() then
        return "server"
    end
    if isClient() then
        return "client"
    end
    return "singleplayer"
end

--- True when this process may create/persist world objects.
--- Pure MP clients must not AddSpecialObject locally — those ghosts vanish on
--- rejoin while the inventory remove already synced. A co-op host runs the
--- server as its own process, so the host's game is a pure client too: only
--- singleplayer and the server process may mutate the world.
function LayeredPlacement.canMutateWorld()
    if isClient() and not isServer() then
        return false
    end
    return true
end

--- Mark the chunk so placed moveables are written on save (vanilla does this
--- in ISMoveablesAction:complete; our brush path must too).
function LayeredPlacement.markConstruction(square)
    if not square then
        return
    end
    if buildUtil and buildUtil.setHaveConstruction then
        buildUtil.setHaveConstruction(square, true)
    end
end

--- Requests we sent to the server and have not heard back about. A missing
--- reply almost always means the mod is not enabled on the server, which is
--- otherwise a completely silent failure for the player.
local pendingRequests = {}
local pendingCount = 0
local REPLY_TIMEOUT_MS = 8000

local function nowMs()
    if getTimestampMs then
        return getTimestampMs()
    end
    return 0
end

local function notePending(command, square, spriteName)
    if not square then
        return
    end
    local key = command .. "|" .. tostring(square:getX()) .. "," .. tostring(square:getY())
        .. "," .. tostring(square:getZ()) .. "|" .. tostring(spriteName)
    if not pendingRequests[key] then
        pendingCount = pendingCount + 1
    end
    pendingRequests[key] = nowMs()
    return key
end

local function clearPending(command, args)
    if not args then
        return
    end
    local key = command .. "|" .. tostring(args.x) .. "," .. tostring(args.y)
        .. "," .. tostring(args.z) .. "|" .. tostring(args.spriteName)
    if pendingRequests[key] then
        pendingRequests[key] = nil
        pendingCount = pendingCount - 1
    end
end

local function watchPendingRequests()
    if pendingCount <= 0 then
        return
    end
    local now = nowMs()
    for key, sent in pairs(pendingRequests) do
        if now - sent > REPLY_TIMEOUT_MS then
            pendingRequests[key] = nil
            pendingCount = pendingCount - 1
            LayeredPlacement.log("no server reply for " .. tostring(key)
                .. " — is Layered Placement enabled and up to date on the server?")
        end
    end
end

local function onServerReply(module, command, args)
    if module ~= LayeredPlacement.MOD_ID or command ~= "requestResult" then
        return
    end
    clearPending(tostring(args and args.request), args)
    if args and args.ok then
        LayeredPlacement.log("server confirmed " .. tostring(args.request)
            .. " @ " .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z))
    else
        LayeredPlacement.log("server refused " .. tostring(args and args.request)
            .. ": " .. tostring(args and args.reason or "unknown"))
    end
end

if Events and Events.OnServerCommand and Events.OnTick then
    Events.OnServerCommand.Add(onServerReply)
    Events.OnTick.Add(watchPendingRequests)
end

--- Send one world-action request to the authoritative server. Pure MP clients
--- only; returns true when the command went out so the caller stops here.
--- spriteName must be the *current facing* sprite (what the ghost shows);
--- origSpriteName is for the server-side inventory lookup.
local function requestWorldAction(command, character, square, spriteName, origSpriteName, cursorFacing)
    if LayeredPlacement.canMutateWorld() then
        return false
    end
    if not character or not square or not spriteName or not sendClientCommand then
        return false
    end
    sendClientCommand(character, LayeredPlacement.MOD_ID, command, {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        spriteName = spriteName,
        origSpriteName = origSpriteName or spriteName,
        cursorFacing = cursorFacing,
        version = LayeredPlacement.VERSION,
    })
    notePending(command, square, spriteName)
    LayeredPlacement.log("client requested " .. command .. " @ "
        .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
        .. " sprite=" .. tostring(spriteName)
        .. " face=" .. tostring(cursorFacing))
    return true
end

--- Ask the server to place/pick floating decor (MP clients only).
function LayeredPlacement.requestFloatingWorldAction(character, square, spriteName, mode, origSpriteName, cursorFacing)
    local command = (mode == "pickup") and "pickUpFloating" or "placeFloating"
    return requestWorldAction(command, character, square, spriteName, origSpriteName, cursorFacing)
end

--- Ask the server to perform a layered wall-object place. Timed actions only
--- complete on the client, so the occupied-tile override has no authority in
--- co-op or on a dedicated server: the server has to do the work. Its inventory
--- lookup keeps duplicate or replayed requests idempotent.
function LayeredPlacement.requestLayeredPlace(character, square, spriteName, origSpriteName, cursorFacing)
    return requestWorldAction("placeLayered", character, square, spriteName, origSpriteName, cursorFacing)
end

local SANDBOX_OPTION_NAMES = {
    layeredPlace = "LayeredPlace",
    floatingPlace = "FloatingPlace",
    meshFloorAim = "MeshFloorAim",
    catwalkReach = "CatwalkReach",
    lightInteract = "LightInteract",
}

--- Missing values mean enabled so old saves and main-menu contexts retain the
--- behavior they had before server permissions were added.
function LayeredPlacement.serverAllows(name)
    local optionName = SANDBOX_OPTION_NAMES[name]
    if not optionName then
        return false
    end
    local vars = SandboxVars and SandboxVars.LayeredPlacement
    if not vars or vars[optionName] == nil then
        return true
    end
    return vars[optionName] ~= false
end

local function flag(name)
    local opts = LayeredPlacement.options
    if opts and opts[name] == false then
        return false
    end
    return LayeredPlacement.serverAllows(name)
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

--- Lights this mod placed or opted into battery power. Their on/off state is
--- ours to persist even with the easier controls off, otherwise a vanilla toggle
--- gets undone by the state we restore on chunk load.
function LayeredPlacement.managesLight(obj)
    if not obj or not obj.getModData or not instanceof(obj, "IsoLightSwitch") then
        return false
    end
    local md = obj:getModData()
    if not md then
        return false
    end
    return (md.lpBatteryLight or md.lpGrid or md.lpWantOn ~= nil) and true or false
end

--- True when this square/light should run on battery (no building power path).
--- Indoor / powered-room lights must stay on building electricity.
function LayeredPlacement.lightShouldUseBattery(obj)
    if not obj or not instanceof(obj, "IsoLightSwitch") then
        return false
    end
    local square = obj.getSquare and obj:getSquare()
    if not square then
        return true
    end
    -- Match IsoLightSwitch.hasElectricityAround's ordering. During grid power,
    -- haveElectricity() alone is too broad: exterior railing squares can report
    -- power even though a light switch there cannot consume it.
    local hasGridPower = square.hasGridPower and square:hasGridPower()
    local isBuildingSquare = (square.getRoom and square:getRoom())
        or (square.getRoofHideBuilding and square:getRoofHideBuilding())
    if hasGridPower then
        if isBuildingSquare then
            return false
        end
        -- Fascia objects are powered through their attached building square.
        local objects = square.getObjects and square:getObjects()
        if objects then
            for i = 0, objects:size() - 1 do
                local candidate = objects:get(i)
                if candidate and candidate.isFascia and candidate:isFascia()
                    and candidate.getFasciaAttachedSquare
                then
                    local attached = candidate:getFasciaAttachedSquare()
                    if attached and ((attached.getRoom and attached:getRoom())
                        or (attached.getRoofHideBuilding and attached:getRoofHideBuilding()))
                    then
                        return false
                    end
                end
            end
        end
        return true
    end
    if square.haveElectricity and square:haveElectricity() then
        return false
    end
    return true
end

--- Apply power + optional on-state. Battery mode only when the tile has no
--- building/room electricity path (railings, outdoors, void air).
function LayeredPlacement.preparePlacedLight(obj, desired)
    if not obj or not instanceof(obj, "IsoLightSwitch") then
        return false
    end
    local ok, err = pcall(function()
        local needBattery = LayeredPlacement.lightShouldUseBattery(obj)
        if needBattery then
            -- setUseBattery() calls setActive(false) internally. Use the direct
            -- setter so preparing/refreshing battery state doesn't undo Turn On.
            if obj.setUseBatteryDirect then
                obj:setUseBatteryDirect(true)
            elseif obj.setUseBattery then
                obj:setUseBattery(true)
            end
            if obj.setHasBatteryRaw then
                obj:setHasBatteryRaw(true)
            end
            if obj.setPower then
                obj:setPower(1.0)
            end
        else
            if obj.setUseBattery then
                obj:setUseBattery(false)
            end
            if obj.setUseBatteryDirect then
                pcall(function()
                    obj:setUseBatteryDirect(false)
                end)
            end
        end
        local md = obj:getModData()
        if md then
            md.lpBatteryLight = needBattery and true or false
            if desired == nil then
                if md.lpWantOn == nil and obj.isActivated then
                    md.lpWantOn = obj:isActivated() and true or false
                end
            else
                md.lpWantOn = desired and true or false
            end
        end
        local wantOn = desired
        if wantOn == nil and md then
            wantOn = md.lpWantOn
        end
        if wantOn ~= nil and obj.isActivated
            and obj:isActivated() ~= (wantOn and true or false)
        then
            local applied = false
            if obj.setActive then
                pcall(function()
                    obj:setActive(wantOn and true or false, false, true)
                end)
                applied = obj:isActivated() == (wantOn and true or false)
            end
            if not applied and obj.switchLight then
                obj:switchLight(wantOn and true or false)
            elseif not applied and obj.toggle then
                obj:toggle()
            end
        end
        if needBattery then
            if obj.setUseBatteryDirect then
                obj:setUseBatteryDirect(true)
            end
            if obj.setHasBatteryRaw then
                obj:setHasBatteryRaw(true)
            end
            if obj.setPower then
                obj:setPower(1.0)
            end
        end
        if md then
            md.lpWantOn = obj.isActivated and obj:isActivated() or (wantOn and true or false)
            md.lpBatteryLight = needBattery and true or false
        end
        local square = obj:getSquare()
        local inWorld = square and obj:getObjectIndex() ~= -1
        if inWorld then
            if obj.syncCustomizedSettings then
                obj:syncCustomizedSettings(nil)
            end
            if obj.syncIsoObject then
                obj:syncIsoObject(false, 0, nil)
            end
            if obj.transmitModData then
                obj:transmitModData()
            end
            LayeredPlacement.markConstruction(square)
        end
    end)
    if not ok then
        LayeredPlacement.log("preparePlacedLight failed: " .. tostring(err))
        return false
    end
    return true
end

--- Every IsoLightSwitch that belongs to the same multi-tile hanging light.
--- Single-tile lights just return { obj }.
function LayeredPlacement.collectLightGroup(obj)
    local group = {}
    if not obj or not instanceof(obj, "IsoLightSwitch") then
        return group
    end

    local originX, originY, originZ, parts = LayeredPlacement.gridOriginOf(obj)
    if not parts then
        table.insert(group, obj)
        return group
    end

    local cell = getCell()
    local seen = {}
    for i = 1, #parts do
        local part = parts[i]
        if part and part.n and part.x ~= nil and part.y ~= nil then
            -- Look up only. Creating squares to read a light's state would spawn
            -- air tiles across the footprint.
            local sq = cell and cell:getGridSquare(originX + part.x, originY + part.y, originZ)
            local found = LayeredPlacement.findSpriteObject(sq, part.n)
            if found and instanceof(found, "IsoLightSwitch") and not seen[found]
                and LayeredPlacement.sameGridOrigin(found, originX, originY, originZ)
            then
                seen[found] = true
                table.insert(group, found)
            end
        end
    end
    if #group == 0 then
        table.insert(group, obj)
    elseif not seen[obj] then
        table.insert(group, 1, obj)
    end
    return group
end

--- Set on/off for a light and every multi-tile partner.
function LayeredPlacement.setLightGroupState(obj, desired)
    local group = LayeredPlacement.collectLightGroup(obj)
    local any = false
    for i = 1, #group do
        if LayeredPlacement.preparePlacedLight(group[i], desired) then
            any = true
        end
    end
    return any
end

--- Toggle immediately in SP/listen-host, or ask the dedicated server to do it.
--- Always applies the full multi-tile group so string lights don't half-lit.
function LayeredPlacement.requestLightState(character, obj, desired)
    if not character or not obj or not obj:getSquare() then
        return false
    end
    desired = desired and true or false
    if LayeredPlacement.canMutateWorld() then
        return LayeredPlacement.setLightGroupState(obj, desired)
    end
    if not sendClientCommand then
        return false
    end
    -- Optimistic local visual so the menu click isn't a no-op while waiting
    -- for the server packet (still authoritative via setLightState).
    LayeredPlacement.setLightGroupState(obj, desired)
    local square = obj:getSquare()
    sendClientCommand(character, "LayeredPlacement", "setLightState", {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        objectIndex = obj:getObjectIndex(),
        spriteName = obj:getSprite() and obj:getSprite():getName() or nil,
        desired = desired,
    })
    return true
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

--- Max same-floor distance for the floating-decor helpers. Without a cap the
--- pathing skip would let you place/pick decor anywhere on your Z level.
LayeredPlacement.REACH_DIST = 3
LayeredPlacement.CHEAT_REACH = 4
--- Looking down from a catwalk onto a ground-floor wall is Z-diff 1.
LayeredPlacement.BRUSH_MAX_Z = 1

function LayeredPlacement.chebyshev(squareA, squareB)
    if not squareA or not squareB then
        return 999
    end
    local dx = math.abs(squareA:getX() - squareB:getX())
    local dy = math.abs(squareA:getY() - squareB:getY())
    if dx > dy then
        return dx
    end
    return dy
end

function LayeredPlacement.withinReach(character, square, dist, maxZ)
    local charSq = character and (character:getSquare() or character:getCurrentSquare())
    if not charSq or not square then
        return false
    end
    local dz = math.abs(charSq:getZ() - square:getZ())
    if maxZ == nil then
        if dz ~= 0 then
            return false
        end
    elseif dz > maxZ then
        return false
    end
    return LayeredPlacement.chebyshev(charSq, square) <= (dist or LayeredPlacement.REACH_DIST)
end

--- Brush-style reach for floating highs: same floor or one level away (catwalk → ground wall).
function LayeredPlacement.withinBrushReach(character, square)
    return LayeredPlacement.withinReach(
        character, square, LayeredPlacement.CHEAT_REACH, LayeredPlacement.BRUSH_MAX_Z
    )
end

--- Hanging decor: lamps, chandeliers, canopies, string lights, bunting.
--- Deliberately narrow. MoveType defaults to "Object" for every moveable without
--- one, so keying on IsLow too would sweep in ~1900 ordinary furniture tiles
--- (ovens, washers, tables, fridges) and let them be placed in mid-air.
function LayeredPlacement.isHangingDecor(props)
    if not props or not props.isMoveable or not props.isHigh then
        return false
    end
    if props.type ~= "Object" then
        return false
    end
    if props.isTable or props.isTableTop or props.isStackable or props.isWaterCollector then
        return false
    end
    if props.isoType and props.isoType ~= "IsoObject" and props.isoType ~= "IsoLightSwitch" then
        return false
    end
    if props.spriteProps and props.spriteProps:has("container") then
        return false
    end
    return true
end

function LayeredPlacement.isWallDecor(props)
    if not props or not props.isMoveable then
        return false
    end
    local t = props.type
    return t == "WallObject" or t == "WallOverlay" or t == "WindowObject"
end

--- Everything whose placement rules this mod is allowed to relax.
--- Wall-attached types still go through the vanilla attach path; only the
--- "tile is already occupied" and "needs a floor" rules are touched.
function LayeredPlacement.isPlacementDecor(props)
    return LayeredPlacement.isHangingDecor(props) or LayeredPlacement.isWallDecor(props)
end

--- Wider set for the pathing/adjacency helpers only. These never change what
--- may be placed, just whether you have to walk onto an awkward catwalk tile.
function LayeredPlacement.isReachDecor(props)
    if not props or not props.isMoveable then
        return false
    end
    if props.isHigh or props.isLow then
        return true
    end
    return LayeredPlacement.isWallDecor(props)
end

--- Hanging decor placed on railings/catwalk edges, when that helper is enabled.
function LayeredPlacement.isFloatingDecor(props)
    return LayeredPlacement.allowFloatingPlace() and LayeredPlacement.isHangingDecor(props)
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

--- Score a square for pickup aiming (prefer high/low decor already on the tile).
local function pickupAimScore(square)
    if not square or not square.getObjects then
        return -1
    end
    local objects = square:getObjects()
    if not objects then
        return 0
    end
    local score = 0
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local spr = obj and obj:getSprite()
        local props = spr and spr:getProperties()
        if props and props:has("IsMoveAble") then
            score = score + 1
            if props:has("IsHigh") or props:has("IsLow") then
                score = score + 4
            end
        end
        -- Wall-overlay moveables live as child sprites on walls/railings.
        if obj and obj.getChildSprites then
            local kids = obj:getChildSprites()
            if kids then
                for j = 0, kids:size() - 1 do
                    local child = kids:get(j)
                    local cspr = child and child:getParentSprite()
                    local cprops = cspr and cspr:getProperties()
                    if cprops and cprops:has("IsMoveAble") then
                        score = score + 1
                        if cprops:has("IsHigh") or cprops:has("IsLow") then
                            score = score + 4
                        end
                    end
                end
            end
        end
    end
    return score
end

--- Create or fetch a grid square. force=true skips the isValidSquare gate so
--- catwalk/railing edge tiles (often "invalid" but still placeable) can exist.
function LayeredPlacement.ensureGridSquare(x, y, z, force)
    local cell = getCell()
    if not cell or x == nil or y == nil or z == nil then
        return nil
    end
    local sq = cell:getGridSquare(x, y, z)
    if sq then
        return sq
    end
    if cell.getOrCreateGridSquare then
        local ok, created = pcall(function()
            return cell:getOrCreateGridSquare(x, y, z)
        end)
        if ok and created then
            return created
        end
    end
    local world = getWorld and getWorld() or nil
    if not force and world and world.isValidSquare and not world:isValidSquare(x, y, z) then
        return nil
    end
    local ok, created = pcall(function()
        return cell:createNewGridSquare(x, y, z, true)
    end)
    if ok and created then
        return created
    end
    return nil
end

--- Lift a below-player square up to the player's Z (mesh fallthrough).
--- Returns nil when we cannot get an upstairs tile — callers should treat that
--- as "not here" rather than placing on the ground under the catwalk.
function LayeredPlacement.liftToPlayerZ(character, square, playerNum)
    if not character or not square then
        return square
    end
    local charSq = character:getSquare() or character:getCurrentSquare()
    if not charSq then
        return square
    end
    local pz = charSq:getZ()
    if square:getZ() >= pz then
        return square
    end
    local cell = getCell()
    if not cell then
        return nil
    end
    local x, y = square:getX(), square:getY()
    if screenToIsoX and screenToIsoY and getMouseX and getMouseY then
        local pn = playerNum
        if pn == nil and character.getPlayerNum then
            pn = character:getPlayerNum()
        end
        if pn ~= nil then
            local wx = screenToIsoX(pn, getMouseX(), getMouseY(), pz)
            local wy = screenToIsoY(pn, getMouseX(), getMouseY(), pz)
            if wx and wy then
                x = math.floor(wx)
                y = math.floor(wy)
            end
        end
    end
    -- Force-create: railing edges are often isValidSquare=false.
    local lifted = LayeredPlacement.ensureGridSquare(x, y, pz, true)
    if lifted then
        return lifted
    end
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    lifted = LayeredPlacement.ensureGridSquare(x + dx, y + dy, pz, true)
                    if lifted then
                        return lifted
                    end
                end
            end
        end
    end
    return nil
end

--- Walk to a same-Z floor tile next to a floating railing/catwalk square.
--- keepActions=true so an existing path/queue from tryBuild isn't wiped.
function LayeredPlacement.walkToNearbyFloor(character, square, keepActions)
    if not character or not square or not luautils or not luautils.walkAdj then
        return false
    end
    local cell = getCell()
    if not cell then
        return false
    end
    local z = square:getZ()
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if not (dx == 0 and dy == 0) then
                    local sq = cell:getGridSquare(square:getX() + dx, square:getY() + dy, z)
                    if sq and sq:getFloor() and luautils.walkAdj(character, sq, keepActions ~= false) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function getOrCreateSquare(cell, x, y, z, force)
    return LayeredPlacement.ensureGridSquare(x, y, z, force)
end

--- When the mouse hits a tall pillar/ground, the reprojected XY may be empty.
--- Pickup: keep the exact tile if it has decor; only then search neighbors.
--- Place: force-create upstairs tiles (railing edges are often "invalid").
local function findBestSquareAtPlayerZ(cell, x, y, pz, mode)
    local force = mode == "place"
    local exact = getOrCreateSquare(cell, x, y, pz, force)

    if mode == "pickup" then
        -- Score the whole small search area. Returning the first moveable on
        -- the projected tile made floor trash/tables steal the cursor from a
        -- nearby high light that the player was visibly aiming at.
        local exactScore = pickupAimScore(exact)
        local best, bestScore, bestDist = nil, 0, 999
        if exactScore > 0 then
            best, bestScore, bestDist = exact, exactScore, 0
        end
        local radius = 2
        for dx = -radius, radius do
            for dy = -radius, radius do
                if not (dx == 0 and dy == 0) then
                    local dist = math.max(math.abs(dx), math.abs(dy))
                    local sq = cell:getGridSquare(x + dx, y + dy, pz)
                    local score = pickupAimScore(sq)
                    if score > bestScore or (score == bestScore and score > 0 and dist < bestDist) then
                        best, bestScore, bestDist = sq, score, dist
                    end
                end
            end
        end
        if bestScore > 0 then
            return best
        end
        if exact then
            return exact
        end
        for r = 1, radius do
            for dx = -r, r do
                for dy = -r, r do
                    if math.abs(dx) == r or math.abs(dy) == r then
                        local sq = cell:getGridSquare(x + dx, y + dy, pz)
                        if sq then
                            return sq
                        end
                    end
                end
            end
        end
        return nil
    end

    -- place: never silently keep the ground tile under mesh
    if exact then
        return exact
    end
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = getOrCreateSquare(cell, x + dx, y + dy, pz, true)
                    if sq then
                        return sq
                    end
                end
            end
        end
    end
    return nil
end

--- If the mouse fell through mesh to a lower Z while you're upstairs, aim at
--- your floor instead. Re-project the mouse onto the player Z plane — lifting
--- the ground tile's XY is wrong under isometric angles (common on catwalks).
--- Near tall pillars the exact XY often has no upper square; snap to a nearby
--- player-Z tile (decor for pickup, force-create for place).
---
--- Place: only remap Object-type floating highs (lights). Wall hangings
--- (posters/paintings) must keep the aimed wall square — lifting them to an
--- empty upstairs tile greens the cursor then eats the item with nothing shown.
--- Pickup: still remap any high/low so mesh fallthrough finds upstairs decor.
--- mode: optional "pickup" / "place" (nil defaults to place-style scoring)
function LayeredPlacement.resolveFloatingSquare(character, square, props, playerNum, mode)
    if not LayeredPlacement.allowMeshFloorAim() then
        return square
    end
    if not square then
        return square
    end
    local aimMode = mode or "place"
    if props then
        if aimMode == "pickup" then
            if not (props.isHigh or props.isLow) then
                return square
            end
        elseif not LayeredPlacement.isFloatingDecor(props) then
            return square
        end
    end
    if not character then
        return square
    end
    local charSq = character:getSquare() or character:getCurrentSquare()
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
    if screenToIsoX and screenToIsoY and getMouseX and getMouseY then
        local pn = playerNum
        if pn == nil and character.getPlayerNum then
            pn = character:getPlayerNum()
        end
        if pn ~= nil then
            local wx = screenToIsoX(pn, getMouseX(), getMouseY(), pz)
            local wy = screenToIsoY(pn, getMouseX(), getMouseY(), pz)
            if wx and wy then
                x = math.floor(wx)
                y = math.floor(wy)
            end
        end
    end

    local atPlayer = findBestSquareAtPlayerZ(cell, x, y, pz, aimMode)
    if atPlayer then
        LayeredPlacement.trace(
            "float Z " .. tostring(square:getZ())
                .. " -> " .. tostring(pz)
                .. " @" .. tostring(atPlayer:getX()) .. "," .. tostring(atPlayer:getY())
                .. " (" .. tostring(aimMode) .. ")"
        )
        return atPlayer
    end
    -- Could not create an upstairs tile — keep the aimed square (may be an
    -- intentional ground-floor wall place from a catwalk).
    return square
end

LayeredPlacement.log("v" .. LayeredPlacement.VERSION .. " loaded ("
    .. LayeredPlacement.environment()
    .. ", world writes " .. (LayeredPlacement.canMutateWorld() and "local" or "server-side") .. ")")
