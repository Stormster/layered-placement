require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"
require "Moveables/ISMoveablesAction"

--- Decor / layer items we treat more like brush placement.
local function isLayerDecor(props)
    if not props or not props.isMoveable then
        return false
    end
    if props.isHigh or props.isLow then
        return true
    end
    local t = props.type
    return t == "WallObject" or t == "WallOverlay" or t == "WindowObject"
end

local function hasWallForDecor(props, square)
    if not props.facing then
        return false
    end
    if props.allowDoorFrame then
        return props:getWallForFacing(square, props.facing, "WallAndDoor") and true or false
    end
    return props:getWallForFacing(square, props.facing) and true or false
end

--- Brush-like: high/low may float (no floor required). Wall decor still needs a wall
--- unless floating place is enabled.
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
    if square:has("tree") then
        return false
    end

    local isHighLow = props.isHigh or props.isLow
    -- Parked cars under a catwalk flag upstairs tiles as vehicle-intersecting.
    -- Floating highs/lows on the railing should ignore that.
    if square:isVehicleIntersecting() and not (isHighLow and LayeredPlacement.allowFloatingPlace()) then
        return false
    end

    if props.type == "WallOverlay" or props.type == "WindowObject" then
        if not hasWallForDecor(props, square) then
            return false
        end
        if not LayeredPlacement.allowLayeredPlace() then
            return false
        end
    elseif props.type == "WallObject" then
        if isHighLow then
            if not hasWallForDecor(props, square) then
                if not LayeredPlacement.allowFloatingPlace() then
                    return false
                end
            elseif not LayeredPlacement.allowLayeredPlace() and not LayeredPlacement.allowFloatingPlace() then
                return false
            end
        else
            if not hasWallForDecor(props, square) then
                return false
            end
            if not LayeredPlacement.allowLayeredPlace() then
                return false
            end
        end
    else
        -- Object-type highs/lows (string lights, etc.)
        if isHighLow and LayeredPlacement.allowFloatingPlace() then
            -- ok (railings / open air on that level)
        elseif LayeredPlacement.allowLayeredPlace() then
            -- ok (over furniture / multiple highs)
        else
            return false
        end
    end

    return LayeredPlacement.hasPlaceRequirements(props, character)
end

local function chebyshevDist(squareA, squareB)
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
    for gx = 0, spriteGrid:getWidth() - 1 do
        for gy = 0, spriteGrid:getHeight() - 1 do
            if spriteGrid:getSprite(gx, gy) then
                LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ)
            end
        end
    end
end

local function isFloatingHighLow(props)
    return LayeredPlacement.allowFloatingPlace()
        and isLayerDecor(props)
        and props
        and (props.isHigh or props.isLow)
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
                local memberSq = LayeredPlacement.ensureGridSquare(sX + gx, sY + gy, sZ)
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
local function forceSpawnDecor(square, spriteName, item)
    if not square or not spriteName then
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
            obj = IsoObject.new(getCell(), square, spriteName)
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
        triggerEvent("OnObjectAdded", obj)
    end)
    if not ok then
        print("[LayeredPlacement] forceSpawn failed: " .. tostring(err))
        return false
    end
    return obj ~= nil
end

local function cheatPlaceFloating(props, character, square, origSpriteName)
    ensureMultiSpriteSquares(props, square)
    local item, container = findPlaceItem(props, character, origSpriteName)
    if not item then
        print("[LayeredPlacement] cheat place: no item for " .. tostring(props.name))
        return false
    end

    local placed = 0
    if props.isMultiSprite then
        local members, spriteGrid = buildFloatingGridMembers(props, square)
        if not members then
            print("[LayeredPlacement] cheat place: could not build grid members")
            return false
        end
        local anchor = spriteGrid:getAnchorSprite()
        for _, gridMember in ipairs(members) do
            local gridItem = item
            if gridMember.sprite ~= anchor then
                gridItem = props:instanceItem(gridMember.sprite:getName()) or item
            end
            local name = gridMember.sprite:getName()
            pcall(function()
                props:placeMoveableInternal(gridMember.square, gridItem, name)
            end)
            local found = props:findOnSquare(gridMember.square, name)
            if not found then
                forceSpawnDecor(gridMember.square, name, gridItem)
                found = props:findOnSquare(gridMember.square, name)
            end
            if found then
                placed = placed + 1
            end
        end
    else
        local name = props.spriteName or origSpriteName
        pcall(function()
            props:placeMoveableInternal(square, item, name)
        end)
        local found = props:findOnSquare(square, name)
        if not found then
            forceSpawnDecor(square, name, item)
            found = props:findOnSquare(square, name)
        end
        if found then
            placed = 1
        end
    end

    if placed > 0 then
        removePlacedInventoryItem(character, item, container)
        if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
            ISMoveableCursor.clearCacheForAllPlayers()
        end
        print("[LayeredPlacement] cheat-placed floating decor @ "
            .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
            .. " parts=" .. tostring(placed))
        return true
    end
    print("[LayeredPlacement] cheat place produced 0 parts")
    return false
end

local function cheatPickUpFloating(props, character, square, createItem)
    ensureMultiSpriteSquares(props, square)
    -- forceAllow=true: same as movables cheat for this tile.
    local result = _pickUpMoveable(props, character, square, createItem, true)
    if result ~= nil then
        return result
    end
    local obj, sprInstance = props:findOnSquare(square, props.spriteName)
    if not obj then
        return nil
    end
    local spriteGrid = props.sprite and props.sprite:getSpriteGrid()
    if spriteGrid then
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
                            character, partSq, partObj, partSpr, partSprite:getName(), false, true
                        )
                    end
                end
            end
        end
        if createItem then
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
        print("[LayeredPlacement] cheat-picked floating multi decor")
        return {}
    end
    return props:pickUpMoveableInternal(character, square, obj, sprInstance, props.spriteName, createItem, true)
end

--- Floating highs/lows: cheat them into place (no canPlace re-check).
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    if isFloatingHighLow(self) and square then
        if cheatPlaceFloating(self, character, square, origSpriteName) then
            return
        end
    end
    if LayeredPlacement.isPlaceHelpEnabled() and isLayerDecor(self) and (self.isHigh or self.isLow) then
        forceAllow = true
    end
    return _placeMoveable(self, character, square, origSpriteName, forceAllow)
end

function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
    -- Floating highs: treat like movables cheat for validation.
    if isFloatingHighLow(self) and square and not square:has(IsoFlagType.water) and not square:has("tree") then
        return true
    end
    local canPlace = _canPlaceMoveableInternal(self, character, square, item, forceTypeObject)
    if canPlace or not LayeredPlacement.isPlaceHelpEnabled() then
        return canPlace
    end
    return tryAllowLayered(self, character, square, item, forceTypeObject)
end

function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if isFloatingHighLow(self) then
        ensureMultiSpriteSquares(self, square)
        return true
    end
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    return _canPickUpMoveable(self, character, square, object)
end

function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    if isFloatingHighLow(self) and square then
        return cheatPickUpFloating(self, character, square, createItem)
    end
    return _pickUpMoveable(self, character, square, createItem, forceAllow)
end

function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if not LayeredPlacement.isPlaceHelpEnabled() or not isLayerDecor(self) then
        return _canPlaceMoveable(self, character, square, item)
    end

    if not square or square:has(IsoFlagType.water) then
        return false
    end

    -- Floating highs/lows: green cursor if the grid cells can exist + item is held.
    if isFloatingHighLow(self) then
        if self.isMultiSprite then
            ensureMultiSpriteSquares(self, square)
            local members = buildFloatingGridMembers(self, square)
            if not members then
                return false
            end
        end
        local invItem = item
        if self.isForceSingleItem then
            invItem = self:findInInventoryMultiSprite(character, self.name .. " (1/1)") or item
        end
        return invItem ~= nil
    end

    if square:isVehicleIntersecting() then
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
            if not self:canPlaceMoveableInternal(character, gridMember.square, invItem) then
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
local REACH_DIST = 3

local function withinCatwalkReach(character, square)
    local charSquare = character and character:getSquare()
    if not charSquare or not square then
        return false
    end
    if charSquare:getZ() ~= square:getZ() then
        return false
    end
    return chebyshevDist(charSquare, square) <= REACH_DIST
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

--- Floating high/low Place/Pickup: treat like movables cheat so the spinner
--- cannot cancel before complete() (that was the silent no-place bug).
local function isFloatingDecorAction(action)
    if not action or (action.mode ~= "place" and action.mode ~= "pickup") then
        return false
    end
    local props = action.moveProps or action.origMoveProps
    return isFloatingHighLow(props)
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
    if not props or not isLayerDecor(props) then
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

--- Floating highs: skip pathing entirely (cheat-style). Just start the action.
function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, origSpriteName)
    if isFloatingHighLow(self) and (mode == "place" or mode == "pickup") and character and square then
        ensureMultiSpriteSquares(self, square)
        tryEquipModeTool(self, character, mode)
        return true
    end
    local ok = _walkToAndEquip(self, character, square, mode, origSpriteName)
    if ok or not LayeredPlacement.allowCatwalkReach() then
        return ok
    end
    if (mode ~= "place" and mode ~= "pickup") or not isLayerDecor(self) or not character or not square then
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

--- Cheat-style validity: floating highs never abort mid-spinner on adjacency.
function ISMoveablesAction:isValid()
    if isFloatingDecorAction(self) then
        if not self.square or not self.character then
            self:stop()
            return false
        end
        local plSquare = self.character:getSquare()
        if not plSquare or plSquare:getZ() ~= self.square:getZ() then
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
    if isCatwalkReachAction(self) then
        if isClient() and SafeHouse.isSafeHouse(self.square, self.character:getUsername(), true) then
            if self.mode == "place" or self.mode == "pickup" then
                if not SafeHouse.isSafehouseAllowLoot(self.square, self.character) then
                    self:stop()
                    return false
                end
            end
        end
        return true
    end
    return _isValidMoveablesAction(self)
end

function ISMoveablesAction:getDuration()
    if isFloatingDecorAction(self) then
        return 1
    end
    return _getDurationMoveablesAction(self)
end

LayeredPlacement.log("place hooks ready (floating cheat place/pickup)")
