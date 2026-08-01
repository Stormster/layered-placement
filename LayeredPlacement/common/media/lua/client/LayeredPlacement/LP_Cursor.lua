require "LayeredPlacement/LP_Shared"
require "BuildingObjects/ISBuildingObject"

--- Deferred: ISMoveableCursor lives under server/BuildingObjects and is often
--- nil when client scripts first load (was crashing on ISMoveableCursor.render).
local hooked = false

local REACH_DIST = 2

local function withinCatwalkReach(character, square)
    local charSq = character and (character:getSquare() or character:getCurrentSquare())
    if not charSq or not square then
        return false
    end
    if charSq:getZ() ~= square:getZ() then
        return false
    end
    local dx = math.abs(charSq:getX() - square:getX())
    local dy = math.abs(charSq:getY() - square:getY())
    return math.max(dx, dy) <= REACH_DIST
end

local function isDecorProps(props)
    if not props or not props.isMoveable then
        return false
    end
    if props.isHigh or props.isLow then
        return true
    end
    local t = props.type
    return t == "WallObject" or t == "WallOverlay" or t == "WindowObject"
end

local function aimSquare(self)
    return self.currentSquare or self.square
end

--- Multi-sprite pickup skips FloorTileCursor and only ghosts real floors.
--- Floating railing lights often have no floor, so draw the white square ourselves.
local function drawPickupFloorCursor(self, x, y, z)
    local mode = ISMoveableCursor.mode[self.player]
    if mode ~= "pickup" or not self.currentMoveProps or not self.currentMoveProps.isMultiSprite then
        return
    end
    local cursor = self.getFloorCursorSprite and self:getFloorCursorSprite()
    if not cursor then
        return
    end

    local props = self.currentMoveProps
    local spriteGrid = props.sprite and props.sprite:getSpriteGrid()
    if not spriteGrid then
        cursor:RenderGhostTileColor(x, y, z, 0.75, 1, 0.75, 0.25)
        return
    end

    local xo = spriteGrid:getSpriteGridPosX(props.sprite)
    local yo = spriteGrid:getSpriteGridPosY(props.sprite)
    local wx, wy = x - xo, y - yo
    for gx = 0, spriteGrid:getWidth() - 1 do
        for gy = 0, spriteGrid:getHeight() - 1 do
            if spriteGrid:getSprite(gx, gy) then
                cursor:RenderGhostTileColor(wx + gx, wy + gy, z, 0.75, 1, 0.75, 0.25)
            end
        end
    end
end

local function hookCursor()
    if hooked then
        return
    end
    if not ISMoveableCursor or not ISMoveableCursor.isValid then
        return
    end
    hooked = true

    local _isValid = ISMoveableCursor.isValid
    local _render = ISMoveableCursor.render
    local _beforeWorldRender = ISMoveableCursor.beforeWorldRender
    local _create = ISMoveableCursor.create
    local _tryBuild = ISBuildingObject.tryBuild
    local _walkTo = ISBuildingObject.walkTo

    function ISMoveableCursor:isValid(square)
        local mode = ISMoveableCursor.mode[self.player]
        if not (LayeredPlacement.allowMeshFloorAim() and square and (mode == "place" or mode == "pickup")) then
            return _isValid(self, square)
        end

        -- Pickup: remap BEFORE isValid so getObjectList sees objects on your floor,
        -- not the ground tile the mouse fell through to.
        if mode == "pickup" then
            local target = LayeredPlacement.resolveFloatingSquare(self.character, square, nil, self.player)
            if target and target ~= square then
                self.square = target
                self.currentSquare = target
                return _isValid(self, target)
            end
            return _isValid(self, square)
        end

        -- Place: populate currentMoveProps from the clicked square first, then remap Z.
        -- Re-project mouse onto the player's floor so mesh fallthrough uses the
        -- catwalk XY you're looking at, not the ground tile the ray hit.
        local ok = _isValid(self, square)
        local props = self.currentMoveProps or self.origMoveProps
        local target = LayeredPlacement.resolveFloatingSquare(self.character, square, props, self.player)
        if target and target ~= square then
            ok = _isValid(self, target)
            -- create() / DoTileBuilding use square + currentSquare; keep both remapped.
            self.square = target
            self.currentSquare = target
        end
        return ok
    end

    if _render then
        function ISMoveableCursor:render(x, y, z, square)
            local cs = aimSquare(self)
            if cs and (cs:getX() ~= x or cs:getY() ~= y or cs:getZ() ~= z) then
                x, y, z, square = cs:getX(), cs:getY(), cs:getZ(), cs
            end
            local result = _render(self, x, y, z, square)
            drawPickupFloorCursor(self, x, y, z)
            return result
        end
    end

    if _beforeWorldRender then
        function ISMoveableCursor:beforeWorldRender(x, y, z)
            if self.square and (self.isLeftDown or self.build) then
                return _beforeWorldRender(self, self.square:getX(), self.square:getY(), self.square:getZ())
            end
            return _beforeWorldRender(self, x, y, z)
        end
    end

    if _create then
        function ISMoveableCursor:create(x, y, z, north, sprite)
            local cs = aimSquare(self)
            if cs then
                return _create(self, cs:getX(), cs:getY(), cs:getZ(), north, sprite)
            end
            return _create(self, x, y, z, north, sprite)
        end
    end

    -- DoTileBuilding keeps mouse Z when left-clicking; force remapped floor coords.
    function ISMoveableCursor:tryBuild(x, y, z)
        local cs = aimSquare(self)
        if LayeredPlacement.allowMeshFloorAim() and cs then
            return _tryBuild(self, cs:getX(), cs:getY(), cs:getZ())
        end
        return _tryBuild(self, x, y, z)
    end

    -- tryBuild requires walkTo before create(). Floating railing tiles often fail
    -- canReachTo even when you're standing next to them — same catwalkReach idea.
    function ISMoveableCursor:walkTo(x, y, z)
        local cs = aimSquare(self)
        if LayeredPlacement.allowMeshFloorAim() and cs then
            x, y, z = cs:getX(), cs:getY(), cs:getZ()
        end
        if _walkTo(self, x, y, z) then
            return true
        end
        if not LayeredPlacement.allowCatwalkReach() then
            return false
        end
        local mode = ISMoveableCursor.mode[self.player]
        if mode ~= "place" and mode ~= "pickup" then
            return false
        end
        local props = self.currentMoveProps or self.origMoveProps
        if not isDecorProps(props) then
            return false
        end
        local square = getCell() and getCell():getGridSquare(x, y, z) or cs
        return withinCatwalkReach(self.character, square)
    end

    LayeredPlacement.log("cursor floating Z hook ready")
end

Events.OnGameBoot.Add(hookCursor)
Events.OnGameStart.Add(hookCursor)
-- MP clients sometimes finish loading BuildingObjects after OnGameStart.
Events.OnCreatePlayer.Add(function()
    hookCursor()
end)
Events.OnTick.Add(function()
    if not hooked then
        hookCursor()
    end
end)
