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
    if square:isVehicleIntersecting() then
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
local _isWallBetweenParts = ISMoveableSpriteProps.isWallBetweenParts
local _walkToAndEquip = ISMoveableSpriteProps.walkToAndEquip

function ISMoveableSpriteProps:canPlaceMoveableInternal(character, square, item, forceTypeObject)
    local canPlace = _canPlaceMoveableInternal(self, character, square, item, forceTypeObject)
    if canPlace or not LayeredPlacement.isPlaceHelpEnabled() then
        return canPlace
    end
    return tryAllowLayered(self, character, square, item, forceTypeObject)
end

function ISMoveableSpriteProps:canPlaceMoveable(character, square, item)
    if not LayeredPlacement.isPlaceHelpEnabled() or not isLayerDecor(self) then
        return _canPlaceMoveable(self, character, square, item)
    end

    if not square or square:has(IsoFlagType.water) then
        return false
    end
    if square:isVehicleIntersecting() then
        return false
    end

    if self.isMoveable and self.isMultiSprite then
        local spriteGrid = self.sprite:getSpriteGrid()
        if not spriteGrid then
            return false
        end
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
--- Must stay in sync: starting Place without matching isValid just spins then cancels.
local REACH_DIST = 2

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

local function isCatwalkReachAction(action)
    if not LayeredPlacement.allowCatwalkReach() then
        return false
    end
    if not action or (action.mode ~= "place" and action.mode ~= "pickup") then
        return false
    end
    local props = action.moveProps
    if not props or not isLayerDecor(props) then
        return false
    end
    return withinCatwalkReach(action.character, action.square)
end

--- When pathing can't reach awkward catwalk/railing tiles, allow Place and Pickup
--- if the player is already next to the tile.
function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, origSpriteName)
    local ok = _walkToAndEquip(self, character, square, mode, origSpriteName)
    if ok or not LayeredPlacement.allowCatwalkReach() then
        return ok
    end
    if (mode ~= "place" and mode ~= "pickup") or not isLayerDecor(self) or not character or not square then
        return ok
    end
    if not withinCatwalkReach(character, square) then
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
