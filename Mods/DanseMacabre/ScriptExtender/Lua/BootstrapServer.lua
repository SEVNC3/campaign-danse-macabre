---@diagnostic disable: undefined-global
-- Danse Macabre - BootstrapServer.lua
-- Death's Door System - A dramatic death system overhaul

_P("[DanseMacabre] Loading Danse Macabre...")

-- Load and initialize the Death's Door module
local DeathsDoor = Ext.Require("Server/DeathsDoor.lua")

-- Export to mod table for external access
Mods.DanseMacabre = Mods.DanseMacabre or {}
Mods.DanseMacabre.DeathsDoor = DeathsDoor

-- Initialize when session loads
Ext.Events.SessionLoaded:Subscribe(function()
    _P("[DanseMacabre] Session loaded, initializing Death's Door...")
    DeathsDoor.Init()
    _P("[DanseMacabre] Danse Macabre fully initialized")
end)

_P("[DanseMacabre] BootstrapServer.lua loaded")
