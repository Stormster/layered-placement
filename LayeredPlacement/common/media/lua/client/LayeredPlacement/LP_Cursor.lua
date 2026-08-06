require "LayeredPlacement/LP_Shared"

--- Deferred: ISMoveableCursor lives under server/BuildingObjects and is often
--- unavailable when client scripts first load. Wait for both cursor globals
--- instead of requiring the server-side file during the early MP load phase.
local hooked = false

local function withinCatwalkReach(character, square)
    return LayeredPlacement.withinReach(character, square, LayeredPlacement.REACH_DIST)
end

local function isDecorProps(props)
    return LayeredPlacement.isReachDecor(props)
end

local function aimSquare(self)
    return self.currentSquare or self.square
end

local function walkToCursorTarget(self, square)
    if withinCatwalkReach(self.character, square) then
        return true
    end
    if LayeredPlacement.walkToNearbyFloor(self.character, square, true) then
        return true
    end
    local props = self.currentMoveProps or self.origMoveProps
    if props and props.isMultiSprite and props.getSpriteGridTopLeft and props.getMultiTileSquares and luautils and luautils.walkAdjSquares then
        local left, top = props:getSpriteGridTopLeft(square:getX(), square:getY())
        local squares = props:getMultiTileSquares(left, top, square:getZ())
        if squares and luautils.walkAdjSquares(self.character, squares, true, true) then
            return true
        end
    end
    return false
end

--- Multi-sprite cursor skips FloorTileCursor and only ghosts real floors.
--- Floating railing lights often have no floor, so draw the white square ourselves
--- when mesh-aim or floating place is on.
local function drawMeshFloorCursor(self, x, y, z)
    if not (LayeredPlacement.allowMeshFloorAim() or LayeredPlacement.allowFloatingPlace()) then
        return
    end
    local mode = ISMoveableCursor.mode[self.player]
    if (mode ~= "pickup" and mode ~= "place") or not self.currentMoveProps or not self.currentMoveProps.isMultiSprite then
        return
    end
    if not LayeredPlacement.isReachDecor(self.currentMoveProps) then
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
    if not ISMoveableCursor or not ISMoveableCursor.isValid
        or not ISBuildingObject or not ISBuildingObject.tryBuild or not ISBuildingObject.walkTo
    then
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
            local target = LayeredPlacement.resolveFloatingSquare(self.character, square, nil, self.player, "pickup")
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
        local target = LayeredPlacement.resolveFloatingSquare(self.character, square, props, self.player, "place")
        -- nil target = could not lift; keep the aimed square (ground-wall from a
        -- catwalk is a valid intentional aim for floating highs).
        if target and target ~= square then
            ok = _isValid(self, target)
            self.square = target
            self.currentSquare = target
        end
        return ok
    end

    if _render then
        function ISMoveableCursor:render(x, y, z, square)
            if LayeredPlacement.allowMeshFloorAim() then
                -- Vanilla's cyan helper circle sits at the raw mouse Z (often the
                -- ground under a pillar); the remapped floor cursor is the real aim.
                self.renderFloorHelper = false
                local cs = aimSquare(self)
                if cs and (cs:getX() ~= x or cs:getY() ~= y or cs:getZ() ~= z) then
                    x, y, z, square = cs:getX(), cs:getY(), cs:getZ(), cs
                end
            end
            local result = _render(self, x, y, z, square)
            drawMeshFloorCursor(self, x, y, z)
            return result
        end
    end

    if _beforeWorldRender then
        function ISMoveableCursor:beforeWorldRender(x, y, z)
            if LayeredPlacement.allowMeshFloorAim() and self.square and (self.isLeftDown or self.build) then
                return _beforeWorldRender(self, self.square:getX(), self.square:getY(), self.square:getZ())
            end
            return _beforeWorldRender(self, x, y, z)
        end
    end

    if _create then
        function ISMoveableCursor:create(x, y, z, north, sprite)
            local cs = aimSquare(self)
            if LayeredPlacement.allowMeshFloorAim() and cs then
                x, y, z = cs:getX(), cs:getY(), cs:getZ()
            end

            -- Brush-style floating highs: SP/listen-host place locally (authoritative).
            -- Pure MP clients send a server command — timed actions often never
            -- start on fence/railing tiles (walkTo/canReach), and client spawns
            -- do not persist across rejoin.
            local mode = ISMoveableCursor.mode[self.player]
            local props = self.currentMoveProps or self.origMoveProps
            if (mode == "place" or mode == "pickup")
                and LayeredPlacement.isFloatingDecor(props)
                and self.canCreate
            then
                if self:cannotCreate(x, y, z) then
                    ISTimedActionQueue.clear(getSpecificPlayer(self.player))
                    self.cursorFacing = nil
                    self.joypadFacing = nil
                    self.objectListCache = nil
                    return
                end
                local square = (getCell() and getCell():getGridSquare(x, y, z)) or cs
                if square and LayeredPlacement.withinBrushReach(self.character, square) then
                    self.square = square
                    self.currentSquare = square
                    -- Place the *current facing* sprite (ghost), not origSpriteName
                    -- (inventory / unrotated). Otherwise rotation snaps back on MP.
                    local placeSprite = (props and props.spriteName)
                        or self.origSpriteName
                    local origSprite = self.origSpriteName or placeSprite
                    local cursorFacing = self.cursorFacing or self.joypadFacing
                    if LayeredPlacement.requestFloatingWorldAction(
                        self.character, square, placeSprite, mode, origSprite, cursorFacing
                    ) then
                        self.cursorFacing = nil
                        self.joypadFacing = nil
                        self.objectListCache = nil
                        return
                    end
                    if mode == "place" then
                        if cursorFacing and props then
                            props.cursorFacing = cursorFacing
                        end
                        props:placeMoveableViaCursor(
                            self.character, square, origSprite, self
                        )
                    else
                        props:pickUpMoveableViaCursor(
                            self.character, square, origSprite, self
                        )
                    end
                    self.cursorFacing = nil
                    self.joypadFacing = nil
                    self.objectListCache = nil
                    return
                end
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
    -- canReachTo even when you're standing next to them.
    -- floatingPlace owns cheat skip for highs/lows; catwalkReach is the milder helper.
    function ISMoveableCursor:walkTo(x, y, z)
        local cs = aimSquare(self)
        if LayeredPlacement.allowMeshFloorAim() and cs then
            x, y, z = cs:getX(), cs:getY(), cs:getZ()
        end
        if _walkTo(self, x, y, z) then
            return true
        end
        local mode = ISMoveableCursor.mode[self.player]
        if mode ~= "place" and mode ~= "pickup" then
            return false
        end
        local props = self.currentMoveProps or self.origMoveProps
        local square = getCell() and getCell():getGridSquare(x, y, z) or cs
        -- Hanging decor you're already standing next to: start the action without
        -- pathing. Wall hangings and anything further away path normally.
        if LayeredPlacement.isFloatingDecor(props)
            and LayeredPlacement.withinBrushReach(self.character, square or cs)
        then
            return true
        end
        if not LayeredPlacement.allowCatwalkReach() then
            return false
        end
        if not isDecorProps(props) then
            return false
        end
        return walkToCursorTarget(self, square or cs)
    end

    -- Remap mouse Z before DoTileBuilding assigns square / renders / tryBuilds.
    if type(DoTileBuilding) == "function" and not LayeredPlacement._doTileBuildingHooked then
        LayeredPlacement._doTileBuildingHooked = true
        local _DoTileBuilding = DoTileBuilding
        function DoTileBuilding(draggingItem, isRender, x, y, z, square)
            if LayeredPlacement.allowMeshFloorAim()
                and draggingItem
                and draggingItem.Type == "ISMoveableCursor"
                and square
            then
                local mode = ISMoveableCursor.mode[draggingItem.player]
                if mode == "place" or mode == "pickup" then
                    local char = draggingItem.character
                    local props = nil
                    if mode == "place" then
                        props = draggingItem.currentMoveProps or draggingItem.origMoveProps
                    end
                    local target = LayeredPlacement.resolveFloatingSquare(
                        char, square, props, draggingItem.player, mode
                    )
                    if target and target ~= square then
                        square = target
                        x = target:getX()
                        y = target:getY()
                        z = target:getZ()
                    end
                end
            end
            return _DoTileBuilding(draggingItem, isRender, x, y, z, square)
        end
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
