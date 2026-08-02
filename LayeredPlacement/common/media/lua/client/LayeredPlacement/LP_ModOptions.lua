require "LayeredPlacement/LP_Shared"

local OPTIONS = {
    {
        id = "layeredPlace",
        label = "Lights over furniture & stacked decor",
        tooltip = "Stack posters and wall decor (high + low on the same wall), place ceiling lights over furniture, and keep multiple wall hangings together. Floor furniture stays normal.",
    },
    {
        id = "floatingPlace",
        label = "Place on railings & catwalks",
        tooltip = "Allow hanging decor and outdoor/wall lamps on railings, posts, and catwalk edges without a solid wall.",
    },
    {
        id = "meshFloorAim",
        label = "Aim at your floor through mesh",
        tooltip = "When you're upstairs and Place/Pickup falls through grated floors to the ground, aim at your floor instead.",
    },
    {
        id = "catwalkReach",
        label = "Easier reach on catwalks",
        tooltip = "Let you finish Place and Pickup when you're already next to a catwalk/railing tile but normal pathing to it fails.",
    },
    {
        id = "lightInteract",
        label = "Easier railing light controls",
        tooltip = "Make turn on/off and right-click menus work better for lamps on railings (so the rail doesn't eat every click).",
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

local options = PZAPI.ModOptions:getOptions(LayeredPlacement.MOD_ID)
if not options then
    options = PZAPI.ModOptions:create(LayeredPlacement.MOD_ID, "Layered Placement")
    for _, def in ipairs(OPTIONS) do
        options:addTickBox(def.id, def.label, true, def.tooltip)
    end
end

bindOptionCallbacks(options)

Events.OnMainMenuEnter.Add(loadFromDiskThenApply)
Events.OnGameStart.Add(loadFromDiskThenApply)
