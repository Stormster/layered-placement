LayeredPlacement = LayeredPlacement or {}

LayeredPlacement.MOD_ID = "LayeredPlacement"
LayeredPlacement.VERSION = "1.6.6"

--- Feature flags (defaults on). Dedicated servers keep these defaults;
--- clients override from Mod Options.
LayeredPlacement.options = LayeredPlacement.options or {
    layeredPlace = true,   -- lights over furniture/posters, multiple highs, wall decor together
    floatingPlace = true,  -- railings / catwalks / wall lamps without a solid wall
    meshFloorAim = true,   -- Place/Pickup aim at your floor when the mouse falls through mesh
    catwalkReach = true,   -- place/pickup when you're next to a tile but pathing fails
    lightInteract = true,  -- easier turn on/off and right-click for railing lamps
}

function LayeredPlacement.log(msg)
    if getDebug and getDebug() then
        print("[LayeredPlacement] " .. tostring(msg))
    end
end

local function flag(name)
    local opts = LayeredPlacement.options
    if not opts then
        return true
    end
    return opts[name] ~= false
end

function LayeredPlacement.allowLayeredPlace()
    return flag("layeredPlace")
end

function LayeredPlacement.allowFloatingPlace()
    return flag("floatingPlace")
end

function LayeredPlacement.allowMeshFloorAim()
    return flag("meshFloorAim")
end

function LayeredPlacement.allowCatwalkReach()
    return flag("catwalkReach")
end

function LayeredPlacement.allowLightInteract()
    return flag("lightInteract")
end

--- Any placement helper that changes what Place will accept.
function LayeredPlacement.isPlaceHelpEnabled()
    return LayeredPlacement.allowLayeredPlace() or LayeredPlacement.allowFloatingPlace()
end

--- Back-compat for older checks.
function LayeredPlacement.isEnabled()
    return LayeredPlacement.isPlaceHelpEnabled()
        or LayeredPlacement.allowMeshFloorAim()
        or LayeredPlacement.allowCatwalkReach()
        or LayeredPlacement.allowLightInteract()
end

--- Coerce Mod Options / UI values to a real boolean.
function LayeredPlacement.coerceBool(value, default)
    if value == nil then
        return default ~= false
    end
    if value == true or value == false then
        return value
    end
    if value == "true" or value == "1" then
        return true
    end
    if value == "false" or value == "0" then
        return false
    end
    return value and true or false
end

function LayeredPlacement.setOption(name, value)
    LayeredPlacement.options = LayeredPlacement.options or {}
    LayeredPlacement.options[name] = LayeredPlacement.coerceBool(value, true)
end

function LayeredPlacement.setEnabled(value)
    -- Legacy single switch: turn the main place helpers on/off together.
    local on = value and true or false
    LayeredPlacement.setOption("layeredPlace", on)
    LayeredPlacement.setOption("floatingPlace", on)
end

--- Max same-floor distance for the floating-decor helpers. Without a cap the
--- pathing skip would let you place/pick decor anywhere on your Z level.
LayeredPlacement.REACH_DIST = 3
LayeredPlacement.CHEAT_REACH = 4
--- Looking down from a catwalk onto a ground-floor wall is Z-diff 1.
LayeredPlacement.BRUSH_MAX_Z = 1

function LayeredPlacement.chebyshev(squareA, squareB)
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

function LayeredPlacement.withinReach(character, square, dist, maxZ)
    local charSq = character and (character:getSquare() or character:getCurrentSquare())
    if not charSq or not square then
        return false
    end
    local dz = math.abs(charSq:getZ() - square:getZ())
    if maxZ == nil then
        if dz ~= 0 then
            return false
        end
    elseif dz > maxZ then
        return false
    end
    return LayeredPlacement.chebyshev(charSq, square) <= (dist or LayeredPlacement.REACH_DIST)
end

--- Brush-style reach for floating highs: same floor or one level away (catwalk → ground wall).
function LayeredPlacement.withinBrushReach(character, square)
    return LayeredPlacement.withinReach(
        character, square, LayeredPlacement.CHEAT_REACH, LayeredPlacement.BRUSH_MAX_Z
    )
end

--- Hanging decor: lamps, chandeliers, canopies, string lights, bunting.
--- Deliberately narrow. MoveType defaults to "Object" for every moveable without
--- one, so keying on IsLow too would sweep in ~1900 ordinary furniture tiles
--- (ovens, washers, tables, fridges) and let them be placed in mid-air.
function LayeredPlacement.isHangingDecor(props)
    if not props or not props.isMoveable or not props.isHigh then
        return false
    end
    if props.type ~= "Object" then
        return false
    end
    if props.isTable or props.isTableTop or props.isStackable or props.isWaterCollector then
        return false
    end
    if props.isoType and props.isoType ~= "IsoObject" and props.isoType ~= "IsoLightSwitch" then
        return false
    end
    if props.spriteProps and props.spriteProps:has("container") then
        return false
    end
    return true
end

function LayeredPlacement.isWallDecor(props)
    if not props or not props.isMoveable then
        return false
    end
    local t = props.type
    return t == "WallObject" or t == "WallOverlay" or t == "WindowObject"
end

--- Everything whose placement rules this mod is allowed to relax.
--- Wall-attached types still go through the vanilla attach path; only the
--- "tile is already occupied" and "needs a floor" rules are touched.
function LayeredPlacement.isPlacementDecor(props)
    return LayeredPlacement.isHangingDecor(props) or LayeredPlacement.isWallDecor(props)
end

--- Wider set for the pathing/adjacency helpers only. These never change what
--- may be placed, just whether you have to walk onto an awkward catwalk tile.
function LayeredPlacement.isReachDecor(props)
    if not props or not props.isMoveable then
        return false
    end
    if props.isHigh or props.isLow then
        return true
    end
    return LayeredPlacement.isWallDecor(props)
end

--- Hanging decor placed on railings/catwalk edges, when that helper is enabled.
function LayeredPlacement.isFloatingDecor(props)
    return LayeredPlacement.allowFloatingPlace() and LayeredPlacement.isHangingDecor(props)
end

function LayeredPlacement.hasPlaceRequirements(props, character)
    if not character or not instanceof(character, "IsoPlayer") then
        return true
    end
    if ISMoveableDefinitions.cheat or character:isMovablesCheat() then
        return true
    end
    local hasSkill = props:hasRequiredSkill(character, "place")
    local hasTool = (not props.placeTool) and true or props:hasTool(character, "place")
    return hasSkill and hasTool
end

--- Score a square for pickup aiming (prefer high/low decor already on the tile).
local function pickupAimScore(square)
    if not square or not square.getObjects then
        return -1
    end
    local objects = square:getObjects()
    if not objects then
        return 0
    end
    local score = 0
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local spr = obj and obj:getSprite()
        local props = spr and spr:getProperties()
        if props and props:has("IsMoveAble") then
            score = score + 1
            if props:has("IsHigh") or props:has("IsLow") then
                score = score + 4
            end
        end
        -- Wall-overlay moveables live as child sprites on walls/railings.
        if obj and obj.getChildSprites then
            local kids = obj:getChildSprites()
            if kids then
                for j = 0, kids:size() - 1 do
                    local child = kids:get(j)
                    local cspr = child and child:getParentSprite()
                    local cprops = cspr and cspr:getProperties()
                    if cprops and cprops:has("IsMoveAble") then
                        score = score + 1
                        if cprops:has("IsHigh") or cprops:has("IsLow") then
                            score = score + 4
                        end
                    end
                end
            end
        end
    end
    return score
end

--- Create or fetch a grid square. force=true skips the isValidSquare gate so
--- catwalk/railing edge tiles (often "invalid" but still placeable) can exist.
function LayeredPlacement.ensureGridSquare(x, y, z, force)
    local cell = getCell()
    if not cell or x == nil or y == nil or z == nil then
        return nil
    end
    local sq = cell:getGridSquare(x, y, z)
    if sq then
        return sq
    end
    if cell.getOrCreateGridSquare then
        local ok, created = pcall(function()
            return cell:getOrCreateGridSquare(x, y, z)
        end)
        if ok and created then
            return created
        end
    end
    local world = getWorld and getWorld() or nil
    if not force and world and world.isValidSquare and not world:isValidSquare(x, y, z) then
        return nil
    end
    local ok, created = pcall(function()
        return cell:createNewGridSquare(x, y, z, true)
    end)
    if ok and created then
        return created
    end
    return nil
end

--- Lift a below-player square up to the player's Z (mesh fallthrough).
--- Returns nil when we cannot get an upstairs tile — callers should treat that
--- as "not here" rather than placing on the ground under the catwalk.
function LayeredPlacement.liftToPlayerZ(character, square, playerNum)
    if not character or not square then
        return square
    end
    local charSq = character:getSquare() or character:getCurrentSquare()
    if not charSq then
        return square
    end
    local pz = charSq:getZ()
    if square:getZ() >= pz then
        return square
    end
    local cell = getCell()
    if not cell then
        return nil
    end
    local x, y = square:getX(), square:getY()
    if screenToIsoX and screenToIsoY and getMouseX and getMouseY then
        local pn = playerNum
        if pn == nil and character.getPlayerNum then
            pn = character:getPlayerNum()
        end
        if pn ~= nil then
            local wx = screenToIsoX(pn, getMouseX(), getMouseY(), pz)
            local wy = screenToIsoY(pn, getMouseX(), getMouseY(), pz)
            if wx and wy then
                x = math.floor(wx)
                y = math.floor(wy)
            end
        end
    end
    -- Force-create: railing edges are often isValidSquare=false.
    local lifted = LayeredPlacement.ensureGridSquare(x, y, pz, true)
    if lifted then
        return lifted
    end
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    lifted = LayeredPlacement.ensureGridSquare(x + dx, y + dy, pz, true)
                    if lifted then
                        return lifted
                    end
                end
            end
        end
    end
    return nil
end

--- Walk to a same-Z floor tile next to a floating railing/catwalk square.
--- keepActions=true so an existing path/queue from tryBuild isn't wiped.
function LayeredPlacement.walkToNearbyFloor(character, square, keepActions)
    if not character or not square or not luautils or not luautils.walkAdj then
        return false
    end
    local cell = getCell()
    if not cell then
        return false
    end
    local z = square:getZ()
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if not (dx == 0 and dy == 0) then
                    local sq = cell:getGridSquare(square:getX() + dx, square:getY() + dy, z)
                    if sq and sq:getFloor() and luautils.walkAdj(character, sq, keepActions ~= false) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function getOrCreateSquare(cell, x, y, z, force)
    return LayeredPlacement.ensureGridSquare(x, y, z, force)
end

--- When the mouse hits a tall pillar/ground, the reprojected XY may be empty.
--- Pickup: keep the exact tile if it has decor; only then search neighbors.
--- Place: force-create upstairs tiles (railing edges are often "invalid").
local function findBestSquareAtPlayerZ(cell, x, y, pz, mode)
    local force = mode == "place"
    local exact = getOrCreateSquare(cell, x, y, pz, force)

    if mode == "pickup" then
        if pickupAimScore(exact) > 0 then
            return exact
        end
        local best, bestScore, bestDist = nil, 0, 999
        local radius = 2
        for dx = -radius, radius do
            for dy = -radius, radius do
                if not (dx == 0 and dy == 0) then
                    local dist = math.max(math.abs(dx), math.abs(dy))
                    local sq = cell:getGridSquare(x + dx, y + dy, pz)
                    local score = pickupAimScore(sq)
                    if score > bestScore or (score == bestScore and score > 0 and dist < bestDist) then
                        best, bestScore, bestDist = sq, score, dist
                    end
                end
            end
        end
        if bestScore > 0 then
            return best
        end
        if exact then
            return exact
        end
        for r = 1, radius do
            for dx = -r, r do
                for dy = -r, r do
                    if math.abs(dx) == r or math.abs(dy) == r then
                        local sq = cell:getGridSquare(x + dx, y + dy, pz)
                        if sq then
                            return sq
                        end
                    end
                end
            end
        end
        return nil
    end

    -- place: never silently keep the ground tile under mesh
    if exact then
        return exact
    end
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = getOrCreateSquare(cell, x + dx, y + dy, pz, true)
                    if sq then
                        return sq
                    end
                end
            end
        end
    end
    return nil
end

--- If the mouse fell through mesh to a lower Z while you're upstairs, aim at
--- your floor instead. Re-project the mouse onto the player Z plane — lifting
--- the ground tile's XY is wrong under isometric angles (common on catwalks).
--- Near tall pillars the exact XY often has no upper square; snap to a nearby
--- player-Z tile (decor for pickup, force-create for place).
---
--- Place: only remap Object-type floating highs (lights). Wall hangings
--- (posters/paintings) must keep the aimed wall square — lifting them to an
--- empty upstairs tile greens the cursor then eats the item with nothing shown.
--- Pickup: still remap any high/low so mesh fallthrough finds upstairs decor.
--- mode: optional "pickup" / "place" (nil defaults to place-style scoring)
function LayeredPlacement.resolveFloatingSquare(character, square, props, playerNum, mode)
    if not LayeredPlacement.allowMeshFloorAim() then
        return square
    end
    if not square then
        return square
    end
    local aimMode = mode or "place"
    if props then
        if aimMode == "pickup" then
            if not (props.isHigh or props.isLow) then
                return square
            end
        elseif not LayeredPlacement.isFloatingDecor(props) then
            return square
        end
    end
    if not character then
        return square
    end
    local charSq = character:getSquare() or character:getCurrentSquare()
    if not charSq then
        return square
    end
    local pz = charSq:getZ()
    if square:getZ() >= pz then
        return square
    end
    local cell = getCell()
    if not cell then
        return square
    end

    local x, y = square:getX(), square:getY()
    if screenToIsoX and screenToIsoY and getMouseX and getMouseY then
        local pn = playerNum
        if pn == nil and character.getPlayerNum then
            pn = character:getPlayerNum()
        end
        if pn ~= nil then
            local wx = screenToIsoX(pn, getMouseX(), getMouseY(), pz)
            local wy = screenToIsoY(pn, getMouseX(), getMouseY(), pz)
            if wx and wy then
                x = math.floor(wx)
                y = math.floor(wy)
            end
        end
    end

    local atPlayer = findBestSquareAtPlayerZ(cell, x, y, pz, aimMode)
    if atPlayer then
        LayeredPlacement.log(
            "float Z " .. tostring(square:getZ())
                .. " -> " .. tostring(pz)
                .. " @" .. tostring(atPlayer:getX()) .. "," .. tostring(atPlayer:getY())
                .. " (" .. tostring(aimMode) .. ")"
        )
        return atPlayer
    end
    -- Could not create an upstairs tile — keep the aimed square (may be an
    -- intentional ground-floor wall place from a catwalk).
    return square
end
