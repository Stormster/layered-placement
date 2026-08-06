require "LayeredPlacement/LP_Shared"

local SERVER_NOTE = " This is a personal preference. A server can disable this feature for everyone in Sandbox settings."

local OPTIONS = {
    {
        id = "layeredPlace",
        label = "Lights over furniture & stacked decor",
        tooltip = "Stack posters and wall decor on the same wall, and place ceiling lights over furniture. Does not enable railing/mid-air placement (use Place on railings for that). Floor furniture stays normal.",
    },
    {
        id = "floatingPlace",
        label = "Place on railings & catwalks",
        tooltip = "Allow hanging Object-type highs (string lights, canopies, etc.) on railings, posts, and catwalk edges without a solid wall or floor. Independent of stacking.",
    },
    {
        id = "meshFloorAim",
        label = "Aim at your floor through mesh",
        tooltip = "When you're upstairs and Place/Pickup falls through grated floors to the ground, aim at your floor instead. Independent of the place helpers.",
    },
    {
        id = "catwalkReach",
        label = "Easier reach on catwalks",
        tooltip = "Finish Place/Pickup when you're already next to a catwalk/railing tile but normal pathing fails. Railing floating place still works without this; this helps wall hangings and other highs.",
    },
    {
        id = "lightInteract",
        label = "Easier railing light controls (disabled - in development)",
        tooltip = "Turned off in this version and ignored even if you tick it. Clicking near a lamp could toggle a light you were not aiming at, so lights use the normal controls for now. It needs more development and will be back in a later update. Placing lights on railings is unaffected.",
        default = false,
        serverNote = false,
    },
}

--- Read current tickbox values into runtime flags.
--- Do NOT call ModOptions:load() here — Apply already wrote UI values into option.value;
--- load() would restore the previous file and undo the click.
local function applyFromUiValues()
    local opts = PZAPI.ModOptions:getOptions(LayeredPlacement.MOD_ID)
    if not opts then
        return
    end
    for _, def in ipairs(OPTIONS) do
        local opt = opts:getOption(def.id)
        if opt and opt.getValue then
            -- A feature held back in code must not show a ticked box.
            if def.default == false and opt.setValue then
                pcall(function()
                    opt:setValue(false)
                end)
            end
            LayeredPlacement.setOption(def.id, LayeredPlacement.coerceBool(opt:getValue(), true))
        end
    end
    LayeredPlacement.log(
        "options layered=" .. tostring(LayeredPlacement.allowLayeredPlace())
            .. " floating=" .. tostring(LayeredPlacement.allowFloatingPlace())
            .. " mesh=" .. tostring(LayeredPlacement.allowMeshFloorAim())
            .. " reach=" .. tostring(LayeredPlacement.allowCatwalkReach())
            .. " lights=" .. tostring(LayeredPlacement.allowLightInteract())
    )
end

local function loadFromDiskThenApply()
    if PZAPI.ModOptions and PZAPI.ModOptions.load then
        PZAPI.ModOptions:load()
    end
    applyFromUiValues()
end

local function bindOptionCallbacks(opts)
    for _, def in ipairs(OPTIONS) do
        local optionId = def.id -- capture per-iteration (Lua 5.1 / Kahlua)
        local opt = opts:getOption(optionId)
        if opt then
            -- Fires when the box is clicked (before Apply). Instant runtime update.
            opt.onChange = function(self, selected)
                LayeredPlacement.setOption(optionId, LayeredPlacement.coerceBool(selected, true))
                LayeredPlacement.log(optionId .. "=" .. tostring(LayeredPlacement.options[optionId]) .. " (pending save)")
            end
            -- Fires on Apply if the value changed vs the previous saved value.
            opt.onChangeApply = function(self, selected)
                LayeredPlacement.setOption(optionId, LayeredPlacement.coerceBool(selected, true))
                LayeredPlacement.log(optionId .. "=" .. tostring(LayeredPlacement.options[optionId]) .. " (apply)")
            end
        end
    end

    -- Called after all gameOption.apply() have copied UI → option.value.
    opts.apply = function(self)
        applyFromUiValues()
    end
end

--- Without the Mod Options API every feature simply stays at its default (on,
--- unless Sandbox says otherwise) instead of erroring out of this whole file.
if PZAPI and PZAPI.ModOptions then
    local options = PZAPI.ModOptions:getOptions(LayeredPlacement.MOD_ID)
    if not options then
        options = PZAPI.ModOptions:create(LayeredPlacement.MOD_ID, "Layered Placement")
        for _, def in ipairs(OPTIONS) do
            local tooltip = def.tooltip
            if def.serverNote ~= false then
                tooltip = tooltip .. SERVER_NOTE
            end
            options:addTickBox(def.id, def.label, def.default ~= false, tooltip)
        end
    end

    bindOptionCallbacks(options)

    Events.OnMainMenuEnter.Add(loadFromDiskThenApply)
    Events.OnGameStart.Add(loadFromDiskThenApply)
else
    LayeredPlacement.log("Mod Options API unavailable; using Sandbox settings only")
end

--- Small Lights / other ForceSingleItem multis can't Drop until canBeDroppedOnFloor
--- is flipped. Fix anything already sitting in the player inventory.
local dropHooked = false

local function hookDropItem()
    if dropHooked then
        return
    end
    if not ISInventoryPaneContextMenu or not ISInventoryPaneContextMenu.dropItem then
        return
    end
    dropHooked = true
    local _dropItem = ISInventoryPaneContextMenu.dropItem
    ISInventoryPaneContextMenu.dropItem = function(item, player)
        LayeredPlacement.makeMoveableDroppable(item)
        return _dropItem(item, player)
    end
end

local function fixPlayerMoveableDrops()
    hookDropItem()
    local player = getSpecificPlayer and getSpecificPlayer(0)
    if not player then
        return
    end
    LayeredPlacement.fixInventoryMoveableDrops(player:getInventory())
end

Events.OnGameStart.Add(fixPlayerMoveableDrops)
Events.OnCreatePlayer.Add(function(playerIndex, player)
    hookDropItem()
    if player then
        LayeredPlacement.fixInventoryMoveableDrops(player:getInventory())
    end
end)
