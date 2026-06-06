-- floodBeamMP (client) - rewritten for BeamNG 0.36+
--
-- Runs in each player's BeamNG client (GE Lua). Receives events from the
-- BeamMP server and raises/lowers the local water level so every player sees
-- (and gets flooded by) the same rising water.
--
-- What was broken on 0.36 (and is fixed here):
--   1. Ocean lookup matched object *names* only, but findClassObjects() can
--      return numeric *IDs* -> ocean was never found -> client reported nil
--      -> server printed "This map doesn't have an ocean".
--   2. Height was read/written via the legacy `obj.position` MatrixF property
--      (obj.position:getColumn(3).z / obj.position = MatrixF). The current
--      engine uses obj:getPosition() / obj:setPosition(vec3). We use those,
--      with a MatrixF fallback for older clients.
--   3. Bonus: if the map genuinely has no ocean, we now CREATE a WaterPlane
--      at runtime so the flood works on ANY map.

local M = {}

local GENERATED_WATER_NAME = "flood_generatedWaterPlane"

local ocean = nil
local oceanCreatedByUs = false
local allWater = {}      -- rivers / water blocks (for hide-when-submerged)
local hiddenWater = {}
local calledOnInit = false

-- init-report retry (the scene may not be fully populated the instant
-- E_OnPlayerLoaded fires)
local pendingInit = false
local initTimer = 0
local initTries = 0

M.hideCoveredWater = true

-- Smooth interpolation: the server sends discrete level updates; rather than
-- snapping the water plane to each one (jerky), we ease the applied height
-- toward the latest target every frame. Higher rate = snappier, lower = floatier.
local targetZ = nil   -- latest height the server wants
local currentZ = nil  -- height actually applied (smoothed)
local SMOOTH_RATE = 3.0

-- ---------------------------------------------------------------------------
-- Transform helpers (version-tolerant)
-- ---------------------------------------------------------------------------
local function getObjZ(obj)
  if not obj then return nil end
  if obj.getPosition then
    local p = obj:getPosition()
    if p then return p.z end
  end
  if obj.position and obj.position.getColumn then -- legacy fallback
    return obj.position:getColumn(3).z
  end
  return nil
end

local function setObjZ(obj, z)
  if not obj then return end
  if obj.getPosition and obj.setPosition then
    local p = obj:getPosition()
    obj:setPosition(vec3(p.x, p.y, z))
    return true
  end
  if obj.position and obj.position.getColumn then -- legacy fallback
    local c3 = obj.position:getColumn(3)
    local mat = MatrixF(true)
    mat:setColumn(0, obj.position:getColumn(0))
    mat:setColumn(1, obj.position:getColumn(1))
    mat:setColumn(2, obj.position:getColumn(2))
    mat:setColumn(3, vec3(c3.x, c3.y, z))
    obj.position = mat
    return true
  end
  return false
end

-- A scenetree class-object entry may be a name string OR a numeric id.
local function resolveObject(idOrName)
  local num = tonumber(idOrName)
  if num then
    return scenetree.findObjectById(num)
  end
  return scenetree.findObject(idOrName)
end

local function objName(obj, fallback)
  if obj and obj.getName then
    local ok, n = pcall(function() return obj:getName() end)
    if ok and n then return n end
  end
  return tostring(fallback or "")
end

-- ---------------------------------------------------------------------------
-- Water discovery / creation
-- ---------------------------------------------------------------------------
local function findOcean()
  local objs = scenetree.findClassObjects("WaterPlane") or {}
  local firstValid = nil
  for _, idOrName in pairs(objs) do
    local obj = resolveObject(idOrName)
    if obj then
      firstValid = firstValid or obj
      local nm = string.lower(objName(obj, idOrName))
      if string.find(nm, "ocean") then
        return obj
      end
    end
  end
  return firstValid -- no "ocean"-named plane: just use the first WaterPlane
end

local function getAllWater()
  local water = {}
  for _, className in ipairs({ "River", "WaterBlock" }) do
    local objs = scenetree.findClassObjects(className) or {}
    for _, idOrName in pairs(objs) do
      local obj = resolveObject(idOrName)
      if obj then table.insert(water, obj) end
    end
  end
  return water
end

local function createOcean()
  if not scenetree.MissionGroup then
    log("E", "floodBeamMP", "No MissionGroup; cannot create water")
    return nil
  end
  local obj = createObject("WaterPlane")
  if not obj then
    log("E", "floodBeamMP", "createObject('WaterPlane') failed")
    return nil
  end

  obj:setField("baseColor", 0, "45 108 171 255")
  obj:setField("rippleDir", 0, "0.000000 1.000000")
  obj:setField("rippleDir", 1, "0.707000 0.707000")
  obj:setField("rippleDir", 2, "0.500000 0.860000")
  obj:setField("rippleTexScale", 0, "7.140000 7.140000")
  obj:setField("rippleTexScale", 1, "6.250000 12.500000")
  obj:setField("rippleTexScale", 2, "50.000000 50.000000")
  obj:setField("rippleSpeed", 0, "0.065")
  obj:setField("rippleSpeed", 1, "0.09")
  obj:setField("rippleSpeed", 2, "0.04")
  obj:setField("rippleMagnitude", 0, "1.0")
  obj:setField("rippleMagnitude", 1, "1.0")
  obj:setField("rippleMagnitude", 2, "0.3")
  obj:setField("overallRippleMagnitude", 0, "1.0")
  obj:setField("waveDir", 0, "0.000000 1.000000")
  obj:setField("waveDir", 1, "0.707000 0.707000")
  obj:setField("waveDir", 2, "0.500000 0.860000")
  obj:setField("waveMagnitude", 0, "0.2")
  obj:setField("waveMagnitude", 1, "0.2")
  obj:setField("waveMagnitude", 2, "0.2")
  obj:setField("waveSpeed", 0, "1")
  obj:setField("waveSpeed", 1, "1")
  obj:setField("waveSpeed", 2, "1")
  obj:setField("overallWaveMagnitude", 0, "1.0")
  obj:setField("rippleTex", 0, "core/art/water/ripple.dds")
  obj:setField("depthGradientTex", 0, "core/art/water/depthcolor_ramp.dds")
  obj:setField("foamTex", 0, "core/art/water/foam.dds")
  obj:setField("cubemap", 0, "DefaultSkyCubemap")

  -- Start low so flooding begins on dry ground.
  local px, py, startZ = 0.0, 0.0, 0.0
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if veh and veh.getPosition then
    local vp = veh:getPosition()
    px, py, startZ = vp.x, vp.y, vp.z - 1.0
  elseif core_terrain and core_terrain.getTerrain() then
    local t = core_terrain.getTerrain()
    if t and t.getPosition then startZ = t:getPosition().z end
  end

  obj:registerObject(GENERATED_WATER_NAME)
  scenetree.MissionGroup:addObject(obj)
  obj:setPosition(vec3(px, py, startZ))
  if obj.reloadTextures then obj:reloadTextures() end

  oceanCreatedByUs = true
  log("I", "floodBeamMP", "Created WaterPlane at Z=" .. tostring(startZ))
  return obj
end

-- ---------------------------------------------------------------------------
-- Hide rivers/blocks that get submerged (cosmetic, from original mod)
-- ---------------------------------------------------------------------------
local function handleWaterSources()
  local height = getObjZ(ocean)
  if not height then return end
  for id, water in pairs(allWater) do
    local wz = getObjZ(water)
    if wz then
      if M.hideCoveredWater and not hiddenWater[id] and wz < height then
        water.isRenderEnabled = false
        hiddenWater[id] = true
      elseif wz > height and hiddenWater[id] then
        water.isRenderEnabled = true
        hiddenWater[id] = false
      elseif not M.hideCoveredWater and hiddenWater[id] then
        water.isRenderEnabled = true
        hiddenWater[id] = false
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Init: locate (or create) the ocean, then report its level to the server.
-- ---------------------------------------------------------------------------
local function locateWater()
  allWater = getAllWater()
  ocean = findOcean()
  if not ocean then
    ocean = createOcean() -- make the mod work on oceanless maps too
  end
  return ocean
end

local function reportInitLevel()
  local level = getObjZ(ocean)
  if level then
    TriggerServerEvent("E_OnInitiliaze", tostring(level)) -- keep server's event name
    calledOnInit = true
    pendingInit = false
    log("I", "floodBeamMP", "Reported initial water level: " .. tostring(level))
    return true
  end
  return false
end

AddEventHandler("E_OnPlayerLoaded", function()
  locateWater()
  if calledOnInit then return end
  if not reportInitLevel() then
    -- scene not ready yet; keep trying for a few seconds in onUpdate
    pendingInit = true
    initTimer = 0
    initTries = 0
  end
end)

AddEventHandler("E_SetWaterLevel", function(level)
  level = tonumber(level)
  if not level then return end
  if not ocean then
    locateWater()
    if not ocean then
      log("W", "floodBeamMP", "E_SetWaterLevel: no ocean")
      return
    end
  end
  targetZ = level
  if currentZ == nil then
    -- first update (or a reset/teleport): snap so we don't slide across the map
    currentZ = level
    setObjZ(ocean, level)
    handleWaterSources()
  end
end)

-- ---------------------------------------------------------------------------
-- Rain (kept from original; defensive lookups). Volume -1 = auto.
-- ---------------------------------------------------------------------------
AddEventHandler("E_SetRainVolume", function(volume)
  volume = tonumber(volume) or 0
  local rainObj = scenetree.findObject("rain_coverage")
  if not rainObj then
    log("W", "floodBeamMP", "E_SetRainVolume: rain_coverage not found")
    return
  end

  local soundObj = scenetree.findObject("rain_sound")
  if soundObj then soundObj:delete() end

  if volume == -1 then -- automatic, based on drop count
    volume = (rainObj.numDrops or 0) / 100
  end

  soundObj = createObject("SFXEmitter")
  soundObj.scale = Point3F(100, 100, 100)
  soundObj.fileName = String('/art/sound/environment/amb_rain_medium.ogg')
  soundObj.playOnAdd = true
  soundObj.isLooping = true
  soundObj.volume = volume
  soundObj.isStreaming = true
  soundObj.is3D = false
  soundObj:registerObject('rain_sound')
end)

AddEventHandler("E_SetRainAmount", function(amount)
  amount = tonumber(amount) or 0
  local rainObj = scenetree.findObject("rain_coverage")
  if not rainObj then
    rainObj = createObject("Precipitation")
    rainObj.dataBlock = scenetree.findObject("rain_medium")
    rainObj.splashSize = 0
    rainObj.splashMS = 0
    rainObj.animateSplashes = 0
    rainObj.boxWidth = 16.0
    rainObj.boxHeight = 10.0
    rainObj.dropSize = 1.0
    rainObj.doCollision = true
    rainObj.hitVehicles = true
    rainObj.rotateWithCamVel = true
    rainObj.followCam = true
    rainObj.useWind = true
    rainObj.minSpeed = 0.4
    rainObj.maxSpeed = 0.5
    rainObj.minMass = 4
    rainObj.masMass = 5
    rainObj:registerObject('rain_coverage')
  end
  rainObj.numDrops = amount
end)

-- ---------------------------------------------------------------------------
-- onUpdate: only used to retry the initial report if the scene wasn't ready.
-- ---------------------------------------------------------------------------
local function onUpdate(dtReal)
  local dt = dtReal or 0

  -- Retry the initial level report if the scene wasn't ready at join time.
  if pendingInit then
    initTimer = initTimer + dt
    if initTimer >= 0.5 then
      initTimer = 0
      initTries = initTries + 1
      locateWater()
      if reportInitLevel() or initTries >= 20 then -- up to ~10s
        pendingInit = false
      end
    end
  end

  -- Smoothly ease the water toward the server's latest target each frame.
  if ocean and targetZ and currentZ and math.abs(targetZ - currentZ) > 1e-4 then
    local t = math.min(1, dt * SMOOTH_RATE)
    currentZ = currentZ + (targetZ - currentZ) * t
    if math.abs(targetZ - currentZ) < 1e-3 then currentZ = targetZ end
    setObjZ(ocean, currentZ)
    handleWaterSources()
  end
end

M.onUpdate = onUpdate
M.locateWater = locateWater

return M
