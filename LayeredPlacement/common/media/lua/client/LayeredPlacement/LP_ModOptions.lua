require "LayeredPlacement/LP_Shared"

local OPTIONS = {
    {
        id = "layeredPlace",
        label = "Lights over furniture & stacked decor",
        tooltip = "Place ceiling lights over tables/posters, stack multiple high decor items, and keep wall decor together. Floor furniture stays normal.",
    },
    {
        id = "floatingPlace",
        label = "Place on railings & catwalks",
        tooltip = "Allow hanging decor and outdoor/wall lamps on railings, posts, and catwalk edges without a solid wall.",
    },
    {
        id = "meshFloorAim",
        label = "Aim at your floor through mesh",
        tooltip = "When you're upstairs and the Place cursor falls through grated floors to the ground, aim at your floor instead.",
    },
    {
        id = "catwalkReach",
        label = "Easier reach on catwalks",
        tooltip = "Let you finish Place when you're already next to a catwalk/railing tile but normal pathing to it fails.",
    },
    {
        id = "lightInteract",
        label = "Easier railing light controls",
        tooltip = "Make turn on/off and right-click menus work better for lamps on railings (so the rail doesn't eat every click).",
    },
}

local options = PZAPI.ModOptions:create(LayeredPlacement.MOD_ID, "Layered Placement")
local tickBoxes = {}

for _, def in ipairs(OPTIONS) do
    local box = options:addTickBox(def.id, def.label, true, def.tooltip)
    tickBoxes[def.id] = box
    box.onChange = function(self, selected)
        LayeredPlacement.setOption(def.id, selected == true)
        LayeredPlacement.log(def.id .. "=" .. tostring(selected == true) .. " (pending save)")
    end
end

local function applyOptions()
    if PZAPI.ModOptions and PZAPI.ModOptions.load then
        PZAPI.ModOptions:load()
    end
    for _, def in ipairs(OPTIONS) do
        local opt = options:getOption(def.id)
        if opt then
            LayeredPlacement.setOption(def.id, opt:getValue() == true)
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

options.apply = function(self)
    applyOptions()
end

Events.OnMainMenuEnter.Add(applyOptions)
Events.OnGameStart.Add(applyOptions)
