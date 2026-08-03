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
local function tryAllowLayered(props, character, square, item, forceTypeObject)
    if not props.isMoveable or not square then
        return false
    end
    if not LayeredPlacement.isPlaceHelpEnabled() then
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
        -- Stack freely when a wall/attach surface exists. Do not allow mid-air.
        if not hasAttachSurface(props, square) then
            return false
        end
    else
        if LayeredPlacement.allowFloatingPlace() then
            -- ok
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

--- Brush/cheat spawn: bypass vanilla placeMoveableInternal quirks on empty air tiles.
--- Never runs on a pure MP client — local AddSpecialObject does not persist.
local function forceSpawnDecor(square, spriteName, item)
    if not square or not spriteName then
        return false
    end
    if not LayeredPlacement.canMutateWorld() then
        return false
    end
    local spr = getSprite(spriteName)
    if not spr then
        return false
    end
    local obj = nil
    local ok, err = pcall(function()
        local tileType = spr:getType()
        if tileType == IsoObjectType.lightswitch then
            obj = IsoLightSwitch.new(getCell(), square, spr, square:getRoomID())
            if obj.addLightSourceFromSprite then
                obj:addLightSourceFromSprite()
            end
            if item and obj.getCustomSettingsFromItem then
                obj:getCustomSettingsFromItem(item)
            end
        else
            -- Match vanilla N/W WallOverlay place: IsoObject from IsoSprite.
            obj = IsoObject.new(getCell(), square, spr)
        end
        if obj and item and GameEntityFactory then
            if item.hasComponents and (not item:hasComponents()) and GameEntityFactory.CreateIsoEntityFromCellLoading then
                GameEntityFactory.CreateIsoEntityFromCellLoading(obj)
            end
            if GameEntityFactory.TransferComponents then
                GameEntityFactory.TransferComponents(item, obj)
            end
        end
        square:AddSpecialObject(obj)
        if isServer() and obj.transmitCompleteItemToClients then
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
        LayeredPlacement.log("direct spawn failed: " .. tostring(err))
        return false
    end
    return obj ~= nil
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
            for i, gridMember in ipairs(members) do
                if placePart(props, gridMember.square, parts[i].item, gridMember.sprite:getName()) then
                    placed = placed + 1
                    removePlacedInventoryItem(character, parts[i].item, parts[i].container)
                    LayeredPlacement.markConstruction(gridMember.square)
                end
            end
        else
            local item, container = findPlaceItem(props, character, origSpriteName)
            if not item then
                LayeredPlacement.log("cheat place: no item for " .. tostring(props.name))
                return false
            end
            local anchor = spriteGrid:getAnchorSprite()
            for _, gridMember in ipairs(members) do
                local gridItem = item
                if gridMember.sprite ~= anchor then
                    gridItem = props:instanceItem(gridMember.sprite:getName()) or item
                end
                if placePart(props, gridMember.square, gridItem, gridMember.sprite:getName()) then
                    placed = placed + 1
                    LayeredPlacement.markConstruction(gridMember.square)
                end
            end
            if placed > 0 then
                removePlacedInventoryItem(character, item, container)
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
        LayeredPlacement.log("placed floating decor @ "
            .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
            .. " parts=" .. tostring(placed))
        return true
    end
    LayeredPlacement.log("floating place produced 0 parts")
    return false
end

local function cheatPickUpFloating(props, character, square, createItem)
    ensureMultiSpriteSquares(props, square)
    -- forceAllow=true: same as movables cheat for this tile. Vanilla returns false
    -- (not nil) when a grid partner is missing, which is the case we recover from.
    local result = _pickUpMoveable(props, character, square, createItem, true)
    if result ~= nil and result ~= false then
        return result
    end
    local obj, sprInstance = props:findOnSquare(square, props.spriteName)
    if not obj then
        return nil
    end
    local spriteGrid = props.sprite and props.sprite:getSpriteGrid()
    if spriteGrid then
        -- Non-ForceSingleItem grids hand back one item per sprite, like vanilla.
        local perPartItem = createItem and not props.isForceSingleItem
        local sX = square:getX() - spriteGrid:getSpriteGridPosX(props.sprite)
        local sY = square:getY() - spriteGrid:getSpriteGridPosY(props.sprite)
        local sZ = square:getZ()
        for gx = 0, spriteGrid:getWidth() - 1 do
            for gy = 0, spriteGrid:getHeight() - 1 do
                local partSprite = spriteGrid:getSprite(gx, gy)
                if partSprite then
                    local partSq = LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ)
                    local partObj, partSpr = props:findOnSquare(partSq, partSprite:getName())
                    if partObj then
                        props:pickUpMoveableInternal(
                            character, partSq, partObj, partSpr, partSprite:getName(), perPartItem, true
                        )
                    end
                end
            end
        end
        if createItem and props.isForceSingleItem then
            local anchor = spriteGrid:getAnchorSprite()
            local item = props:instanceItem(anchor and anchor:getName() or props.spriteName)
            if item then
                character:getInventory():AddItem(item)
                if sendAddItemToContainer then
                    sendAddItemToContainer(character:getInventory(), item)
                end
            end
        end
        if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
            ISMoveableCursor.clearCacheForAllPlayers()
        end
        LayeredPlacement.log("picked up floating multi decor")
        return {}
    end
    return props:pickUpMoveableInternal(character, square, obj, sprInstance, props.spriteName, createItem, true)
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
    local canPersist = LayeredPlacement.canMutateWorld()

    -- Prefer vanilla internals first when we can persist (server/SP).
    if canPersist then
        pcall(function()
            props:placeMoveableInternal(square, item, spriteName)
        end)
        if appeared() then
            return finishOk(item, "vanilla")
        end
    end

    if isOverlay and isEastOrSouth and wall then
        -- E/S: attach (transmitUpdatedSpriteToServer is valid on MP clients).
        if attachWallOverlay(wall, spriteName) and appeared() then
            return finishOk(item, "wall-attached")
        end
        if canPersist and forceSpawnDecor(square, spriteName, item) and appeared() then
            return finishOk(item, "spawned-same-side")
        end
    elseif isOverlay and isNorthOrWest then
        -- N/W: free object on the aimed square only — never attach to the
        -- adjacent wall (that lands in the other room).
        if canPersist and forceSpawnDecor(square, spriteName, item) and appeared() then
            return finishOk(item, "spawned-aimed")
        end
    else
        -- Plain WallObject / WindowObject: free object on aimed square.
        if canPersist and forceSpawnDecor(square, spriteName, item) and appeared() then
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
    if LayeredPlacement.isWallDecor(self) and LayeredPlacement.isPlaceHelpEnabled() and square then
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
    if LayeredPlacement.isPlaceHelpEnabled() and isLayerDecor(self) then
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
    -- Wall hangings: prefer our stacking rules over vanilla's one-overlay /
    -- one-IsHigh limit so a second poster on the same wall isn't red.
    if LayeredPlacement.isWallDecor(self) and LayeredPlacement.isPlaceHelpEnabled() then
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
        return self:canPickUpMoveableInternal(character, square, object, false)
    end
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local ok = _canPickUpMoveable(self, character, square, object)
    if ok or not LayeredPlacement.allowFloatingPlace() then
        return ok
    end
    -- Wall/object highs on railings: allow pickup without full grid partners.
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) then
        return ok
    end
    return self:canPickUpMoveableInternal(character, square, object, false)
end

function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    if isFloatingObjectDecor(self) and square then
        local obj = self:findOnSquare(square, self.spriteName)
        if forceAllow or self:canPickUpMoveable(character, square, obj) then
            return cheatPickUpFloating(self, character, square, createItem)
        end
        return nil
    end
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local result = _pickUpMoveable(self, character, square, createItem, forceAllow)
    if (result ~= nil and result ~= false) or not LayeredPlacement.allowFloatingPlace() then
        return result
    end
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) or not square then
        return result
    end
    -- Grid partner missing: remove whatever parts we can find (wall/object highs).
    return cheatPickUpFloating(self, character, square, createItem)
end

function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if not LayeredPlacement.isPlaceHelpEnabled() or not isLayerDecor(self) then
        return _canPlaceMoveable(self, character, square, item)
    end

    if not square or square:has(IsoFlagType.water) then
        return false
    end

    -- Hanging decor (lights, canopies): brush-green when the grid fits and we
    -- hold the item(s). Cross-Z aims (catwalk → ground wall) are allowed.
    if isFloatingObjectDecor(self) then
        if not LayeredPlacement.hasPlaceRequirements(self, character) then
            return false
        end
        if not LayeredPlacement.withinBrushReach(character, square) then
            -- Still allow the cursor to show valid if multi-tile reaches us.
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

    -- Wall hangings / posters: stacking check lives here so the cursor turns
    -- green even when vanilla would keep it red for a second high/overlay.
    if LayeredPlacement.isWallDecor(self) then
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

    -- Wall hangings: allow over vehicles when floating is on; otherwise keep
    -- the vanilla vehicle check. Occupancy is handled in canPlaceMoveableInternal.
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
    if LayeredPlacement.isPlaceHelpEnabled() and isLayerDecor(self) then
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
