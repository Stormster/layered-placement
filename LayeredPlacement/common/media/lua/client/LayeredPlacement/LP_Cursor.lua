require "LayeredPlacement/LP_Shared"

--- Deferred: ISMoveableCursor lives under server/BuildingObjects and is often
--- nil when client scripts first load (was crashing on ISMoveableCursor.render).
local hooked = false

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

    function ISMoveableCursor:isValid(square)
        if not (LayeredPlacement.allowMeshFloorAim() and ISMoveableCursor.mode[self.player] == "place" and square) then
            return _isValid(self, square)
        end

        -- Populate currentMoveProps from the clicked square first, then remap Z.
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
            local cs = self.currentSquare
            if cs and (cs:getX() ~= x or cs:getY() ~= y or cs:getZ() ~= z) then
                return _render(self, cs:getX(), cs:getY(), cs:getZ(), cs)
            end
            return _render(self, x, y, z, square)
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
            local cs = self.currentSquare
            if cs then
                return _create(self, cs:getX(), cs:getY(), cs:getZ(), north, sprite)
            end
            return _create(self, x, y, z, north, sprite)
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
