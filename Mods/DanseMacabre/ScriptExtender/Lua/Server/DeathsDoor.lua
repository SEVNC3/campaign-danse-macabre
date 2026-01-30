---@diagnostic disable: undefined-global
-- Danse Macabre - Death's Door Module
-- Handles the death saving throw system with escalating DC

local DeathsDoor = {}

-- DC progression configuration
local DC_PROGRESSION = {8, 10, 12, 14, 16, 18, 20}
local DC_STATUSES = {
    [8] = "DEATHS_DOOR_DC_8",
    [10] = "DEATHS_DOOR_DC_10",
    [12] = "DEATHS_DOOR_DC_12",
    [14] = "DEATHS_DOOR_DC_14",
    [16] = "DEATHS_DOOR_DC_16",
    [18] = "DEATHS_DOOR_DC_18",
    [20] = "DEATHS_DOOR_DC_20"
}

-- Save trigger statuses for each DC (shows dice roll animation)
local SAVE_STATUSES = {
    [8] = "DEATHS_DOOR_SAVE_DC_8",
    [10] = "DEATHS_DOOR_SAVE_DC_10",
    [12] = "DEATHS_DOOR_SAVE_DC_12",
    [14] = "DEATHS_DOOR_SAVE_DC_14",
    [16] = "DEATHS_DOOR_SAVE_DC_16",
    [18] = "DEATHS_DOOR_SAVE_DC_18",
    [20] = "DEATHS_DOOR_SAVE_DC_20"
}

-- Death knell sounds (different for success vs failure)
local SOUND_SAVE_PASSED = "CrSpell_Impact_Raven_BadOmen"  -- Resisted Death
local SOUND_SAVE_FAILED = "CrSpell_Impact_DeathShriek"    -- Succumbed to Death

-- Feedback status names
local FEEDBACK_STATUS = "DEATHSDOOR_FEEDBACK"
local FEEDBACK_TENSION_STATUS = "DEATHSDOOR_FEEDBACK_TENSION"

-- Turn trigger passive
local TURN_SAVE_PASSIVE = "Passive_DeathsDoor_TurnSave"

-- Track entities that have Death's Door this combat
local entitiesInDeathsDoor = {}

-- Track entities currently processing saves (prevent double-triggers)
local processingEntities = {}

-- Track entities being killed (prevent double-death triggers)
local killingEntities = {}

-- Track whose turn it is (to filter DoT damage from direct attacks)
local currentTurnEntity = nil

-- Track currently controlled character for audio feedback
local currentControlled = nil

--- Extract UUID from entity identifier
--- @param entity string Entity identifier (may be full name or just UUID)
--- @return string uuid Just the UUID portion
local function ExtractUUID(entity)
    if not entity then return "" end
    local uuid = string.match(tostring(entity), "[a-f0-9%-]+$")
    return uuid or tostring(entity)
end

--- Get display name for entity
--- @param entity string Entity GUID
--- @return string name Display name or "Unknown"
local function GetDisplayName(entity)
    local success, name = pcall(function()
        return Osi.GetDisplayName(entity)
    end)
    if success and name and name ~= "" then
        return name
    end
    return "Unknown"
end

--- Apply audio feedback statuses (layered heartbeat + tension)
--- @param entity string Entity GUID
local function ApplyFeedbackStatuses(entity)
    pcall(function()
        Osi.ApplyStatus(entity, FEEDBACK_STATUS, -1, 1)
        Osi.ApplyStatus(entity, FEEDBACK_TENSION_STATUS, -1, 1)
    end)
end

--- Remove audio feedback statuses
--- @param entity string Entity GUID
local function RemoveFeedbackStatuses(entity)
    pcall(function()
        if Osi.HasActiveStatus(entity, FEEDBACK_STATUS) == 1 then
            Osi.RemoveStatus(entity, FEEDBACK_STATUS)
        end
        if Osi.HasActiveStatus(entity, FEEDBACK_TENSION_STATUS) == 1 then
            Osi.RemoveStatus(entity, FEEDBACK_TENSION_STATUS)
        end
    end)
end

--- Check if entity has Death's Door status
--- @param entity string Entity GUID
--- @return boolean hasStatus
local function HasDeathsDoorStatus(entity)
    return Osi.HasActiveStatus(entity, "DEATHS_DOOR") == 1
end

--- Check if Death's Door should apply to all combatants (MCM setting)
--- @return boolean Whether all combatants mode is enabled
local function IsAllCombatantsEnabled()
    if Mods.Grimoire and Ext.Mod.IsModLoaded("755a8a72-407f-4f0d-9a33-274ac0f0b53d") and MCM then
        local value = MCM.Get("deaths_door_all_combatants", Mods.Grimoire.ModUUID)
        return value == true
    end
    return false -- Default: party only
end

--- Disable Death's Door for an entity
--- @param entity string Entity GUID
function DeathsDoor.DisableForEntity(entity)
    -- Skip non-characters for consistency
    if Osi.IsCharacter(entity) ~= 1 then
        return
    end

    if Osi.HasActiveStatus(entity, "DEATHS_DOOR_ENABLER") == 1 then
        Osi.RemoveStatus(entity, "DEATHS_DOOR_ENABLER")
        _P("[DanseMacabre] Disabled Death's Door for: " .. tostring(entity))
    end
    -- If entity is currently in Death's Door state, kill them immediately
    if Osi.HasActiveStatus(entity, "DEATHS_DOOR") == 1 then
        _P("[DanseMacabre] Entity in Death's Door state - killing: " .. tostring(entity))
        Osi.RemoveStatus(entity, "DEATHS_DOOR")
        -- Remove any DC tracking statuses
        for dc = 8, 20, 2 do
            local dcStatus = DC_STATUSES[dc]
            if dcStatus then
                Osi.RemoveStatus(entity, dcStatus)
            end
        end
        -- Kill the entity (they're at 0 HP)
        Osi.Die(entity, 0, entity, 0, 0, 0)
    end
end

--- Apply MCM setting changes to all entities in active combats
--- @param allCombatantsEnabled boolean Whether all combatants mode is enabled
local function ApplySettingToActiveCombats(allCombatantsEnabled)
    -- Get all entities currently in combat
    local combatants = Osi.DB_Is_InCombat:Get(nil, nil)
    if not combatants then return end

    for _, row in pairs(combatants) do
        local entity = row[1]
        if entity and Osi.IsDead(entity) == 0 then
            local isPartyMember = Osi.IsPartyMember(entity, 1) == 1

            if allCombatantsEnabled then
                -- Enable for everyone
                DeathsDoor.EnableForEntity(entity)
            else
                -- Party only - remove from non-party members
                if not isPartyMember then
                    DeathsDoor.DisableForEntity(entity)
                end
            end
        end
    end
end

--- Subscribe to MCM setting changes for dynamic application
local function SetupMCMListener()
    if not Ext.Mod.IsModLoaded("755a8a72-407f-4f0d-9a33-274ac0f0b53d") then
        _P("[DanseMacabre] MCM not loaded, skipping listener setup")
        return
    end

    -- Check if BG3MCM events are available
    if not Ext.ModEvents['BG3MCM'] or not Ext.ModEvents['BG3MCM']['MCM_Setting_Saved'] then
        _P("[DanseMacabre] MCM events not available yet, skipping listener setup")
        return
    end

    -- Listen for setting changes (correct MCM API)
    Ext.ModEvents['BG3MCM']['MCM_Setting_Saved']:Subscribe(function(payload)
        if not payload or payload.settingId ~= "deaths_door_all_combatants" then return end

        _P("[DanseMacabre] MCM setting changed: deaths_door_all_combatants = " .. tostring(payload.value))

        -- Apply changes to all active combats
        ApplySettingToActiveCombats(payload.value == true)
    end)

    _P("[DanseMacabre] MCM change listener registered")
end

--- Get current DC for entity based on which DC status is active
--- @param entity string Entity GUID
--- @return number dc Current DC value
function DeathsDoor.GetCurrentDC(entity)
    for i = #DC_PROGRESSION, 1, -1 do
        local dc = DC_PROGRESSION[i]
        if Osi.HasActiveStatus(entity, DC_STATUSES[dc]) == 1 then
            return dc
        end
    end
    return 8 -- Default starting DC
end

--- Increment DC to next level
--- @param entity string Entity GUID
--- @return number nextDC The new DC value
function DeathsDoor.IncrementDC(entity)
    local currentDC = DeathsDoor.GetCurrentDC(entity)
    local nextDC = math.min(currentDC + 2, 20)

    -- Remove old DC status
    if DC_STATUSES[currentDC] then
        Osi.RemoveStatus(entity, DC_STATUSES[currentDC])
    end

    -- Apply new DC status
    if DC_STATUSES[nextDC] then
        Osi.ApplyStatus(entity, DC_STATUSES[nextDC], -1, 1)
    end

    _P("[DanseMacabre] DC incremented: " .. currentDC .. " -> " .. nextDC)
    return nextDC
end

--- Play the death knell sound based on save result
--- @param entity string Entity GUID
--- @param passed boolean Whether the save passed
function DeathsDoor.PlayDeathKnell(entity, passed)
    pcall(function()
        if passed then
            Osi.PlaySound(entity, SOUND_SAVE_PASSED)
        else
            Osi.PlaySound(entity, SOUND_SAVE_FAILED)
        end
    end)
end

--- Show floating text for death save result
--- @param entity string Entity GUID
--- @param passed boolean Whether the save passed
function DeathsDoor.ShowFloatingText(entity, passed)
    if Mods.Grimoire and Mods.Grimoire.FloatingText then
        local text
        if passed then
            text = "Resisted Death!"
        else
            text = "Succumbed to Death!"
        end
        Mods.Grimoire.FloatingText.ShowCustom(entity, text)
    end
end

--- Trigger a death save using status (shows dice roll UI)
--- @param entity string Entity GUID
--- @param reason string Reason for the save (for logging)
function DeathsDoor.TriggerSave(entity, reason)
    local entityUUID = ExtractUUID(entity)

    -- DEBUG: Log state at trigger time
    local hp = Osi.GetHitpoints(entity) or "?"
    _P("[DanseMacabre] DEBUG TriggerSave called:")
    _P("[DanseMacabre]     Reason: " .. reason)
    _P("[DanseMacabre]     HP: " .. tostring(hp))
    _P("[DanseMacabre]     Has DEATHS_DOOR: " .. tostring(Osi.HasActiveStatus(entity, "DEATHS_DOOR")))
    _P("[DanseMacabre]     Has DEATHS_DOOR_CHECK: " .. tostring(Osi.HasActiveStatus(entity, "DEATHS_DOOR_CHECK")))
    _P("[DanseMacabre]     Has DEATHS_DOOR_ENABLER: " .. tostring(Osi.HasActiveStatus(entity, "DEATHS_DOOR_ENABLER")))

    -- Prevent double-triggers within short window
    if processingEntities[entityUUID] then
        _P("[DanseMacabre] Skipping duplicate save for " .. entityUUID)
        return
    end
    processingEntities[entityUUID] = true

    -- Clear processing flag after delay
    Ext.Timer.WaitFor(1000, function()
        processingEntities[entityUUID] = nil
    end)

    local dc = DeathsDoor.GetCurrentDC(entity)
    local saveStatus = SAVE_STATUSES[dc]

    if not saveStatus then
        _P("[DanseMacabre] ERROR: No save status for DC " .. dc)
        return
    end

    _P("[DanseMacabre] " .. reason .. " - Triggering save (DC " .. dc .. ") for " .. entityUUID)

    -- Apply the save trigger status - this shows the dice roll
    Osi.ApplyStatus(entity, saveStatus, 0, 1)
end

--- Handle save passed (called when DEATHS_DOOR_SAVE_PASSED is applied)
--- @param entity string Entity GUID
function DeathsDoor.OnSavePassed(entity)
    _P("[DanseMacabre] Entity RESISTED DEATH!")

    -- Play death knell sound (Resisted Death)
    DeathsDoor.PlayDeathKnell(entity, true)

    -- Show floating text using Grimoire
    DeathsDoor.ShowFloatingText(entity, true)

    -- Increment DC for next time
    local newDC = DeathsDoor.IncrementDC(entity)
    _P("[DanseMacabre] DC now " .. newDC)

    -- Cleanup marker status after short delay
    local capturedEntity = entity
    Ext.Timer.WaitFor(500, function()
        Osi.RemoveStatus(capturedEntity, "DEATHS_DOOR_SAVE_PASSED")
    end)
end

--- Handle save failed (called when DEATHS_DOOR_SAVE_FAILED is applied)
--- @param entity string Entity GUID
function DeathsDoor.OnSaveFailed(entity)
    local hp = Osi.GetHitpoints(entity) or "?"

    _P("[DanseMacabre] Entity SUCCUMBED TO DEATH!")
    _P("[DanseMacabre] DEBUG OnSaveFailed:")
    _P("[DanseMacabre]     HP at fail time: " .. tostring(hp))
    _P("[DanseMacabre]     Has DEATHS_DOOR_ENABLER: " .. tostring(Osi.HasActiveStatus(entity, "DEATHS_DOOR_ENABLER")))

    -- Play death knell sound (Succumbed to Death)
    DeathsDoor.PlayDeathKnell(entity, false)

    -- Show floating text using Grimoire
    DeathsDoor.ShowFloatingText(entity, false)

    -- Delay death briefly - just enough for "Succumbed to Death!" text to display
    local capturedEntity = entity
    Ext.Timer.WaitFor(600, function()
        -- Check if entity recovered before killing (healed during the 600ms window)
        if Osi.HasActiveStatus(capturedEntity, "DEATHS_DOOR") ~= 1 then
            _P("[DanseMacabre] Entity recovered from Death's Door - cancelling death")
            Osi.RemoveStatus(capturedEntity, "DEATHS_DOOR_SAVE_FAILED")
            return  -- Don't kill - they recovered
        end

        local hpAtKill = Osi.GetHitpoints(capturedEntity) or "?"
        _P("[DanseMacabre] DEBUG 600ms timer fired, about to Kill:")
        _P("[DanseMacabre]     HP now: " .. tostring(hpAtKill))
        _P("[DanseMacabre]     Has DEATHS_DOOR: " .. tostring(Osi.HasActiveStatus(capturedEntity, "DEATHS_DOOR")))
        _P("[DanseMacabre]     Has DEATHS_DOOR_ENABLER: " .. tostring(Osi.HasActiveStatus(capturedEntity, "DEATHS_DOOR_ENABLER")))

        -- Clean up the marker status
        Osi.RemoveStatus(capturedEntity, "DEATHS_DOOR_SAVE_FAILED")
        DeathsDoor.Kill(capturedEntity)
    end)
end

--- Kill entity properly using Osi.Die
--- @param entity string Entity GUID
function DeathsDoor.Kill(entity)
    local entityUUID = ExtractUUID(entity)

    -- Prevent double-kill
    if killingEntities[entityUUID] then
        return
    end
    killingEntities[entityUUID] = true

    _P("[DanseMacabre] Killing entity: " .. entityUUID)

    -- Remove Death's Door status first
    Osi.RemoveStatus(entity, "DEATHS_DOOR")

    -- Remove the DOWNED check status
    Osi.RemoveStatus(entity, "DEATHS_DOOR_CHECK")

    -- Remove the turn save passive
    pcall(function()
        Osi.RemovePassive(entity, TURN_SAVE_PASSIVE)
    end)

    -- Remove all DC tracking statuses
    for _, status in pairs(DC_STATUSES) do
        Osi.RemoveStatus(entity, status)
    end

    -- Remove DEATHS_DOOR_ENABLER to prevent re-triggering on death
    Osi.RemoveStatus(entity, "DEATHS_DOOR_ENABLER")

    -- Remove from tracking
    entitiesInDeathsDoor[entityUUID] = nil

    -- Use Osi.Die to properly kill the entity
    -- Parameters: target, deathType, source, generateTreasure, immediate, impactForce
    -- deathType 0 = normal death with animation
    pcall(function()
        Osi.Die(entity, 0, entity, 0, 0, 0)
    end)

    _P("[DanseMacabre] Entity killed: " .. tostring(entity))
end

--- Clear Death's Door status and reset DC (called when healed)
--- @param entity string Entity GUID
function DeathsDoor.ClearDeathsDoor(entity)
    local name = GetDisplayName(entity)
    _P("[DanseMacabre] " .. name .. " recovered from Death's Door")

    -- Remove main status
    Osi.RemoveStatus(entity, "DEATHS_DOOR")

    -- Remove DOWNED check status if present
    Osi.RemoveStatus(entity, "DEATHS_DOOR_CHECK")

    -- Remove the turn save passive
    pcall(function()
        Osi.RemovePassive(entity, TURN_SAVE_PASSIVE)
    end)

    -- Remove all DC tracking statuses
    for _, status in pairs(DC_STATUSES) do
        Osi.RemoveStatus(entity, status)
    end

    -- Remove from tracking
    local entityUUID = ExtractUUID(entity)
    entitiesInDeathsDoor[entityUUID] = nil
end

--- Apply the Death's Door enabler to an entity
--- @param entity string Entity GUID
function DeathsDoor.EnableForEntity(entity)
    -- Only apply to actual characters, not items/scenery/objects
    if Osi.IsCharacter(entity) ~= 1 then
        return
    end

    if Osi.HasActiveStatus(entity, "DEATHS_DOOR_ENABLER") ~= 1 then
        Osi.ApplyStatus(entity, "DEATHS_DOOR_ENABLER", -1, 1)
        _P("[DanseMacabre] Enabled Death's Door for: " .. tostring(entity))
    end
end

--- Check HP and clear Death's Door if healed above 1
--- @param entity string Entity GUID
function DeathsDoor.CheckHealingClear(entity)
    if Osi.HasActiveStatus(entity, "DEATHS_DOOR") == 1 then
        local hp = Osi.GetHitpoints(entity)
        if hp and hp > 1 then
            DeathsDoor.ClearDeathsDoor(entity)
        end
    end
end

--- Initialize the module
function DeathsDoor.Init()
    _P("[DanseMacabre] Initializing Death's Door module...")

    -- Selection-based audio feedback: apply feedback when Death's Door character is selected
    Ext.Osiris.RegisterListener("GainedControl", 1, "after", function(character)
        -- Remove feedback from previous controlled character
        if currentControlled and currentControlled ~= character then
            RemoveFeedbackStatuses(currentControlled)
        end

        -- Apply feedback if new character is at Death's Door
        if HasDeathsDoorStatus(character) then
            ApplyFeedbackStatuses(character)
        end

        currentControlled = character
    end)

    -- Listen for DEATHS_DOOR status being applied (successful initial save)
    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status, causee, _)
        -- DEBUG: Log ALL Death's Door related statuses
        if string.find(status, "DEATHS_DOOR") then
            local hp = Osi.GetHitpoints(target) or "?"
            _P("[DanseMacabre] DEBUG StatusApplied: " .. status .. " | HP: " .. tostring(hp) .. " | Target: " .. tostring(target))
        end

        -- Handle DEATHS_DOOR_CHECK (triggered when HP = 0)
        -- Note: Re-triggers won't happen because DEATHS_DOOR grants damage immunity
        if status == "DEATHS_DOOR_CHECK" then
            _P("[DanseMacabre] DEATHS_DOOR_CHECK triggered - entering Death's Door")
        end

        if status == "DEATHS_DOOR" then
            local entityUUID = ExtractUUID(target)

            -- Check if this is a re-trigger (entity already in Death's Door)
            local isRetrigger = entitiesInDeathsDoor[entityUUID] ~= nil

            if isRetrigger then
                _P("[DanseMacabre] Re-trigger detected for " .. entityUUID .. " - skipping entry logic")
                -- Just remove the DOWNED check status so they can act
                Ext.Timer.WaitFor(100, function()
                    Osi.RemoveStatus(target, "DEATHS_DOOR_CHECK")
                end)
                return
            end

            local name = GetDisplayName(target)
            _P("[DanseMacabre] " .. name .. " entered Death's Door!")

            entitiesInDeathsDoor[entityUUID] = target

            -- Initialize DC to 8 (only on first entry, not re-triggers)
            -- This is handled here instead of OnApplyFunctors to prevent DC reset
            Osi.ApplyStatus(target, "DEATHS_DOOR_DC_8", -1, 1)
            _P("[DanseMacabre] Initialized DC to 8")

            -- Add the turn save passive
            pcall(function()
                Osi.AddPassive(target, TURN_SAVE_PASSIVE)
            end)

            -- Remove the DOWNED check status so character can act
            -- OnRemoveFunctors handles AP/Movement restoration via ResetCombatTurn() + RestoreResource()
            Ext.Timer.WaitFor(100, function()
                Osi.RemoveStatus(target, "DEATHS_DOOR_CHECK")
            end)

            -- Apply audio feedback if this character is currently controlled
            local targetUUID = ExtractUUID(target)
            local controlledUUID = currentControlled and ExtractUUID(currentControlled) or nil
            if controlledUUID and targetUUID == controlledUUID then
                ApplyFeedbackStatuses(target)
            end
        end

        -- Listen for turn marker (passive applied it at turn start)
        if status == "DEATHS_DOOR_TURN_MARKER" then
            local entityUUID = ExtractUUID(target)
            _P("[DanseMacabre] Turn started for " .. tostring(target))

            -- Track that this entity is in their turn (for DoT filtering)
            currentTurnEntity = entityUUID

            -- Trigger the save
            DeathsDoor.TriggerSave(target, "Turn start")
            -- Clean up the marker
            Osi.RemoveStatus(target, "DEATHS_DOOR_TURN_MARKER")

            -- Clear turn tracking after a delay (allows full turn to process)
            Ext.Timer.WaitFor(5000, function()
                if currentTurnEntity == entityUUID then
                    currentTurnEntity = nil
                end
            end)
        end

        -- Listen for save passed
        if status == "DEATHS_DOOR_SAVE_PASSED" then
            DeathsDoor.OnSavePassed(target)
        end

        -- Listen for save failed
        if status == "DEATHS_DOOR_SAVE_FAILED" then
            DeathsDoor.OnSaveFailed(target)
        end
    end)

    -- Listen for DEATHS_DOOR status being removed
    Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(target, status, causee, _)
        if status == "DEATHS_DOOR" then
            local entityUUID = ExtractUUID(target)
            entitiesInDeathsDoor[entityUUID] = nil
            _P("[DanseMacabre] DEATHS_DOOR removed from " .. tostring(target))

            -- Remove the passive too
            pcall(function()
                Osi.RemovePassive(target, TURN_SAVE_PASSIVE)
            end)

            -- Remove audio feedback
            RemoveFeedbackStatuses(target)
        end
    end)

    -- Listen for attacks to trigger death saves (damage is 0 due to immunity)
    -- Skip DoT on defender's own turn (they already get a turn-start save)
    Ext.Osiris.RegisterListener("AttackedBy", 7, "after", function(defender, attacker, attacker2, damageType, damageAmount, damageCause, storyAction)
        -- Trigger on any attack while in Death's Door (damage is 0 due to immunity boost)
        if Osi.HasActiveStatus(defender, "DEATHS_DOOR") == 1 then
            local defenderUUID = ExtractUUID(defender)

            -- Skip if it's the defender's own turn (DoT - already has turn-start save)
            if currentTurnEntity and currentTurnEntity == defenderUUID then
                _P("[DanseMacabre] Skipping save - DoT on own turn")
                return
            end

            -- Small delay then trigger save
            local capturedDefender = defender
            Ext.Timer.WaitFor(100, function()
                if Osi.HasActiveStatus(capturedDefender, "DEATHS_DOOR") == 1 then
                    _P("[DanseMacabre] Attacked while in Death's Door - triggering save")
                    DeathsDoor.TriggerSave(capturedDefender, "Attacked")
                end
            end)
        end
    end)

    -- Listen for any status applied to check for healing
    Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status, causee, _)
        if Osi.HasActiveStatus(target, "DEATHS_DOOR") == 1 then
            -- Skip our own statuses
            if string.find(status, "DEATHS_DOOR") then return end

            -- Delay to allow healing to process
            local capturedTarget = target
            Ext.Timer.WaitFor(200, function()
                DeathsDoor.CheckHealingClear(capturedTarget)
            end)
        end
    end)

    -- Apply enabler to all party members when session loads
    Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(levelName, isEditorMode)
        _P("[DanseMacabre] Level started, enabling Death's Door for party...")
        for _, entity in pairs(Osi.DB_PartyMembers:Get(nil)) do
            DeathsDoor.EnableForEntity(entity[1])
        end

        -- Setup MCM listener for dynamic setting changes
        SetupMCMListener()
    end)

    -- Apply enabler to characters entering combat (respects MCM setting)
    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(entity, combatGuid)
        -- Check if all combatants mode is enabled via MCM
        if IsAllCombatantsEnabled() then
            -- Enable for everyone
            DeathsDoor.EnableForEntity(entity)
        else
            -- Party only mode (default)
            if Osi.IsPartyMember(entity, 1) == 1 then
                DeathsDoor.EnableForEntity(entity)
            end
        end
    end)

    -- Note: Turn tracking is done via DEATHS_DOOR_TURN_MARKER status application
    -- Osiris events like ObjectTurnStarted/ObjectTurnEnded don't exist in the story
    -- The TURN_MARKER approach works because it's applied at turn start by the passive

    -- Clean up tracking when entity is resurrected
    Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(entity)
        local entityUUID = ExtractUUID(entity)
        _P("[DanseMacabre] Entity resurrected: " .. tostring(entityUUID))
        -- Clean up tracking tables
        killingEntities[entityUUID] = nil
        entitiesInDeathsDoor[entityUUID] = nil
    end)

    -- Clean up tracking when combat ends
    Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function(combat)
        _P("[DanseMacabre] Combat ended, clearing Death's Door tracking")

        -- Remove feedback from any entities that had it
        if currentControlled then
            RemoveFeedbackStatuses(currentControlled)
        end

        -- Clear all tracking tables
        entitiesInDeathsDoor = {}
        processingEntities = {}
        killingEntities = {}
        currentTurnEntity = nil
        currentControlled = nil
    end)

    _P("[DanseMacabre] Death's Door module initialized")
end

return DeathsDoor
