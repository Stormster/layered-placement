LayeredPlacement = LayeredPlacement or {}

LayeredPlacement.MOD_ID = "LayeredPlacement"
LayeredPlacement.VERSION = "1.4.9"

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

--- Score a square for place aiming (prefer real floors / catwalk tiles over pillar air).
local function placeAimScore(square)
    if not square then
        return -1
    end
    local score = 1
    if square:getFloor() then
        score = score + 4
    end
    if IsoFlagType and square:has(IsoFlagType.solidfloor) then
        score = score + 2
    end
    return score
end

local function getOrCreateSquare(cell, x, y, z)
    local sq = cell:getGridSquare(x, y, z)
    if sq then
        return sq
    end
    if getWorld and getWorld():isValidSquare(x, y, z) then
        local ok, created = pcall(function()
            return cell:createNewGridSquare(x, y, z, true)
        end)
        if ok then
            return created
        end
    end
    return nil
end

--- When the mouse hits a tall pillar/ground, the reprojected XY may be empty or
--- a bad column tile. Search nearby player-Z squares for a better aim target.
local function findBestSquareAtPlayerZ(cell, x, y, pz, mode)
    local best, bestScore, bestDist = nil, -1, 999
    local radius = (mode == "pickup") and 2 or 2
    for dx = -radius, radius do
        for dy = -radius, radius do
            local dist = math.max(math.abs(dx), math.abs(dy))
            local sq
            if dist == 0 then
                sq = getOrCreateSquare(cell, x, y, pz)
            else
                sq = cell:getGridSquare(x + dx, y + dy, pz)
            end
            if sq then
                local score
                if mode == "pickup" then
                    score = pickupAimScore(sq)
                else
                    score = placeAimScore(sq)
                end
                if score > bestScore or (score == bestScore and dist < bestDist) then
                    best, bestScore, bestDist = sq, score, dist
                end
            end
        end
    end
    -- Pickup with nothing nearby: still snap to exact/nearest existing upstairs tile
    -- so we don't leave the cursor on the ground under a pillar.
    if mode == "pickup" and bestScore <= 0 then
        local exact = getOrCreateSquare(cell, x, y, pz)
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
    end
    return best
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
