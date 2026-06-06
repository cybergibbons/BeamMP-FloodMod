-- Auto-loads the flood client extension when the mod is mounted, and keeps it
-- loaded across Lua reloads (registerCoreModule).
load("floodBeamMP")
registerCoreModule("floodBeamMP")
