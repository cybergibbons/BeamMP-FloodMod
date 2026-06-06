# BeamMP Flood Mod (BeamNG 0.36+)

A working rising-water **flood** mod for **BeamMP** servers on current BeamNG
(tested on 0.36.1.0). A flood is triggered by a server admin via chat/console
commands; the water then rises smoothly on every connected player's client —
and because BeamNG's physics reads the live water plane, vehicles actually get
flooded (buoyancy + engine drowning), not just visually.

This is a fix/rework of the structure from
[daniel-w0/BeamMP-FloodMod](https://github.com/daniel-w0/BeamMP-FloodMod),
whose client stopped working on newer BeamNG. See **Credits** below.

---

## Why the old one said "This map doesn't have an ocean"

The server depends entirely on the **client** reporting the map's water level.
On 0.36 the original client always returned `nil`, so the server concluded the
map had no ocean — even on maps that clearly do (e.g. Italy, whose sea is a
`WaterPlane` named `Ocean1` at Z≈137.6).

Fixed in `floodBeamMP.lua`:

1. **Ocean detection.** The original matched the water object by *name* only,
   but on 0.36 `scenetree.findClassObjects("WaterPlane")` can return numeric
   **IDs**, so the name match never hit. Detection now resolves both names and
   IDs and matches any `WaterPlane` (preferring one named like an ocean).
2. **Transform API.** Height was read/written via the legacy `obj.position`
   `MatrixF` property. Current BeamNG uses `obj:getPosition()` /
   `obj:setPosition(vec3)` (as the game's own `audioRibbonEditor` /
   `objectTool` do). We use those, with a `MatrixF` fallback for old clients.
3. **Smooth rise.** The client now **interpolates** the water height toward the
   server's latest target every frame instead of snapping to each discrete
   update, so the rise glides rather than stair-stepping.
4. **Works on oceanless maps.** If a map has no `WaterPlane`, the client
   **creates one at runtime**, so flooding works anywhere — not just ocean maps.

---

## Layout

```
Resources/
  Client/
    floodBeamMP.zip          # the packaged client mod (auto-sent to players)
    floodBeamMP/             # unpacked client source (edit here, then build.sh)
      scripts/flood/modScript.lua
      lua/ge/extensions/floodBeamMP.lua
  Server/
    Flood/
      main.lua               # chat/console command router
      flood.lua              # flood logic, commands, per-tick water update
      multiplayer.lua        # hSendChatMessage helper
build.sh                     # rebuilds floodBeamMP.zip after client edits
```

## Install on a BeamMP server

1. Copy `Resources/Client/floodBeamMP.zip` into your server's `Resources/Client/`.
2. Copy `Resources/Server/Flood/` into your server's `Resources/Server/`.
3. Restart the server. Connecting players auto-download the client mod.

> Note: a private server (`Private = true` in `ServerConfig.toml`) does not
> validate its AuthKey against the backend, so the flood works even while the
> BeamMP server list / keymaster is down, as long as the player **auth**
> backend is reachable (direct connect).

## Commands (BeamMP chat or server console)

| Command | Effect |
|---|---|
| `/flood_start` | Begin raising the water |
| `/flood_stop` | Pause the rise |
| `/flood_reset` | Restore the original water level |
| `/flood_level <z>` | Set the absolute water height instantly |
| `/flood_speed <n>` | Rise added per tick (ticks every 25 ms). `0.001`≈crawl, `0.1`≈gentle, `0.3`≈fast |
| `/flood_limit <z>` + `/flood_limitEnabled true` | Cap the maximum height |
| `/flood_decrease true` | Lower the water instead of raising |
| `/flood_resetAt <z>` | Auto-reset to start once this height is reached |
| `/flood_rainAmount <n>` / `/flood_rainVolume <n>` | Optional rain (drops; volume `-1`=auto) |
| `/flood_printSettings` | Print current settings |

## Tuning the smoothness

In `Resources/Client/floodBeamMP/lua/ge/extensions/floodBeamMP.lua`:

```lua
local SMOOTH_RATE = 3.0  -- higher = snappier/tracks tighter, lower = floatier
```

Smoothness is governed by both `SMOOTH_RATE` (client) and `/flood_speed`
(server, how big each step is). For the gentlest rise, use a low `/flood_speed`
(e.g. `0.05`). After editing the client, run `./build.sh` and restart the
server so players re-download the updated mod.

## Editing / rebuilding

After changing anything under `Resources/Client/floodBeamMP/`, run:

```
./build.sh
```

to repack `floodBeamMP.zip`, then restart the server (players reconnect to pull it).

## Notes / limits

- Rivers and water blocks below the ocean line are hidden to avoid z-fighting.
- Each client moves its own water plane to the server-broadcast level, so all
  players stay in sync.
- Powertrain "drowning" / buoyancy is BeamNG's own physics; we only move the
  water surface.

## Credits

- Original mod & server/command structure:
  [daniel-w0/BeamMP-FloodMod](https://github.com/daniel-w0/BeamMP-FloodMod)
  (no license stated upstream at time of writing).
- 0.36 client fixes (ocean detection, transform API, smoothing, runtime water
  creation): this fork.

If the upstream author specifies a license, this fork will follow it. Shared
for the BeamMP community in the same spirit as the original.
