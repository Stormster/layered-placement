require "LayeredPlacement/LP_Shared"
require "Moveables/ISMoveableSpriteProps"

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

local function tryEquipPlaceTool(props, character)
    if ISMoveableDefinitions.cheat or character:isMovablesCheat() then
        return true
    end
    if not props.placeTool then
        return true
    end
    local tool = props:hasTool(character, "place")
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

function ISMoveableSpriteProps:walkToAndEquip(character, square, mode, origSpriteName)
    local ok = _walkToAndEquip(self, character, square, mode, origSpriteName)
    if ok or not LayeredPlacement.allowCatwalkReach() then
        return ok
    end
    if mode ~= "place" or not isLayerDecor(self) or not character or not square then
        return ok
    end
    if not LayeredPlacement.isPlaceHelpEnabled() then
        return ok
    end
    local charSquare = character:getSquare()
    if not charSquare then
        return false
    end
    if math.abs(charSquare:getZ() - square:getZ()) > 1 then
        return false
    end
    if chebyshevDist(charSquare, square) > 2 then
        return false
    end
    return tryEquipPlaceTool(self, character)
end

local function findObjectBySprite(square, spriteName)
    if not square or not spriteName then
        return nil
    end
    local objects = square:getObjects()
    if not objects then
        return nil
    end
    for i = objects:size() - 1, 0, -1 do
        local obj = objects:get(i)
        local spr = obj:getSprite()
        if spr and spr:getName() == spriteName then
            return obj
        end
    end
    return nil
end

local _placeMoveableInternal = ISMoveableSpriteProps.placeMoveableInternal

function ISMoveableSpriteProps:placeMoveableInternal(square, item, spriteName)
    if LayeredPlacement.allowFloatingPlace()
        and self.type == "WallObject"
        and (self.isHigh or self.isLow)
        and square
        and spriteName
    then
        local hasWall = self.facing and self:getWallForFacing(square, self.facing)
        if not hasWall then
            createTile(spriteName, square)
            local obj = findObjectBySprite(square, spriteName)
            if obj and instanceof(obj, "IsoLightSwitch") then
                obj:addLightSourceFromSprite()
                if item then
                    obj:getCustomSettingsFromItem(item)
                end
            end
            square:RecalcProperties()
            square:RecalcAllWithNeighbours(true)
            IsoGenerator.updateGenerator(square)
            if obj then
                triggerEvent("OnObjectAdded", obj)
            end
            triggerEvent("OnContainerUpdate")
            LayeredPlacement.log("brush-tile floating WallObject " .. tostring(spriteName))
            return obj
        end
    end
    return _placeMoveableInternal(self, square, item, spriteName)
end

LayeredPlacement.log("place hooks ready (floating decor)")
