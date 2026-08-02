LayeredPlacement = LayeredPlacement or {}

LayeredPlacement.MOD_ID = "LayeredPlacement"
LayeredPlacement.VERSION = "1.5.4"

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

function LayeredPlacement.ensureGridSquare(x, y, z)
    local cell = getCell()
    if not cell or x == nil or y == nil or z == nil then
        return nil
    end
    local sq = cell:getGridSquare(x, y, z)
    if sq then
        return sq
    end
    -- Prefer getOrCreate when available (admin/build paths use this).
    if cell.getOrCreateGridSquare then
        local ok, created = pcall(function()
            return cell:getOrCreateGridSquare(x, y, z)
        end)
        if ok and created then
            return created
        end
    end
    local world = getWorld and getWorld() or nil
    if world and world.isValidSquare and world:isValidSquare(x, y, z) then
        local ok, created = pcall(function()
            return cell:createNewGridSquare(x, y, z, true)
        end)
        if ok and created then
            return created
        end
    end
    -- Last resort: some catwalk edge coords still place if we force-create.
    local ok, created = pcall(function()
        return cell:createNewGridSquare(x, y, z, true)
    end)
    if ok and created then
        return created
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

local function getOrCreateSquare(cell, x, y, z)
    return LayeredPlacement.ensureGridSquare(x, y, z)
end

--- When the mouse hits a tall pillar/ground, the reprojected XY may be empty.
--- Pickup: keep the exact tile if it has decor; only then search neighbors.
--- Place: stick to the exact aim tile (neighbor floor-snapping stole railing edges).
local function findBestSquareAtPlayerZ(cell, x, y, pz, mode)
    local exact = getOrCreateSquare(cell, x, y, pz)

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
        -- Nothing to pick nearby — still leave the ground; snap upstairs if possible.
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

    -- place
    if exact then
        return exact
    end
    for r = 1, 2 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = getOrCreateSquare(cell, x + dx, y + dy, pz)
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
--- player-Z tile (decor for pickup, floors for place).
--- mode: optional "pickup" / "place" (nil defaults to place-style scoring)
function LayeredPlacement.resolveFloatingSquare(character, square, props, playerNum, mode)
    if not LayeredPlacement.allowMeshFloorAim() then
        return square
    end
    if not square then
        return square
    end
    -- High/low decor is the usual mesh case; also remap when props aren't ready yet
    -- so the cursor can still snap before inventory props populate.
    if props and not (props.isHigh or props.isLow) then
        return square
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
    -- Re-hit the mouse against the player's floor (fixes angled look-through).
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

    local aimMode = mode or "place"
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
    return square
end
