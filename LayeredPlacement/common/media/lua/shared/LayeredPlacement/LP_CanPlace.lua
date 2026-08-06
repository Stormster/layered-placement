require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"
require "Moveables/ISMoveablesAction"

--- Decor we treat more like brush placement: hanging decor plus wall-attached
--- decor. Plain floor furniture (IsLow) keeps every vanilla rule.
local function isLayerDecor(props)
    return LayeredPlacement.isPlacementDecor(props)
end

--- Vanilla wall object used by WallOverlay attach. Must succeed or place
--- silently creates nothing while still consuming the inventory item.
local function getWallObjectForDecor(props, square)
    if not props or not square or not props.facing then
        return nil
    end
    if props.type == "WindowObject" then
        return props:getWallForFacing(square, props.facing, "WindowFrame")
    end
    if props.allowDoorFrame then
        return props:getWallForFacing(square, props.facing, "WallAndDoor")
    end
    return props:getWallForFacing(square, props.facing)
end

local function hasWallForDecor(props, square)
    return getWallObjectForDecor(props, square) and true or false
end

--- True when this square (or the facing-adjacent one) has any wall-like flag.
--- Stair landings and doorframes often fail the stricter getWallForFacing check
--- even though a painting is clearly hanging on them.
local function squareHasWallFlags(square)
    if not square then
        return false
    end
    return square:has("WallN") or square:has("WallW") or square:has("WallNW")
        or square:has("DoorWallN") or square:has("DoorWallW")
        or square:has("WallNTrans") or square:has("WallWTrans") or square:has("WallNWTrans")
end

local function hasAttachSurface(props, square)
    if not props or not square then
        return false
    end
    if hasWallForDecor(props, square) then
        return true
    end
    -- Facing-based lookup failed (stairs, odd frames): accept any wall flags on
    -- this square or the neighbor getWallForFacing would have used.
    if squareHasWallFlags(square) then
        return true
    end
    if props.facing == "N" then
        local south = square.getTileInDirection and square:getTileInDirection(IsoDirections.S)
        if squareHasWallFlags(south) then
            return true
        end
    elseif props.facing == "W" then
        local east = square.getTileInDirection and square:getTileInDirection(IsoDirections.E)
        if squareHasWallFlags(east) then
            return true
        end
    end
    return false
end

--- Brush-like occupancy: stack multiple highs/overlays, hang over furniture.
--- Wall hangings always need a wall/attach surface — never greenlight open air
--- (that ate posters: forceAllow + WallOverlay with no wall = item gone, nothing shown).
--- Toggle split: layeredPlace = stacking / over-furniture; floatingPlace = mid-air Object highs.
local function tryAllowLayered(props, character, square, item, forceTypeObject)
    if not props.isMoveable or not square then
        return false
    end
    if not isLayerDecor(props) then
        return false
    end
    if props.isTableTop or (props.isStackable and props.isTable) then
        return false
    end
    if square:has("tree") or square:has(IsoFlagType.water) then
        return false
    end

    local isHighLow = props.isHigh or props.isLow
    if square:isVehicleIntersecting() and not (isHighLow and LayeredPlacement.allowFloatingPlace()) then
        return false
    end

    local t = props.type
    if t == "WallOverlay" or t == "WindowObject" or t == "WallObject" then
        -- Stacking posters/highs: layeredPlace only (not floatingPlace).
        if not LayeredPlacement.allowLayeredPlace() then
            return false
        end
        if not hasAttachSurface(props, square) then
            return false
        end
    else
        if LayeredPlacement.allowFloatingPlace() then
            -- Object highs may float (railings / no floor).
        elseif LayeredPlacement.allowLayeredPlace() then
            if not square:getFloor() then
                return false
            end
            if props.isSquareAtTopOfStairs and props:isSquareAtTopOfStairs(square) then
                return false
            end
        else
            return false
        end
    end

    return LayeredPlacement.hasPlaceRequirements(props, character)
end

local function tryEquipModeTool(props, character, mode)
    if ISMoveableDefinitions.cheat or character:isMovablesCheat() then
        return true
    end
    local usesTool = (mode == "pickup" and props.pickUpTool) or (mode == "place" and props.placeTool)
    if not usesTool then
        return true
    end
    local tool = props:hasTool(character, mode)
    if not tool then
        return false
    end
    if tool ~= true then
        ISWorldObjectContextMenu.equip(character, character:getPrimaryHandItem(), tool:getType(), true)
    end
    return true
end

local _canPlaceMoveable = ISMoveableSpriteProps.canPlaceMoveable
local _canPlaceMoveableInternal = ISMoveableSpriteProps.canPlaceMoveableInternal
local _canPickUpMoveable = ISMoveableSpriteProps.canPickUpMoveable
local _pickUpMoveable = ISMoveableSpriteProps.pickUpMoveable
local _placeMoveable = ISMoveableSpriteProps.placeMoveable
local _isWallBetweenParts = ISMoveableSpriteProps.isWallBetweenParts
local _walkToAndEquip = ISMoveableSpriteProps.walkToAndEquip

local function ensureMultiSpriteSquares(props, square)
    if not props or not square or not props.isMultiSprite or not props.sprite then
        return
    end
    local spriteGrid = props.sprite:getSpriteGrid()
    if not spriteGrid then
        return
    end
    local sX = square:getX() - spriteGrid:getSpriteGridPosX(props.sprite)
    local sY = square:getY() - spriteGrid:getSpriteGridPosY(props.sprite)
    local sZ = square:getZ()
    local force = LayeredPlacement.allowFloatingPlace()
    for gx = 0, spriteGrid:getWidth() - 1 do
        for gy = 0, spriteGrid:getHeight() - 1 do
            if spriteGrid:getSprite(gx, gy) then
                LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ, force)
            end
        end
    end
end

--- Hanging Object-type decor (lamps, chandeliers, canopies, string lights).
--- See LayeredPlacement.isFloatingDecor for why this is deliberately narrow.
local function isFloatingObjectDecor(props)
    return LayeredPlacement.isFloatingDecor(props)
end

--- Decor whose pickup may fall back to our recovery path when vanilla gives up
--- (missing multi-tile partner, stacked wall decor). Stacked wall decor belongs
--- to layeredPlace, hanging decor to floatingPlace — the same split as placing.
local function allowRecoveryPickup(props)
    if LayeredPlacement.allowFloatingPlace() then
        return true
    end
    return LayeredPlacement.allowLayeredPlace() and LayeredPlacement.isWallDecor(props)
end

--- The cheat path skips pathing and adjacency, so it needs its own range gate.
--- Allow one Z of difference so catwalk → ground-wall aims still count.
local function isFloatingDecorInReach(props, character, square)
    if not isFloatingObjectDecor(props) or not square then
        return false
    end
    if LayeredPlacement.withinBrushReach(character, square) then
        return true
    end
    if not props.isMultiSprite or not props.getSpriteGridTopLeft or not props.getMultiTileSquares then
        return false
    end
    local left, top = props:getSpriteGridTopLeft(square:getX(), square:getY())
    local squares = props:getMultiTileSquares(left, top, square:getZ())
    if not squares then
        return false
    end
    for _, sq in ipairs(squares) do
        if LayeredPlacement.withinBrushReach(character, sq) then
            return true
        end
    end
    return false
end

local function findPlaceItem(props, character, origSpriteName)
    if not character then
        return nil, nil
    end
    if props.isForceSingleItem then
        local item, container = props:findInInventoryMultiSprite(character, props.name .. " (1/1)")
        if item then
            return item, container
        end
    end
    if origSpriteName then
        local item = props:findInInventory(character, origSpriteName)
        if item then
            return item, character:getInventory()
        end
    end
    local inv = character:getInventory()
    if inv and inv.getItems then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "Moveable") and item:getName() == props.name then
                return item, inv
            end
        end
    end
    return nil, nil
end

--- Build multi-tile member list ourselves (vanilla cache often has nil edge squares).
local function buildFloatingGridMembers(props, square)
    if not props or not square or not props.sprite then
        return nil
    end
    local spriteGrid = props.sprite:getSpriteGrid()
    if not spriteGrid then
        return nil
    end
    local sX = square:getX() - spriteGrid:getSpriteGridPosX(props.sprite)
    local sY = square:getY() - spriteGrid:getSpriteGridPosY(props.sprite)
    local sZ = square:getZ()
    local members = {}
    for gx = 0, spriteGrid:getWidth() - 1 do
        for gy = 0, spriteGrid:getHeight() - 1 do
            local spr = spriteGrid:getSprite(gx, gy)
            if spr then
                local memberSq = LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ, true)
                if not memberSq then
                    return nil
                end
                table.insert(members, { square = memberSq, sprite = spr, x = gx, y = gy })
            end
        end
    end
    if #members == 0 then
        return nil
    end
    return members, spriteGrid
end

local function removePlacedInventoryItem(character, item, container)
    if not character or not item then
        return
    end
    if container == "floor" then
        if item:getWorldItem() ~= nil then
            item:getWorldItem():getSquare():transmitRemoveItemFromSquare(item:getWorldItem())
            item:getWorldItem():getSquare():removeWorldObject(item:getWorldItem())
            item:setWorldItem(nil)
        end
        return
    end
    local inv = container or character:getInventory()
    if inv and inv.Remove then
        inv:Remove(item)
        if sendRemoveItemFromContainer then
            sendRemoveItemFromContainer(inv, item)
        end
    end
end

--- Count matching sprites so we can tell a real placement from one that was
--- already there (stacking a second identical light on one tile).
local function countSprite(square, spriteName)
    if not square or not square.getObjects then
        return 0
    end
    local objects = square:getObjects()
    if not objects then
        return 0
    end
    local n = 0
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local spr = obj and obj:getSprite()
        if spr and spr:getName() == spriteName then
            n = n + 1
        end
    end
    return n
end

--- Brush/cheat spawn: bypass vanilla placeMoveableInternal quirks on empty air tiles.
--- Never runs on a pure MP client — local AddSpecialObject does not persist.
local function forceSpawnDecor(square, spriteName, item)
    if not square or not spriteName then
        return false
    end
    if not LayeredPlacement.canMutateWorld() then
        return false
    end
    local before = countSprite(square, spriteName)
    -- Prefer shared spawner (also used by multi-grid restore).
    local obj = LayeredPlacement.spawnDecorSprite(square, spriteName)
    if obj and item then
        pcall(function()
            if obj.getCustomSettingsFromItem and instanceof(obj, "IsoLightSwitch") then
                obj:getCustomSettingsFromItem(item)
            end
            if GameEntityFactory then
                if item.hasComponents and (not item:hasComponents())
                    and GameEntityFactory.CreateIsoEntityFromCellLoading
                then
                    GameEntityFactory.CreateIsoEntityFromCellLoading(obj)
                end
                if GameEntityFactory.TransferComponents then
                    GameEntityFactory.TransferComponents(item, obj)
                end
            end
            if instanceof(obj, "IsoLightSwitch") and LayeredPlacement.preparePlacedLight then
                LayeredPlacement.preparePlacedLight(obj, true)
            end
            if isServer() and obj.transmitCompleteItemToClients then
                obj:transmitCompleteItemToClients()
            end
        end)
    end
    if countSprite(square, spriteName) > before then
        return true
    end
    return false
end

--- Brush spawn: direct object create first (admin-brush style), vanilla as backup.
--- Skips entirely on pure MP clients so we never create non-persisted ghosts.
local function placePart(props, square, item, spriteName)
    if not LayeredPlacement.canMutateWorld() then
        return false
    end
    local before = countSprite(square, spriteName)
    forceSpawnDecor(square, spriteName, item)
    if countSprite(square, spriteName) > before then
        LayeredPlacement.markConstruction(square)
        return true
    end
    pcall(function()
        props:placeMoveableInternal(square, item, spriteName)
    end)
    if countSprite(square, spriteName) > before then
        LayeredPlacement.markConstruction(square)
        return true
    end
    return false
end

--- Multi-part decor that is not ForceSingleItem needs one inventory item per
--- sprite, exactly like vanilla, or canopies/rainbow lights would duplicate.
local function collectMultiPartItems(props, character, members, spriteGrid)
    local max = spriteGrid:getSpriteCount()
    local items = {}
    for i = 1, #members do
        local item, container = props:findInInventoryMultiSprite(
            character, props.name .. " (" .. i .. "/" .. max .. ")"
        )
        if not item then
            return nil
        end
        items[i] = { item = item, container = container }
    end
    return items
end

local function removeWorldSpriteObject(square, spriteName)
    local obj = LayeredPlacement.findSpriteObject(square, spriteName)
    if not obj or not square then
        return
    end
    pcall(function()
        triggerEvent("OnObjectAboutToBeRemoved", obj)
        square:transmitRemoveItemFromSquare(obj)
        if square.RecalcProperties then
            square:RecalcProperties()
        end
    end)
end

local function tagPlacedMultiGrid(members, spriteGrid)
    if not members or #members < 2 then
        return
    end
    local parts = {}
    local sX, sY, sZ
    for i = 1, #members do
        local m = members[i]
        if m.square and m.sprite and m.sprite.getName and m.x ~= nil and m.y ~= nil then
            if not sX then
                sX = m.square:getX() - m.x
                sY = m.square:getY() - m.y
                sZ = m.square:getZ()
            end
            table.insert(parts, { n = m.sprite:getName(), x = m.x, y = m.y })
        end
    end
    if not sX or #parts < 2 then
        return
    end
    for i = 1, #members do
        local m = members[i]
        local obj = m.square and LayeredPlacement.findSpriteObject(m.square, m.sprite:getName())
        if obj then
            LayeredPlacement.tagMultiGridObject(obj, sX, sY, sZ, parts)
            LayeredPlacement.markConstruction(m.square)
        end
    end
end

local function cheatPlaceFloating(props, character, square, origSpriteName)
    -- Pure MP clients must not spawn here — the cursor sends placeFloating to
    -- the server instead (timed actions often never start on fence/rail tiles).
    if not LayeredPlacement.canMutateWorld() then
        return false
    end
    if not LayeredPlacement.hasPlaceRequirements(props, character) then
        return false
    end
    ensureMultiSpriteSquares(props, square)

    local placed = 0
    if props.isMultiSprite then
        local members, spriteGrid = buildFloatingGridMembers(props, square)
        if not members then
            LayeredPlacement.log("cheat place: could not build grid members")
            return false
        end

        if not props.isForceSingleItem then
            local parts = collectMultiPartItems(props, character, members, spriteGrid)
            if not parts then
                LayeredPlacement.log("cheat place: missing one of the multi-part items")
                return false
            end
            local placedMembers = {}
            for i, gridMember in ipairs(members) do
                if placePart(props, gridMember.square, parts[i].item, gridMember.sprite:getName()) then
                    placed = placed + 1
                    table.insert(placedMembers, {
                        square = gridMember.square,
                        spriteName = gridMember.sprite:getName(),
                        item = parts[i].item,
                        container = parts[i].container,
                    })
                    LayeredPlacement.markConstruction(gridMember.square)
                end
            end
            -- All-or-nothing: a half-light that loses its partner can't be picked up.
            if placed > 0 and placed < #members then
                for _, pm in ipairs(placedMembers) do
                    removeWorldSpriteObject(pm.square, pm.spriteName)
                end
                LayeredPlacement.log("cheat place: rolled back partial multi-part place")
                return false
            end
            for _, pm in ipairs(placedMembers) do
                removePlacedInventoryItem(character, pm.item, pm.container)
            end
            if placed == #members then
                tagPlacedMultiGrid(members, spriteGrid)
            end
        else
            local item, container = findPlaceItem(props, character, origSpriteName)
            if not item then
                LayeredPlacement.log("cheat place: no item for " .. tostring(props.name))
                return false
            end
            local anchor = spriteGrid:getAnchorSprite()
            local placedMembers = {}
            for _, gridMember in ipairs(members) do
                local gridItem = item
                if gridMember.sprite ~= anchor then
                    gridItem = props:instanceItem(gridMember.sprite:getName()) or item
                end
                if placePart(props, gridMember.square, gridItem, gridMember.sprite:getName()) then
                    placed = placed + 1
                    table.insert(placedMembers, {
                        square = gridMember.square,
                        spriteName = gridMember.sprite:getName(),
                    })
                    LayeredPlacement.markConstruction(gridMember.square)
                end
            end
            if placed > 0 and placed < #members then
                for _, pm in ipairs(placedMembers) do
                    removeWorldSpriteObject(pm.square, pm.spriteName)
                end
                LayeredPlacement.log("cheat place: rolled back partial ForceSingleItem place")
                return false
            end
            if placed == #members then
                removePlacedInventoryItem(character, item, container)
                tagPlacedMultiGrid(members, spriteGrid)
            end
        end
    else
        local item, container = findPlaceItem(props, character, origSpriteName)
        if not item then
            LayeredPlacement.log("cheat place: no item for " .. tostring(props.name))
            return false
        end
        if placePart(props, square, item, props.spriteName or origSpriteName) then
            placed = 1
            removePlacedInventoryItem(character, item, container)
            LayeredPlacement.markConstruction(square)
        end
    end

    if placed > 0 then
        if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
            ISMoveableCursor.clearCacheForAllPlayers()
        end
        LayeredPlacement.markConstruction(square)
        -- Multi-tile string lights are separate IsoLightSwitches; light the
        -- whole group so place doesn't leave one half dark.
        if props.isMultiSprite then
            local anchorObj = LayeredPlacement.findSpriteObject(
                square, props.spriteName or origSpriteName
            )
            if not anchorObj and props.sprite then
                local grid = props.sprite:getSpriteGrid()
                local anchor = grid and grid:getAnchorSprite()
                if anchor then
                    local members = buildFloatingGridMembers(props, square)
                    if members then
                        for _, m in ipairs(members) do
                            if m.sprite == anchor then
                                anchorObj = LayeredPlacement.findSpriteObject(
                                    m.square, m.sprite:getName()
                                )
                                break
                            end
                        end
                    end
                end
            end
            if anchorObj and instanceof(anchorObj, "IsoLightSwitch") then
                LayeredPlacement.setLightGroupState(anchorObj, true)
            end
        end
        LayeredPlacement.log("placed floating decor @ "
            .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
            .. " parts=" .. tostring(placed))
        return true
    end
    LayeredPlacement.log("floating place produced 0 parts")
    return false
end

local function gridBelongsToProps(gridData, spriteGrid)
    if not gridData or not gridData.parts or not spriteGrid then
        return false
    end
    local expected = {}
    local expectedCount = 0
    for gx = 0, spriteGrid:getWidth() - 1 do
        for gy = 0, spriteGrid:getHeight() - 1 do
            local spr = spriteGrid:getSprite(gx, gy)
            if spr and spr.getName then
                expected[spr:getName()] = true
                expectedCount = expectedCount + 1
            end
        end
    end
    local matched = 0
    for i = 1, #gridData.parts do
        local part = gridData.parts[i]
        if not part or not part.n or not expected[part.n] then
            return false
        end
        matched = matched + 1
    end
    return matched == expectedCount
end

--- Find a hanging-decor object on this square even when the cursor sprite
--- doesn't match (wrong multi-tile half, lit sprite, etc.).
local function findFloatingPartOnSquare(props, square)
    if not props or not square then
        return nil, nil
    end
    local obj, sprInstance = props:findOnSquare(square, props.spriteName)
    if obj then
        return obj, sprInstance
    end
    local spriteGrid = props.sprite and props.sprite.getSpriteGrid and props.sprite:getSpriteGrid()
    if spriteGrid then
        for gx = 0, spriteGrid:getWidth() - 1 do
            for gy = 0, spriteGrid:getHeight() - 1 do
                local partSprite = spriteGrid:getSprite(gx, gy)
                if partSprite then
                    obj, sprInstance = props:findOnSquare(square, partSprite:getName())
                    if obj then
                        return obj, sprInstance
                    end
                end
            end
        end
    end
    -- Last resort: only a tag for this exact sprite grid. Other stacked
    -- hanging decor can share the square and must never be removed.
    if square.getObjects then
        local objects = square:getObjects()
        if objects then
            for i = objects:size() - 1, 0, -1 do
                local candidate = objects:get(i)
                if candidate and candidate.getModData then
                    local md = candidate:getModData()
                    if md and gridBelongsToProps(md.lpGrid, spriteGrid) then
                        return candidate, nil
                    end
                end
                if candidate and instanceof(candidate, "IsoLightSwitch") and props.isoType == "IsoLightSwitch" then
                    local spr = candidate.getSprite and candidate:getSprite()
                    if spr and spr.getSpriteGrid and spr:getSpriteGrid() and spriteGrid
                        and spr:getSpriteGrid() == spriteGrid
                    then
                        return candidate, nil
                    end
                end
            end
        end
    end
    return nil, nil
end

--- Force-remove a world object when vanilla pickUpMoveableInternal no-ops
--- (instanceItem/TransferComponents failures leave lights stuck in the world).
local function forceRemoveWorldObject(square, obj)
    if not square or not obj then
        return false
    end
    local ok = pcall(function()
        triggerEvent("OnObjectAboutToBeRemoved", obj)
        if square.transmitRemoveItemFromSquare then
            square:transmitRemoveItemFromSquare(obj)
        elseif square.RemoveTileObject then
            square:RemoveTileObject(obj)
        end
        if square.RecalcProperties then
            square:RecalcProperties()
        end
        if square.RecalcAllWithNeighbours then
            square:RecalcAllWithNeighbours(true)
        end
    end)
    return ok and true or false
end

local function removeFloatingPart(props, character, square, obj, sprInstance, spriteName, createItem)
    if not obj or not square then
        return false
    end
    local name = spriteName
    if not name and obj.getSprite and obj:getSprite() then
        name = obj:getSprite():getName()
    end
    name = name or props.spriteName
    local before = obj.getObjectIndex and obj:getObjectIndex() or -1
    pcall(function()
        props:pickUpMoveableInternal(character, square, obj, sprInstance, name, createItem, true)
    end)
    local after = obj.getObjectIndex and obj:getObjectIndex() or -1
    if before >= 0 and after < 0 then
        return true
    end
    -- Still in the world (or index check unavailable): yank it directly.
    if after >= 0 or (obj.getSquare and obj:getSquare() == square) then
        return forceRemoveWorldObject(square, obj)
    end
    return true
end

local function cheatPickUpFloating(props, character, square, createItem)
    if not LayeredPlacement.canMutateWorld() then
        -- Pure MP clients: timed-action complete has no authority to delete
        -- world objects. Ask the server (same path as the brush pickup).
        if LayeredPlacement.requestFloatingWorldAction(
            character, square, props.spriteName, "pickup", props.spriteName, props.cursorFacing
        ) then
            return {}
        end
        return nil
    end
    ensureMultiSpriteSquares(props, square)
    -- Vanilla always returns an items table after entering its multi-sprite
    -- branch, even when a ForceSingleItem part wasn't actually removed. Do not
    -- trust that truthy no-op; use the verified atomic recovery path below.
    if not props.isForceSingleItem then
        local result = _pickUpMoveable(props, character, square, createItem, true)
        if result ~= nil and result ~= false then
            return result
        end
    end

    local obj, sprInstance = findFloatingPartOnSquare(props, square)
    -- Cursor square may be the empty half of a 2-tile light; search partners.
    if not obj and props.sprite and props.sprite.getSpriteGrid then
        local spriteGrid = props.sprite:getSpriteGrid()
        if spriteGrid and square then
            local sX = square:getX() - spriteGrid:getSpriteGridPosX(props.sprite)
            local sY = square:getY() - spriteGrid:getSpriteGridPosY(props.sprite)
            local sZ = square:getZ()
            for gx = 0, spriteGrid:getWidth() - 1 do
                for gy = 0, spriteGrid:getHeight() - 1 do
                    local partSq = LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ, true)
                    obj, sprInstance = findFloatingPartOnSquare(props, partSq)
                    if obj then
                        square = partSq
                        break
                    end
                end
                if obj then
                    break
                end
            end
        end
    end
    if not obj then
        LayeredPlacement.log("floating pickup: no object on square")
        return nil
    end

    --- Snapshot light settings onto the inventory item before we delete parts.
    local function makeForceSingleItem(fromObj, spriteName)
        if not createItem or not props.isForceSingleItem then
            return nil
        end
        local item = props:instanceItem(spriteName or props.spriteName)
        if not item and fromObj and fromObj.getSprite and fromObj:getSprite() then
            item = props:instanceItem(fromObj:getSprite():getName())
        end
        if item and fromObj and instanceof(fromObj, "IsoLightSwitch")
            and fromObj.setCustomSettingsToItem
        then
            pcall(function()
                fromObj:setCustomSettingsToItem(item)
            end)
        end
        return item
    end

    local function giveItem(item)
        if not item or not character then
            return
        end
        character:getInventory():AddItem(item)
        if sendAddItemToContainer then
            sendAddItemToContainer(character:getInventory(), item)
        end
        LayeredPlacement.makeMoveableDroppable(item)
    end

    -- Prefer the recorded multi-tile map (survives lit sprites / missing halves).
    local md = obj.getModData and obj:getModData()
    local grid = md and md.lpGrid
    local propsGrid = props.sprite and props.sprite.getSpriteGrid and props.sprite:getSpriteGrid()
    if grid and grid.parts and grid.ox ~= nil and gridBelongsToProps(grid, propsGrid) then
        local perPartItem = createItem and not props.isForceSingleItem
        local anchor = propsGrid and propsGrid:getAnchorSprite()
        local pendingItem = makeForceSingleItem(
            obj, anchor and anchor:getName() or props.spriteName
        )
        -- Never remove a ForceSingleItem grid unless its replacement item
        -- already exists. This is the inventory-loss guard for recovery pickup.
        if createItem and props.isForceSingleItem and not pendingItem then
            LayeredPlacement.log("floating pickup aborted: could not create ForceSingleItem")
            return nil
        end
        -- Where the footprint starts comes from the sprite's own grid slot; a
        -- recorded origin can be stale. The recorded part names still win, since
        -- they survive lit-sprite swaps and missing halves.
        local ox, oy, oz = LayeredPlacement.gridOriginOf(obj)
        if ox == nil then
            ox, oy, oz = grid.ox, grid.oy, grid.oz
        end
        local removed = 0
        for i = 1, #grid.parts do
            local part = grid.parts[i]
            if part and part.n and part.x ~= nil and part.y ~= nil then
                local partSq = LayeredPlacement.ensureGridSquare(
                    ox + part.x, oy + part.y, oz, true
                )
                local partObj = LayeredPlacement.findSpriteObject(partSq, part.n)
                if not partObj then
                    partObj = findFloatingPartOnSquare(props, partSq)
                end
                if partObj and LayeredPlacement.foreignGridPart(partObj, ox, oy, oz) then
                    -- Another copy of the same light hung alongside this one.
                    partObj = nil
                end
                if partObj then
                    if removeFloatingPart(props, character, partSq, partObj, nil, part.n, perPartItem) then
                        removed = removed + 1
                    end
                end
            end
        end
        if removed > 0 then
            giveItem(pendingItem)
            if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
                ISMoveableCursor.clearCacheForAllPlayers()
            end
            LayeredPlacement.log("picked up floating lpGrid parts=" .. tostring(removed))
            LayeredPlacement.fixInventoryMoveableDrops(character:getInventory())
            LayeredPlacement.markConstruction(square)
            return {}
        end
    end

    local spriteGrid = props.sprite and props.sprite:getSpriteGrid()
    if not spriteGrid and obj.getSprite and obj:getSprite() then
        spriteGrid = obj:getSprite():getSpriteGrid()
    end
    if spriteGrid then
        -- Non-ForceSingleItem grids hand back one item per sprite, like vanilla.
        local perPartItem = createItem and not props.isForceSingleItem
        local foundSpr = obj.getSprite and obj:getSprite() or props.sprite
        local sX = square:getX() - spriteGrid:getSpriteGridPosX(foundSpr)
        local sY = square:getY() - spriteGrid:getSpriteGridPosY(foundSpr)
        local sZ = square:getZ()
        local anchor = spriteGrid:getAnchorSprite()
        local pendingItem = makeForceSingleItem(obj, anchor and anchor:getName() or props.spriteName)
        if createItem and props.isForceSingleItem and not pendingItem then
            LayeredPlacement.log("floating pickup aborted: could not create ForceSingleItem anchor")
            return nil
        end
        local removed = 0
        for gx = 0, spriteGrid:getWidth() - 1 do
            for gy = 0, spriteGrid:getHeight() - 1 do
                local partSprite = spriteGrid:getSprite(gx, gy)
                if partSprite then
                    local partSq = LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ, true)
                    local partObj, partSpr = findFloatingPartOnSquare(props, partSq)
                    if not partObj then
                        partObj, partSpr = props:findOnSquare(partSq, partSprite:getName())
                    end
                    if partObj then
                        if removeFloatingPart(
                            props, character, partSq, partObj, partSpr, partSprite:getName(), perPartItem
                        ) then
                            removed = removed + 1
                        end
                    end
                end
            end
        end
        if removed > 0 then
            giveItem(pendingItem)
            if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
                ISMoveableCursor.clearCacheForAllPlayers()
            end
            LayeredPlacement.log("picked up floating multi decor parts=" .. tostring(removed))
            LayeredPlacement.fixInventoryMoveableDrops(character:getInventory())
            LayeredPlacement.markConstruction(square)
            return {}
        end
        return nil
    end
    local pendingItem = makeForceSingleItem(obj, props.spriteName)
    if createItem and props.isForceSingleItem and not pendingItem then
        LayeredPlacement.log("floating pickup aborted: could not create ForceSingleItem")
        return nil
    end
    if removeFloatingPart(
        props, character, square, obj, sprInstance, props.spriteName,
        createItem and not props.isForceSingleItem
    ) then
        giveItem(pendingItem)
        LayeredPlacement.fixInventoryMoveableDrops(character:getInventory())
        LayeredPlacement.markConstruction(square)
        return {}
    end
    return nil
end

--- Count this sprite as a free object or as a wall child/attached overlay
--- (incl. the adjacent wall square N/W overlays attach to).
local function countWallDecorPresence(props, square, spriteName)
    local function countSpriteOnList(list, spriteName)
        if not list then
            return 0
        end
        local n = 0
        for j = 0, list:size() - 1 do
            local entry = list:get(j)
            local spr = entry and (entry.getParentSprite and entry:getParentSprite() or entry.getSprite and entry:getSprite())
            if spr and spr:getName() == spriteName then
                n = n + 1
            end
        end
        return n
    end

    local function countOn(sq)
        if not sq then
            return 0
        end
        local n = countSprite(sq, spriteName)
        if not sq.getObjects then
            return n
        end
        local objects = sq:getObjects()
        if not objects then
            return n
        end
        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if obj then
                n = n + countSpriteOnList(obj.getChildSprites and obj:getChildSprites(), spriteName)
                n = n + countSpriteOnList(obj.getAttachedAnimSprite and obj:getAttachedAnimSprite(), spriteName)
            end
        end
        return n
    end

    local n = countOn(square)
    local wall = getWallObjectForDecor(props, square)
    if wall and wall.getSquare then
        local wsq = wall:getSquare()
        if wsq and wsq ~= square then
            n = n + countOn(wsq)
        elseif wall then
            -- Wall on this square: also count directly on the wall object in case
            -- square object iteration missed a thumpable edge case.
            n = n + countSpriteOnList(wall.getChildSprites and wall:getChildSprites(), spriteName)
            n = n + countSpriteOnList(wall.getAttachedAnimSprite and wall:getAttachedAnimSprite(), spriteName)
        end
    end
    return n
end

--- Attach a WallOverlay to the wall as a child/attached anim, verifying it stuck.
--- Wallpaper replaces the wall's main sprite but keeps the same wall object —
--- AttachExistingAnim can still no-op if the wall already has attached anims
--- (trim, dirt, cracks), so we also try the explicit child-sprite add vanilla used to use.
local function attachWallOverlay(wall, spriteName)
    if not wall or not spriteName then
        return false
    end
    local spr = getSprite(spriteName)
    if not spr then
        return false
    end

    local function childCount()
        local kids = wall.getChildSprites and wall:getChildSprites()
        return kids and kids:size() or 0
    end
    local function attachedCount()
        local anims = wall.getAttachedAnimSprite and wall:getAttachedAnimSprite()
        return anims and anims:size() or 0
    end

    local beforeChild = childCount()
    local beforeAnim = attachedCount()

    pcall(function()
        wall:AttachExistingAnim(spr, 0, 0, false, 0, false, 0)
    end)
    if childCount() > beforeChild or attachedCount() > beforeAnim then
        if isClient() and wall.transmitUpdatedSpriteToServer then
            wall:transmitUpdatedSpriteToServer()
        end
        if isServer() and wall.transmitUpdatedSpriteToClients then
            wall:transmitUpdatedSpriteToClients()
        end
        if wall.getSquare then
            LayeredPlacement.markConstruction(wall:getSquare())
        end
        return true
    end

    -- Explicit child-sprite add (older vanilla path).
    local ok = pcall(function()
        local overlay = spr.newInstance and spr:newInstance() or nil
        if not overlay then
            return
        end
        local sprList = wall:getChildSprites()
        if not sprList then
            sprList = ArrayList.new()
        end
        sprList:add(overlay)
        wall:setChildSprites(sprList)
        if isClient() and wall.transmitUpdatedSpriteToServer then
            wall:transmitUpdatedSpriteToServer()
        end
        if isServer() and wall.transmitUpdatedSpriteToClients then
            wall:transmitUpdatedSpriteToClients()
        end
    end)
    if ok and (childCount() > beforeChild or attachedCount() > beforeAnim) then
        if wall.getSquare then
            LayeredPlacement.markConstruction(wall:getSquare())
        end
        return true
    end
    return false
end

--- Wall hangings: follow vanilla facing rules so the object lands on the same
--- side as the hover ghost.
---   N/W → free IsoObject on the aimed square (wall is on the adjacent tile;
---         attaching would put it in the other room).
---   E/S → AttachExistingAnim on the wall on this square.
--- Never remove the inventory item unless the sprite is present afterward.
local function placeWallDecor(props, character, square, origSpriteName)
    if not props or not character or not square then
        return false
    end
    if not hasAttachSurface(props, square) then
        return false
    end

    local spriteName = props.spriteName or origSpriteName
    if not spriteName then
        return false
    end

    -- Co-op hosts and dedicated players are both pure clients: the timed action
    -- completes only on their machine, so a local object would vanish on rejoin.
    -- Hand the whole placement (object + inventory) to the server instead.
    if not LayeredPlacement.canMutateWorld() then
        if not findPlaceItem(props, character, origSpriteName) then
            LayeredPlacement.log("wall decor place: no matching item in inventory")
            return false
        end
        return LayeredPlacement.requestLayeredPlace(
            character, square, spriteName, origSpriteName, props.cursorFacing
        )
    end

    local function finishOk(item, how)
        removePlacedInventoryItem(character, item)
        if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
            ISMoveableCursor.clearCacheForAllPlayers()
        end
        LayeredPlacement.markConstruction(square)
        LayeredPlacement.log("wall decor " .. how .. " @ "
            .. tostring(square:getX()) .. "," .. tostring(square:getY())
            .. "," .. tostring(square:getZ())
            .. " face=" .. tostring(props.facing))
        return true
    end

    if props.isMultiSprite then
        local before = countWallDecorPresence(props, square, spriteName)
        -- Large paintings: vanilla grid place when possible.
        pcall(function()
            _placeMoveable(props, character, square, origSpriteName, true)
        end)
        if countWallDecorPresence(props, square, spriteName) > before then
            -- Vanilla already removed the item on success.
            if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
                ISMoveableCursor.clearCacheForAllPlayers()
            end
            LayeredPlacement.log("multi wall decor vanilla-placed")
            return true
        end
        -- Fallback: free-spawn each part on its aimed square (same side as hover).
        ensureMultiSpriteSquares(props, square)
        local spriteGrid = props.sprite and props.sprite:getSpriteGrid()
        local sgrid = props.getSpriteGridInfo and props:getSpriteGridInfo(square, false)
        local item = props:findInInventoryMultiSprite(character, props.name .. " (1/1)")
            or props:findInInventory(character, origSpriteName)
        if not spriteGrid or not sgrid or not item then
            LayeredPlacement.log("multi wall decor place produced nothing; item kept")
            return false
        end
        local placed = 0
        for _, gridMember in ipairs(sgrid) do
            local partSprite = gridMember.sprite and gridMember.sprite:getName() or spriteName
            local partItem = item
            if gridMember.sprite ~= spriteGrid:getAnchorSprite() then
                partItem = props:instanceItem(partSprite) or item
            end
            if forceSpawnDecor(gridMember.square, partSprite, partItem) then
                placed = placed + 1
            end
        end
        if placed > 0 or countWallDecorPresence(props, square, spriteName) > before then
            return finishOk(item, "multi-spawned")
        end
        LayeredPlacement.log("multi wall decor place produced nothing; item kept")
        return false
    end

    local item = props:findInInventory(character, origSpriteName)
    if not item then
        return false
    end

    local before = countWallDecorPresence(props, square, spriteName)
    local function appeared()
        return countWallDecorPresence(props, square, spriteName) > before
    end

    local facing = props.facing
    local wall = getWallObjectForDecor(props, square)
    local isNorthOrWest = facing == "N" or facing == "W"
    local isEastOrSouth = facing == "E" or facing == "S"
    local isOverlay = props.type == "WallOverlay"

    -- Prefer vanilla internals first (we only get here in singleplayer or on the
    -- server, so anything created below persists).
    pcall(function()
        props:placeMoveableInternal(square, item, spriteName)
    end)
    if appeared() then
        return finishOk(item, "vanilla")
    end

    if isOverlay and isEastOrSouth and wall then
        -- E/S: attach the overlay to the wall on this square.
        if attachWallOverlay(wall, spriteName) and appeared() then
            return finishOk(item, "wall-attached")
        end
        if forceSpawnDecor(square, spriteName, item) and appeared() then
            return finishOk(item, "spawned-same-side")
        end
    elseif isOverlay and isNorthOrWest then
        -- N/W: free object on the aimed square only — never attach to the
        -- adjacent wall (that lands in the other room).
        if forceSpawnDecor(square, spriteName, item) and appeared() then
            return finishOk(item, "spawned-aimed")
        end
    else
        -- Plain WallObject / WindowObject: free object on aimed square.
        if forceSpawnDecor(square, spriteName, item) and appeared() then
            return finishOk(item, "spawned")
        end
    end

    LayeredPlacement.log("wall decor place failed; item kept")
    return false
end

--- Hanging decor: brush-spawn into place (no canPlace re-check, no spinner path).
--- Wall hangings: use vanilla when it accepts the tile; otherwise facing-correct
--- verified place so stacking still works without wrong-side / vanish bugs.
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    if isFloatingObjectDecor(self) and square then
        -- Prefer upstairs when the mouse fell through mesh, but still allow an
        -- intentional ground-floor aim from a catwalk (brush reach covers dz=1).
        if LayeredPlacement.allowMeshFloorAim() and character then
            local lifted = LayeredPlacement.liftToPlayerZ(character, square)
            if lifted and LayeredPlacement.withinBrushReach(character, lifted) then
                -- Only steal the aim upstairs when the lifted tile is in reach and
                -- the ground tile is not the one they are clearly aiming at with a wall.
                local charSq = character:getSquare() or character:getCurrentSquare()
                if charSq and square:getZ() < charSq:getZ() then
                    local groundHasWall = square:has("WallN") or square:has("WallW")
                        or square:has("WallNW") or square:has("DoorWallN") or square:has("DoorWallW")
                    if not groundHasWall then
                        square = lifted
                    end
                end
            end
        end
        if cheatPlaceFloating(self, character, square, origSpriteName) then
            return true
        end
        -- Pure MP client: refuse local place so the timed-action server
        -- complete() owns persistence. Returning false here is intentional.
        if not LayeredPlacement.canMutateWorld() then
            return false
        end
        LayeredPlacement.log("brush place produced 0 parts")
        return false
    end
    if LayeredPlacement.isWallDecor(self) and LayeredPlacement.allowLayeredPlace() and square then
        -- If vanilla already allows this tile, let it place — correct side + pickup.
        local item = nil
        if self.isMultiSprite and self.isForceSingleItem then
            item = self:findInInventoryMultiSprite(character, self.name .. " (1/1)")
        end
        item = item or self:findInInventory(character, origSpriteName)
        if item and _canPlaceMoveableInternal(self, character, square, item) then
            return _placeMoveable(self, character, square, origSpriteName, false)
        end
        -- Occupancy blocked (second high/overlay, etc.): our verified path.
        return placeWallDecor(self, character, square, origSpriteName)
    end
    if LayeredPlacement.allowLayeredPlace() and isLayerDecor(self) then
        forceAllow = true
    end
    return _placeMoveable(self, character, square, origSpriteName, forceAllow)
end

function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
    if not square then
        return false
    end
    -- Hanging Object-type decor (string lights): brush-valid when in reach.
    if isFloatingObjectDecor(self)
        and not square:has(IsoFlagType.water)
        and not square:has("tree")
        and LayeredPlacement.hasPlaceRequirements(self, character)
    then
        return true
    end
    -- Wall hangings: stacking is layeredPlace only.
    if LayeredPlacement.isWallDecor(self) and LayeredPlacement.allowLayeredPlace() then
        if tryAllowLayered(self, character, square, item, forceTypeObject) then
            return true
        end
    end
    local canPlace = _canPlaceMoveableInternal(self, character, square, item, forceTypeObject)
    if canPlace or not LayeredPlacement.isPlaceHelpEnabled() then
        return canPlace
    end
    return tryAllowLayered(self, character, square, item, forceTypeObject)
end

function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if isFloatingObjectDecor(self) and square then
        ensureMultiSpriteSquares(self, square)
        -- Keep the vanilla requirement checks (tool, skill, inventory room, empty
        -- container); only fall back past the grid-partner check.
        if _canPickUpMoveable(self, character, square, object) then
            return true
        end
        -- Incomplete multi-tile (partner vanished on reload): still allow pickup.
        return self:canPickUpMoveableInternal(character, square, object, false)
    end
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local ok = _canPickUpMoveable(self, character, square, object)
    if ok or not allowRecoveryPickup(self) then
        return ok
    end
    -- Wall/object highs on railings: allow pickup without full grid partners.
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) then
        return ok
    end
    return self:canPickUpMoveableInternal(character, square, object, false)
end

function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    local function afterPickup(result)
        if character and createItem then
            LayeredPlacement.fixInventoryMoveableDrops(character:getInventory())
        end
        return result
    end
    if isFloatingObjectDecor(self) and square then
        local obj = findFloatingPartOnSquare(self, square)
        -- Always use the incomplete-grid recovery path for hanging multis.
        -- Vanilla forceAllow still requires every grid partner to exist.
        -- ViaCursor does not pass forceAllow, so also allow when we can see a part.
        if forceAllow or self:canPickUpMoveable(character, square, obj)
            or (obj and self:canPickUpMoveableInternal(character, square, obj, false))
        then
            return afterPickup(cheatPickUpFloating(self, character, square, createItem))
        end
        return nil
    end
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local result = _pickUpMoveable(self, character, square, createItem, forceAllow)
    if (result ~= nil and result ~= false) or not allowRecoveryPickup(self) then
        return afterPickup(result)
    end
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) or not square then
        return afterPickup(result)
    end
    -- Grid partner missing: remove whatever parts we can find (wall/object highs).
    return afterPickup(cheatPickUpFloating(self, character, square, createItem))
end

function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    -- Floating highs: owned by floatingPlace (independent of layeredPlace).
    if isFloatingObjectDecor(self) then
        if not square or square:has(IsoFlagType.water) then
            return false
        end
        if not LayeredPlacement.hasPlaceRequirements(self, character) then
            return false
        end
        if not LayeredPlacement.withinBrushReach(character, square) then
            if not isFloatingDecorInReach(self, character, square) then
                return false
            end
        end
        if self.isMultiSprite then
            ensureMultiSpriteSquares(self, square)
            local members, spriteGrid = buildFloatingGridMembers(self, square)
            if not members then
                return false
            end
            if not self.isForceSingleItem then
                return collectMultiPartItems(self, character, members, spriteGrid) ~= nil
            end
        end
        local invItem = item
        if self.isForceSingleItem then
            invItem = self:findInInventoryMultiSprite(character, self.name .. " (1/1)") or item
        end
        return invItem ~= nil
    end

    if not LayeredPlacement.isPlaceHelpEnabled() or not isLayerDecor(self) then
        return _canPlaceMoveable(self, character, square, item)
    end

    if not square or square:has(IsoFlagType.water) then
        return false
    end

    -- Wall hangings / posters: stacking is layeredPlace only.
    if LayeredPlacement.isWallDecor(self) then
        if not LayeredPlacement.allowLayeredPlace() then
            return _canPlaceMoveable(self, character, square, item)
        end
        if square:isVehicleIntersecting()
            and not ((self.isHigh or self.isLow) and LayeredPlacement.allowFloatingPlace())
        then
            return false
        end
        if tryAllowLayered(self, character, square, item) then
            return true
        end
        return self:canPlaceMoveableInternal(character, square, item)
    end

    -- Remaining layer decor (non-wall): layered and/or floating rules inside tryAllow.
    if square:isVehicleIntersecting()
        and not ((self.isHigh or self.isLow) and LayeredPlacement.allowFloatingPlace())
    then
        return false
    end

    if self.isMoveable and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
        local sgrid = self:getSpriteGridInfo(square, false)
        if not sgrid then
            return false
        end
        local invItem = item
        if self.isForceSingleItem then
            invItem = self:findInInventoryMultiSprite(character, self.name .. " (1/1)") or item
        end
        if not invItem then
            return false
        end
        for _, gridMember in ipairs(sgrid) do
            local memberSq = gridMember.square
            if not memberSq and gridMember.x ~= nil and gridMember.y ~= nil then
                local spriteGrid = self.sprite:getSpriteGrid()
                if spriteGrid then
                    local sX = square:getX() - spriteGrid:getSpriteGridPosX(self.sprite)
                    local sY = square:getY() - spriteGrid:getSpriteGridPosY(self.sprite)
                    memberSq = LayeredPlacement.ensureGridSquare(sX + gridMember.x, sY + gridMember.y, square:getZ())
                    gridMember.square = memberSq
                end
            end
            if not self:canPlaceMoveableInternal(character, memberSq, invItem) then
                return false
            end
        end
        return true
    end

    return self:canPlaceMoveableInternal(character, square, item)
end

function ISMoveableSpriteProps:isWallBetweenParts(spriteGrid, x, y, z)
    -- Floating multi-sprite highs ignore walls between parts; layered stacking too.
    if isFloatingObjectDecor(self) then
        return false
    end
    if LayeredPlacement.allowLayeredPlace() and isLayerDecor(self) then
        return false
    end
    return _isWallBetweenParts(self, spriteGrid, x, y, z)
end

--- Same-floor Chebyshev reach used by walkToAndEquip + timed-action isValid.
local function withinCatwalkReach(character, square)
    return LayeredPlacement.withinReach(character, square, LayeredPlacement.REACH_DIST)
end

local function walkToDecorSquare(props, character, square)
    if withinCatwalkReach(character, square) then
        return true
    end
    if LayeredPlacement.walkToNearbyFloor(character, square, true) then
        return true
    end
    if props.isMultiSprite and props.getSpriteGridTopLeft and props.getMultiTileSquares and luautils.walkAdjSquares then
        ensureMultiSpriteSquares(props, square)
        local left, top = props:getSpriteGridTopLeft(square:getX(), square:getY())
        local squares = props:getMultiTileSquares(left, top, square:getZ())
        if squares and luautils.walkAdjSquares(character, squares, true, true) then
            return true
        end
    end
    return false
end

--- Hanging decor Place/Pickup in reach: the spinner must not cancel on adjacency
--- before complete(), which is what made railing lights fail silently.
local function isFloatingDecorAction(action)
    if not action or (action.mode ~= "place" and action.mode ~= "pickup") then
        return false
    end
    local props = action.moveProps or action.origMoveProps
    return isFloatingDecorInReach(props, action.character, action.square)
end

local function isCatwalkReachAction(action)
    if isFloatingDecorAction(action) then
        return true
    end
    if not LayeredPlacement.allowCatwalkReach() then
        return false
    end
    if not action or (action.mode ~= "place" and action.mode ~= "pickup") then
        return false
    end
    local props = action.moveProps or action.origMoveProps
    if not LayeredPlacement.isReachDecor(props) then
        return false
    end
    if withinCatwalkReach(action.character, action.square) then
        return true
    end
    if props.isMultiSprite and action.square and props.getSpriteGridTopLeft and props.getMultiTileSquares then
        ensureMultiSpriteSquares(props, action.square)
        local left, top = props:getSpriteGridTopLeft(action.square:getX(), action.square:getY())
        local squares = props:getMultiTileSquares(left, top, action.square:getZ())
        if squares then
            for _, sq in ipairs(squares) do
                if sq and withinCatwalkReach(action.character, sq) then
                    return true
                end
            end
        end
    end
    return false
end

--- Hanging decor within arm's reach: skip pathing (railing tiles fail canReachTo
--- even when you're standing next to them). Anything further away still walks.
function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, origSpriteName)
    if (mode == "place" or mode == "pickup") and character and square
        and isFloatingDecorInReach(self, character, square)
    then
        ensureMultiSpriteSquares(self, square)
        return tryEquipModeTool(self, character, mode)
    end
    local ok = _walkToAndEquip(self, character, square, mode, origSpriteName)
    if ok or not LayeredPlacement.allowCatwalkReach() then
        return ok
    end
    if (mode ~= "place" and mode ~= "pickup") or not character or not square then
        return ok
    end
    if not LayeredPlacement.isReachDecor(self) then
        return ok
    end
    if not walkToDecorSquare(self, character, square) then
        return false
    end
    return tryEquipModeTool(self, character, mode)
end

local _isAdjacentToAnySquare = ISMoveablesAction.isAdjacentToAnySquare
local _isValidMoveablesAction = ISMoveablesAction.isValid
local _getDurationMoveablesAction = ISMoveablesAction.getDuration

function ISMoveablesAction:isAdjacentToAnySquare()
    if _isAdjacentToAnySquare(self) then
        return true
    end
    return isCatwalkReachAction(self)
end

--- Reachable decor never aborts mid-spinner on adjacency; walking away still
--- cancels it, because the reach test is re-evaluated every tick.
function ISMoveablesAction:isValid()
    if not isCatwalkReachAction(self) then
        return _isValidMoveablesAction(self)
    end
    if not self.square or not self.character then
        self:stop()
        return false
    end
    if isClient() and SafeHouse.isSafeHouse(self.square, self.character:getUsername(), true) then
        if not SafeHouse.isSafehouseAllowLoot(self.square, self.character) then
            self:stop()
            return false
        end
    end
    return true
end

--- Floating highs: keep the near-instant feel on MP while still running
--- complete() on the server so objects persist across rejoin.
function ISMoveablesAction:getDuration()
    if isFloatingDecorAction(self) then
        return 1
    end
    return _getDurationMoveablesAction(self)
end

LayeredPlacement.log("place hooks ready (floating decor place/pickup)")
