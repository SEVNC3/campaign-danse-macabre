---@diagnostic disable: undefined-global
-- Danse Macabre - BootstrapServer.lua
-- Death's Door System - A dramatic death system overhaul

_P("[DanseMacabre] Loading Danse Macabre...")

-- Load and initialize the Death's Door module
local DeathsDoor = Ext.Require("Server/DeathsDoor.lua")

-- Export to mod table for external access
Mods.DanseMacabre = Mods.DanseMacabre or {}
Mods.DanseMacabre.DeathsDoor = DeathsDoor

-- List of ALL resurrection spells to block during combat
local RESURRECTION_SPELLS = {
    "Teleportation_Resurrection",           -- Base spell
    "Teleportation_Revivify",               -- Main spell
    "Teleportation_Revivify_4",             -- Upcast level 4
    "Teleportation_Revivify_5",             -- Upcast level 5
    "Teleportation_Revivify_6",             -- Upcast level 6
    "Teleportation_Revivify_Scroll",        -- Scroll version
    "Teleportation_TrueResurrection_Scroll", -- True Resurrection scroll
    "Teleportation_HAG_HusbandResurrection", -- Gustav variant
    "Teleportation_MAG_Revivify",           -- Gustav variant
    "Teleportation_Revivify_Deva",          -- Gustav variant
}

--- Add !Combat requirement to a spell's Requirements table
--- @param spellName string The spell to modify
--- @return boolean success Whether modification succeeded
local function AddNoCombatRequirement(spellName)
    local success, spell = pcall(function() return Ext.Stats.Get(spellName) end)
    if not success or not spell then
        return false
    end

    -- Get existing requirements or empty table
    local requirements = spell.Requirements or {}

    -- Check if already has !Combat requirement
    for _, req in ipairs(requirements) do
        if req.Requirement == "Combat" and req.Not == true then
            return true  -- Already has the requirement
        end
    end

    -- Add !Combat requirement
    -- Format from SE StatTests.lua lines 76-82
    table.insert(requirements, {
        Requirement = "Combat",  -- CORRECT field name (not "Name")
        Param = -1,              -- -1 for boolean requirements
        Not = true               -- NOT Combat = only cast outside combat
    })

    -- CRITICAL: Reassign table (table properties require full reassignment)
    spell.Requirements = requirements

    -- Sync changes to clients
    spell:Sync()

    return true
end

--- Block all resurrection spells during combat
local function ModifyResurrectionSpells()
    local modifiedCount = 0
    local failedSpells = {}

    for _, spellName in ipairs(RESURRECTION_SPELLS) do
        if AddNoCombatRequirement(spellName) then
            modifiedCount = modifiedCount + 1
        else
            table.insert(failedSpells, spellName)
        end
    end

    if modifiedCount > 0 then
        _P("[DanseMacabre] Blocked " .. modifiedCount .. " resurrection spell(s) during combat")
    end

    if #failedSpells > 0 then
        _P("[DanseMacabre] Warning: Could not modify: " .. table.concat(failedSpells, ", "))
    end

    return modifiedCount > 0
end

-- Try immediately (stats already loaded by bootstrap time)
local modified = ModifyResurrectionSpells()

-- Fallback: subscribe to StatsLoaded in case stats load later
if not modified then
    Ext.Events.StatsLoaded:Subscribe(function()
        ModifyResurrectionSpells()
    end)
end

-- Initialize when session loads
Ext.Events.SessionLoaded:Subscribe(function()
    _P("[DanseMacabre] Session loaded, initializing Death's Door...")
    DeathsDoor.Init()
    _P("[DanseMacabre] Danse Macabre fully initialized")
end)

_P("[DanseMacabre] BootstrapServer.lua loaded")
