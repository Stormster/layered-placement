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

    function ISMoveableCursor:isValid(square)
        if not (LayeredPlacement.allowMeshFloorAim() and ISMoveableCursor.mode[self.player] == "place" and square) then
            return _isValid(self, square)
        end

        -- Populate currentMoveProps from the clicked square first, then remap Z.
        local ok = _isValid(self, square)
        local props = self.currentMoveProps or self.origMoveProps
        local target = LayeredPlacement.resolveFloatingSquare(self.character, square, props)
        if target and target ~= square then
            ok = _isValid(self, target)
            -- create() uses currentSquare; keep both in sync with the remapped floor.
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

    LayeredPlacement.log("cursor floating Z hook ready")
end

Events.OnGameBoot.Add(hookCursor)
Events.OnGameStart.Add(hookCursor)
