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

local function findPlaceItem(props, character, origSpriteName)
    if not character then
        return nil
    end
    if props.isForceSingleItem then
        local item = props:findInInventoryMultiSprite(character, props.name .. " (1/1)")
        if item then
            return item
        end
    end
    if origSpriteName then
        return props:findInInventory(character, origSpriteName)
    end
    return nil
end

--- Cursor validation can pass, then placeMoveable re-checks the 2-tile grid at
--- complete() and silently returns (spinner finishes, nothing placed). Ensure
--- partner squares exist and place floating highs brush-style when needed.
function ISMoveableSpriteProps:placeMoveable(character, square, origSpriteName, forceAllow)
    if LayeredPlacement.isPlaceHelpEnabled() and isLayerDecor(self) and (self.isHigh or self.isLow) then
        ensureMultiSpriteSquares(self, square)
        if self.isMultiSprite and self.isForceSingleItem and LayeredPlacement.allowFloatingPlace() then
            local spriteGrid = self.sprite and self.sprite:getSpriteGrid()
            local item = findPlaceItem(self, character, origSpriteName)
            local sgrid = spriteGrid and square and self:getSpriteGridInfo(square, false)
            if item and sgrid then
                local sX = square:getX() - spriteGrid:getSpriteGridPosX(self.sprite)
                local sY = square:getY() - spriteGrid:getSpriteGridPosY(self.sprite)
                local sZ = square:getZ()
                local ok = true
                for _, gridMember in ipairs(sgrid) do
                    local memberSq = gridMember.square
                    if not memberSq and gridMember.x ~= nil and gridMember.y ~= nil then
                        memberSq = LayeredPlacement.ensureGridSquare(sX + gridMember.x, sY + gridMember.y, sZ)
                        gridMember.square = memberSq
                    end
                    if not memberSq or not self:canPlaceMoveableInternal(character, memberSq, item) then
                        ok = false
                        break
                    end
                end
                if ok then
                    for _, gridMember in ipairs(sgrid) do
                        if gridMember.square and gridMember.sprite then
                            local gridItem = item
                            if gridMember.sprite ~= spriteGrid:getAnchorSprite() then
                                gridItem = self:instanceItem(gridMember.sprite:getName()) or item
                            end
                            self:placeMoveableInternal(gridMember.square, gridItem, gridMember.sprite:getName())
                        end
                    end
                    character:getInventory():Remove(item)
                    if sendRemoveItemFromContainer then
                        sendRemoveItemFromContainer(character:getInventory(), item)
                    end
                    if ISMoveableCursor and ISMoveableCursor.clearCacheForAllPlayers then
                        ISMoveableCursor.clearCacheForAllPlayers()
                    end
                    LayeredPlacement.log("placed floating multi decor @ "
                        .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ()))
                    return
                end
            end
        end
        -- Single-sprite floating high: allow force path if vanilla re-check is picky.
        forceAllow = true
    end
    return _placeMoveable(self, character, square, origSpriteName, forceAllow)
end

function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
    local canPlace = _canPlaceMoveableInternal(self, character, square, item, forceTypeObject)
    if canPlace or not LayeredPlacement.isPlaceHelpEnabled() then
        return canPlace
    end
    return tryAllowLayered(self, character, square, item, forceTypeObject)
end

--- Multi-sprite pickup needs every grid cell. Floating edge lights sometimes lose a
--- partner square lookup; allow retrieving highs/lows from the clicked tile anyway.
function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local ok = _canPickUpMoveable(self, character, square, object)
    if ok or not LayeredPlacement.allowFloatingPlace() then
        return ok
    end
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) then
        return ok
    end
    return self:canPickUpMoveableInternal(character, square, object, false)
end

function ISMoveableSpriteProps:pickUpMoveable(character, square, createItem, forceAllow)
    if LayeredPlacement.allowFloatingPlace() and isLayerDecor(self) and self.isMultiSprite then
        ensureMultiSpriteSquares(self, square)
    end
    local result = _pickUpMoveable(self, character, square, createItem, forceAllow)
    if result ~= nil or not LayeredPlacement.allowFloatingPlace() then
        return result
    end
    if not isLayerDecor(self) or not (self.isHigh or self.isLow) or not square then
        return result
    end
    -- Grid partner missing: remove whatever parts we can find and grant one item.
    local obj, sprInstance = self:findOnSquare(square, self.spriteName)
    if not obj then
        return result
    end
    if not (forceAllow or character:isMovablesCheat() or ISMoveableDefinitions.cheat
        or self:canPickUpMoveableInternal(character, square, not sprInstance and obj or nil, false)) then
        return result
    end
    local spriteGrid = self.sprite and self.sprite:getSpriteGrid()
    if spriteGrid then
        local sX = square:getX() - spriteGrid:getSpriteGridPosX(self.sprite)
        local sY = square:getY() - spriteGrid:getSpriteGridPosY(self.sprite)
        local sZ = square:getZ()
        for gx = 0, spriteGrid:getWidth() - 1 do
            for gy = 0, spriteGrid:getHeight() - 1 do
                local partSprite = spriteGrid:getSprite(gx, gy)
                if partSprite then
                    local partSq = getCell():getGridSquare(sX + gx, sY + gy, sZ)
                    local partObj, partSpr = self:findOnSquare(partSq, partSprite:getName())
                    if partObj then
                        self:pickUpMoveableInternal(
                            character, partSq, partObj, partSpr, partSprite:getName(), false, forceAllow
                        )
                    end
                end
            end
        end
        if createItem then
            local anchor = spriteGrid:getAnchorSprite()
            local item = self:instanceItem(anchor and anchor:getName() or self.spriteName)
            if item then
                character:getInventory():AddItem(item)
                if sendAddItemToContainer then
                    sendAddItemToContainer(character:getInventory(), item)
                end
            end
        end
        return {}
    end
    return self:pickUpMoveableInternal(character, square, obj, sprInstance, self.spriteName, createItem, forceAllow)
end

function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if not LayeredPlacement.isPlaceHelpEnabled() or not isLayerDecor(self) then
        return _canPlaceMoveable(self, character, square, item)
    end

    if not square or square:has(IsoFlagType.water) then
        return false
    end
    -- Same as tryAllowLayered: ignore under-catwalk vehicle flags for floating highs.
    if square:isVehicleIntersecting() and not ((self.isHigh or self.isLow) and LayeredPlacement.allowFloatingPlace()) then
        return false
    end

    if self.isMoveable and self.isMultiSprite then
        local spriteGrid = self.sprite:getSpriteGrid()
        if not spriteGrid then
            return false
        end

        -- Floating catwalk edges often lack grid squares for the 2nd light tile.
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

        local sX = square:getX() - spriteGrid:getSpriteGridPosX(self.sprite)
        local sY = square:getY() - spriteGrid:getSpriteGridPosY(self.sprite)
        local sZ = square:getZ()
        for _, gridMember in ipairs(sgrid) do
            local memberSq = gridMember.square
            if not memberSq and gridMember.x ~= nil and gridMember.y ~= nil then
                memberSq = LayeredPlacement.ensureGridSquare(sX + gridMember.x, sY + gridMember.y, sZ)
                gridMember.square = memberSq
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
--- Must stay in sync: starting Place without matching isValid just spins then cancels.
local REACH_DIST = 3

local function withinCatwalkReach(character, square)
    local charSquare = character and character:getSquare()
    if not charSquare or not square then
        return false
    end
    -- ISMoveablesAction:isValid requires the same Z.
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
    -- Path adjacent to any cell of a multi-tile light string.
    if props.isMultiSprite and props.getSpriteGridTopLeft and props.getMultiTileSquares and luautils.walkAdjSquares then
        local left, top = props:getSpriteGridTopLeft(square:getX(), square:getY())
        local squares = props:getMultiTileSquares(left, top, square:getZ())
        if squares and luautils.walkAdjSquares(character, squares, true, true) then
            return true
        end
    end
    return false
end

local function isCatwalkReachAction(action)
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
    -- Allow finishing when adjacent to any cell of a multi-tile string.
    if props.isMultiSprite and action.square and props.getSpriteGridTopLeft and props.getMultiTileSquares then
        local left, top = props:getSpriteGridTopLeft(action.square:getX(), action.square:getY())
        local squares = props:getMultiTileSquares(left, top, action.square:getZ())
        if squares then
            for _, sq in ipairs(squares) do
                if withinCatwalkReach(action.character, sq) then
                    return true
                end
            end
        end
    end
    return false
end

--- When pathing can't reach awkward catwalk/railing tiles, allow Place and Pickup
--- if the player is already next to the tile — or walk to a nearby floor tile first.
function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, origSpriteName)
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

--- walkToAndEquip can start the action via catwalkReach, but vanilla isValid still
--- demands isAdjacentTo (dist 1). Extend adjacency so the action can finish.
local _isAdjacentToAnySquare = ISMoveablesAction.isAdjacentToAnySquare
local _isValidMoveablesAction = ISMoveablesAction.isValid

function ISMoveablesAction:isAdjacentToAnySquare()
    if _isAdjacentToAnySquare(self) then
        return true
    end
    return isCatwalkReachAction(self)
end

--- Also short-circuit the full isValid path: same-Z + adjacency abort is what
--- produces the Place spinner with no result on railing/catwalk tiles.
function ISMoveablesAction:isValid()
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

--- Let vanilla place WallObjects once canPlace is allowed. The old createTile /
--- hand-rolled IsoLightSwitch path skipped TransferComponents and broke MP sync.
--- (Streetlight createTile remains vanilla's problem only.)

LayeredPlacement.log("place hooks ready (floating decor)")
