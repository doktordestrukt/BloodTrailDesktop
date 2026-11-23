-- BloodTrail Desktop (BTDesktop) - play Blood Trail with keyboard and mouse, no headset.
-- https://github.com/doktordestrukt/BloodTrailDesktop
-- Drives the VR pawn, its camera and both grip motion controllers from the keyboard and mouse;
-- weapons go through the game's own grip system, so the game treats them as held.
-- Keys: see README.md in this folder. Settings: BTDesktop.ini in this folder (or Esc in game).
--
-- Rules learned the hard way in this game:
--  * one persistent LoopInGameThreadAfterFrames loop, never a new ExecuteInGameThread closure per frame
--  * pcall + validity checks around every UObject access
--  * LoadAsset only on blueprint classes / packages, never on mesh assets
--  * never hook Fire_pistol

local UEHelpers = require("UEHelpers")

local TAG = "[BTDesktop] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local modDir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\][Ss]cripts[/\\]") or "."

------------------------------------------------------------------------------- settings
local CFG = {
    DisableHMD = 1,           -- 1: switch the headset off at start (desktop view even if SteamVR runs)
    BlockGameKeys = 1,        -- 1: the pawn's own keyboard debug keys (W, Q, F, Space...) are switched off
    EyeHeight = 165,          -- cm above the floor
    CrouchDrop = 60,          -- cm the head goes down when crouching
    MouseSensitivity = 2.5,   -- degrees per unit of the engine's MouseX/MouseY axis value
    SprintMultiplier = 2.3,
    WalkSpeed = 300,          -- cm/s walking (the game's own is 225); sprint = WalkSpeed x SprintMultiplier
    NoclipSpeed = 700,        -- cm/s (x2 with Shift)
    SelfTest = 0,             -- 1: scripted test of every feature at start; PASS/FAIL lines in UE4SS.log
    SelfTestEnd = "hold",     -- after the self test: "hold" = keep the glock in the right hand and wave the hands
    StartMap = "",            -- e.g. /Game/Maps/Sandbox/Map_Sandbox: opened once at start (no VR menu needed)
    RigidGrip = 1,            -- 1 = weapons are drawn as a viewmodel (grip paused, physics off, placed every frame)
    MeleePitch = 50,          -- degrees a melee weapon is tilted up in the hand
    PlayerClass = "/Game/VRExpansion/Vive/WendigoVrChar.WendigoVrChar_C",  -- spawned if the game spawns no player
    FOV = 90,                 -- normal field of view
    AimFOV = 55,              -- field of view while aiming down sights (mouse wheel changes it while aiming)
    SightDrop = 3.0,          -- cm the barrel sits below the eye line when aiming (sight height)
    Hud = 1,                  -- 1 = black/red HUD (loadout bar, ammo, health, crosshair)
    HudDistance = 12,         -- cm in front of the eye the HUD is drawn at (must be nearer than the weapon)
    AimGunDistance = 40,      -- cm in front of the eye the weapon sits when aiming down sights
    MeleeDamage = 45,         -- base damage of a melee swing
    AimCalibrate = 0,         -- 1 = correct the muzzle by the measured bullet direction (measured: bullets follow the muzzle arrow exactly)
    AimToggle = 0,            -- 1 = right mouse toggles aiming instead of holding
    ViewBob = 1.5,            -- cm of camera bob while walking (0 = off)
    GrenadeSpeed = 1500,      -- cm/s throw speed
    GrenadeFuse = 3.0,        -- seconds until a thrown pipe bomb is forced to explode
    Aspect = 1.7778,          -- screen width / height (HUD layout)
    ZeroDistance = 2500,      -- cm: the weapon is zeroed at this distance (hip and sights), so it never swings
                              -- around with what is under the crosshair
    ShowGloves = 1,           -- 1 = show the game's own gloves on both hands (pinned to the hands, no physics)
    Crosshair = 1,            -- 1 = white crosshair
    ScreenPercentage = 100,   -- resolution scale in % (Esc > Graphics)
    GunHands = 0,             -- 1 = show the weapon's own posed hand meshes (makes the game drop the weapon after a shot: keep 0)
    RadioVolume = 60,         -- radio volume 0-100 (music from the Music folder in the game folder)
    RadioNoise = 1,           -- 1 = enemies hear the radio (louder = heard further away)
}

-- key bindings (Esc > Controls; saved as Key_<Action>= in BTDesktop.ini). UE key names.
local ACTIONS = {
    { "Forward", "W", "MOVE FORWARD" }, { "Back", "S", "MOVE BACK" }, { "Left", "A", "STRAFE LEFT" },
    { "Right", "D", "STRAFE RIGHT" }, { "Sprint", "LeftShift", "SPRINT" }, { "Crouch", "LeftControl", "CROUCH" },
    { "Jump", "SpaceBar", "JUMP" }, { "Fire", "LeftMouseButton", "FIRE / MELEE / USE" },
    { "Aim", "RightMouseButton", "AIM (HOLD)" }, { "AimToggle", "Z", "AIM (TOGGLE)" },
    { "Reload", "R", "RELOAD" }, { "FireMode", "B", "FIRE MODE (AUTO / SEMI / BURST)" },
    { "Interact", "E", "INTERACT / PRESS" }, { "Holster", "Q", "HOLSTER WEAPON" }, { "Grab", "G", "GRAB / DROP" },
    { "Grenade", "T", "THROW PIPE BOMB" }, { "Crack", "H", "CRACK (HEAL)" }, { "NightVision", "N", "NIGHT VISION" },
    { "Flashlight", "F", "FLASHLIGHT" }, { "ResetHands", "V", "RESET HANDS" }, { "Radio", "M", "RADIO ON / OFF" },
    { "RadioNext", "Period", "RADIO: NEXT SONG" },
    { "Slot1", "One", "WEAPON SLOT 1" }, { "Slot2", "Two", "WEAPON SLOT 2" }, { "Slot3", "Three", "WEAPON SLOT 3" },
    { "Slot4", "Four", "WEAPON SLOT 4" }, { "Slot5", "Five", "WEAPON SLOT 5" }, { "Slot6", "Six", "WEAPON SLOT 6" },
    { "Slot7", "Seven", "WEAPON SLOT 7" }, { "Slot8", "Eight", "WEAPON SLOT 8" }, { "Slot9", "Nine", "WEAPON SLOT 9" },
    { "Slot10", "Zero", "WEAPON SLOT 10" }, { "Slot11", "Hyphen", "WEAPON SLOT 11" }, { "Slot12", "Equals", "WEAPON SLOT 12" },
}
local B = {}
for _, a in ipairs(ACTIONS) do B[a[1]] = a[2] end
local KEYLABEL = { One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8",
    Nine = "9", Zero = "0", Hyphen = "-", Equals = "=", LeftMouseButton = "LMB", RightMouseButton = "RMB",
    MiddleMouseButton = "MMB", ThumbMouseButton = "MOUSE 4", ThumbMouseButton2 = "MOUSE 5", LeftShift = "SHIFT",
    RightShift = "R-SHIFT", LeftControl = "CTRL", RightControl = "R-CTRL", LeftAlt = "ALT", RightAlt = "R-ALT",
    SpaceBar = "SPACE", CapsLock = "CAPS", BackSpace = "BKSP", LeftBracket = "[", RightBracket = "]",
    Semicolon = ";", Apostrophe = "'", Comma = ",", Period = ".", Slash = "/", Backslash = "\\", Tilde = "`",
    PageUp = "PG UP", PageDown = "PG DN", Enter = "ENTER", Tab = "TAB" }
local function keyLabel(k) if not k or k == "" then return "-" end return KEYLABEL[k] or k:upper() end
local function slotKey(i) return keyLabel(B["Slot" .. i]) end
local function loadConfig()
    local f = io.open(modDir .. "\\BTDesktop.ini", "r")
    if not f then return end
    for line in f:lines() do
        line = line:gsub(";.*$", "")
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and CFG[k] ~= nil then CFG[k] = tonumber(v) or v
        elseif k and k:sub(1, 4) == "Key_" and B[k:sub(5)] ~= nil then B[k:sub(5)] = v end
    end
    f:close()
end
loadConfig()
-- write the current settings back into BTDesktop.ini (keeps comments and unknown lines)
local SAVE_KEYS = { "MouseSensitivity", "AimToggle", "FOV", "AimFOV", "ViewBob", "WalkSpeed", "SprintMultiplier",
    "EyeHeight", "Crosshair", "ShowGloves", "ScreenPercentage", "ZeroDistance", "GunHands", "RadioVolume", "RadioNoise" }
local function saveConfig()
    local path = modDir .. "\\BTDesktop.ini"
    local lines = {}
    local f = io.open(path, "r")
    if f then for line in f:lines() do lines[#lines + 1] = line end f:close() end
    local function val(k)
        if CFG[k] ~= nil then return tostring(CFG[k]) end
        if k:sub(1, 4) == "Key_" and B[k:sub(5)] ~= nil then return B[k:sub(5)] end
    end
    local seen, hasKeys = {}, false
    for i, line in ipairs(lines) do
        if line:match("^%s*%[Keys%]") then hasKeys = true end
        local k, rest = line:match("^%s*([%w_]+)%s*=[^;]*(.*)$")
        if k and val(k) and not seen[k] then
            lines[i] = k .. "=" .. val(k) .. (rest ~= "" and ("  " .. rest) or "")
            seen[k] = true
        end
    end
    for _, k in ipairs(SAVE_KEYS) do if not seen[k] then lines[#lines + 1] = k .. "=" .. val(k) seen[k] = true end end
    local missing = {}
    for _, a in ipairs(ACTIONS) do if not seen["Key_" .. a[1]] then missing[#missing + 1] = "Key_" .. a[1] .. "=" .. B[a[1]] end end
    if #missing > 0 then
        if not hasKeys then lines[#lines + 1] = "[Keys]" end
        for _, l in ipairs(missing) do lines[#lines + 1] = l end
    end
    local w = io.open(path, "w")
    if w then w:write(table.concat(lines, "\n") .. "\n") w:close() end
end
-- Git Bash turns "/Game/..." arguments into "C:/Program Files/Git/Game/...": keep the /Game part
if type(CFG.StartMap) == "string" then CFG.StartMap = CFG.StartMap:match("(/Game/.*)$") or CFG.StartMap end

-- number keys 1-9: weapon classes (found in the pak index; all are VRExpansion grippables)
-- { name, class, (unused), support-hand distance along the barrel from the grip in cm (0 = pistol,
--   cup the grip), sight height above the bore in cm and sideways sight offset in cm (aiming down sights) }
-- (BP_Skel12gabuckshot is the 12-gauge SHELL, not a gun - it was invisible in the hand; BP_TacPistol is
-- from the WeaponMaster system and cannot be gripped by the VRExpansion hands)
local WEAPONS = {
    { "Glock",        "/Game/VRExpansion/Guns/skeletalguns/bp_skel_glock.bp_skel_glock_C", 0, 0, 2.8 },
    { "92FS",         "/Game/VRExpansion/Guns/skeletalguns/bp_skel_92fs.bp_skel_92fs_C", 0, 0, 2.8 },
    { "AK",           "/Game/VRExpansion/Guns/skeletalguns/bp_Skel_ak.bp_Skel_ak_C", 0, 26, 4.5 },
    { "AR",           "/Game/VRExpansion/Guns/skeletalguns/BP_SkelARNEW.BP_SkelARNEW_C", 0, 24, 10.1, 0.5 },
    { "Vector",       "/Game/VRExpansion/Guns/skeletalguns/bp_skel_vector.bp_skel_vector_C", 0, 16, 4.5 },
    { "Shotgun",      "/Game/VRExpansion/Guns/skeletalguns/bp_Skel_shotgun.bp_Skel_shotgun_C", 0, 30, 3.0 },
    { "Knife",        "/Game/VRExpansion/Guns/BT_MeleeWeapons/WendigoWeapons/NewWeapons/Bp_HuntingKnife_V3.Bp_HuntingKnife_V3_C", 0 },
    { "Bat",          "/Game/VRExpansion/Guns/BT_MeleeWeapons/WendigoWeapons/BatBP.BatBP_C", 0 },
}
-- The bar: first the weapons in your holsters (what you picked on the basement's WEAPON LOADOUT
-- board: right holster, back, left), then the spawnable list. Rebuilt when the board changes them.
local HOLSTER_REFS = { { "ActorrefSidearm", "HIP" }, { "ActorrefLongA", "BACK" }, { "ActorrefLongB", "LEFT" } }
local SLOTS = {}
for i, w in ipairs(WEAPONS) do SLOTS[i] = { name = w[1], w = w } end
local function prettyClass(cls)
    local n = cls:gsub("_C$", ""):gsub("^[Bb][Pp]_", ""):gsub("^[Ss]kel_?", ""):gsub("^Skel", ""):gsub("_V%d+$", ""):gsub("BP$", "")
    return n:gsub("_", " ")
end
local function weaponRowForClass(cls)
    for _, w in ipairs(WEAPONS) do
        if w[2]:match("%.([^.]+)$") == cls then return w end
    end
    return nil
end

local NPC_CLASS = "/Game/characters/Human/Blueprints/CharacterLogic/BP_NPC_Man.BP_NPC_Man_C"
local DIGITS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }

------------------------------------------------------------------------------- math
local DEG, RAD = math.pi / 180, 180 / math.pi
local function rotToQuat(p, y, r)  -- FRotator -> FQuat (UE4 formula)
    local sp, cp = math.sin(p * DEG / 2), math.cos(p * DEG / 2)
    local sy, cy = math.sin(y * DEG / 2), math.cos(y * DEG / 2)
    local sr, cr = math.sin(r * DEG / 2), math.cos(r * DEG / 2)
    return { cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy }
end
local function normAxis(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end
local function quatToRot(q)  -- FQuat -> FRotator (UE4 FQuat::Rotator)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local test = z * x - w * y
    local yaw = math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * RAD
    if test < -0.4999995 then
        return { Pitch = -90, Yaw = yaw, Roll = normAxis(-yaw - 2 * math.atan(x, w) * RAD) }
    elseif test > 0.4999995 then
        return { Pitch = 90, Yaw = yaw, Roll = normAxis(yaw - 2 * math.atan(x, w) * RAD) }
    end
    return { Pitch = math.asin(2 * test) * RAD, Yaw = yaw, Roll = math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * RAD }
end
local function qmul(a, b)
    return { a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
             a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
             a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
             a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3] }
end
local function qconj(q) return { -q[1], -q[2], -q[3], q[4] } end
local function qrot(q, vx, vy, vz)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
    return vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx)
end
local function rq(r) return rotToQuat(r.Pitch, r.Yaw, r.Roll) end
local function qnormalize(q)
    local n = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if n < 1e-9 then return { 0, 0, 0, 1 } end
    return { q[1] / n, q[2] / n, q[3] / n, q[4] / n }
end
-- q^t (fraction t of the rotation q, shortest way)
local function qpow(q, t)
    q = qnormalize(q)
    if q[4] < 0 then q = { -q[1], -q[2], -q[3], -q[4] } end
    local half = math.acos(math.min(1, q[4]))
    local sh = math.sin(half)
    if sh < 1e-6 then return { 0, 0, 0, 1 } end
    local nh = half * t
    local k = math.sin(nh) / sh
    return { q[1] * k, q[2] * k, q[3] * k, math.cos(nh) }
end
local function clamp(v, a, b) return v < a and a or (v > b and b or v) end
local function v3(x, y, z) return { X = x, Y = y, Z = z } end

------------------------------------------------------------------------------- game access
local function valid(o)
    local t = type(o)
    if t ~= "userdata" and t ~= "table" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function fullName(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and n or "?"
end
local function shortName(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local cachedPC, lastPCSearch = nil, -10
local function getPC()
    if valid(cachedPC) then return cachedPC end
    local now = os.clock()
    if now - lastPCSearch < 0.5 then return nil end
    lastPCSearch = now
    local pc = UEHelpers.GetPlayerController()
    if valid(pc) then cachedPC = pc return pc end
    return nil
end
local function getWorld(pc)
    local ok, w = pcall(function() return pc:GetWorld() end)
    if ok and valid(w) then return w end
    return nil
end
local CDO = {}
local function cdo(path)
    local o = CDO[path]
    if valid(o) then return o end
    o = StaticFindObject(path)
    CDO[path] = o
    return valid(o) and o or nil
end
local function GS() return cdo("/Script/Engine.Default__GameplayStatics") end
local function KSL() return cdo("/Script/Engine.Default__KismetSystemLibrary") end

local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path:match("^(.-)%.") or path)  -- package of a blueprint class: fine to load
    c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end

local function xform(x, y, z, rot)
    local q = rot and rq(rot) or { 0, 0, 0, 1 }
    return { Rotation = { X = q[1], Y = q[2], Z = q[3], W = q[4] }, Translation = v3(x, y, z), Scale3D = v3(1, 1, 1) }
end
local function spawnActor(world, cls, t, handling)
    local gs = GS()
    local a = gs:BeginDeferredActorSpawnFromClass(world, cls, t, handling or 1, nil)
    if not valid(a) then return nil end
    gs:FinishSpawningActor(a, t)
    return valid(a) and a or nil
end

------------------------------------------------------------------------------- input
local FK = {}
local function fkey(n)
    local k = FK[n]
    if not k then k = { KeyName = FName(n) } FK[n] = k end
    return k
end
local virt, virtAxis = {}, {}       -- keys / axes injected by the self test
local keyNow, keyPrev = {}, {}
local WATCH = {}
local FIXED_KEYS = { "W", "A", "S", "D", "LeftAlt", "X", "MiddleMouseButton", "Escape", "Up", "Down", "Left", "Right",
    "Enter", "SpaceBar", "LeftMouseButton", "RightMouseButton", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "J" }
local function rebuildWatch()
    local seen = {}
    WATCH = {}
    for _, k in ipairs(FIXED_KEYS) do if not seen[k] then seen[k] = true WATCH[#WATCH + 1] = k end end
    for _, a in ipairs(ACTIONS) do local k = B[a[1]] if k and k ~= "" and not seen[k] then seen[k] = true WATCH[#WATCH + 1] = k end end
end
rebuildWatch()
-- every key that can be bound (Esc > Controls)
local ALLKEYS = { "LeftMouseButton", "RightMouseButton", "MiddleMouseButton", "ThumbMouseButton", "ThumbMouseButton2",
    "LeftShift", "RightShift", "LeftControl", "RightControl", "LeftAlt", "RightAlt", "SpaceBar", "Tab", "CapsLock",
    "Enter", "BackSpace", "Up", "Down", "Left", "Right", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
    "Hyphen", "Equals", "LeftBracket", "RightBracket", "Semicolon", "Apostrophe", "Comma", "Period", "Slash",
    "Backslash", "Tilde", "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F12",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour", "NumPadFive", "NumPadSix", "NumPadSeven",
    "NumPadEight", "NumPadNine" }
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do ALLKEYS[#ALLKEYS + 1] = c end

local function readKeys(pc)
    for _, n in ipairs(WATCH) do
        keyPrev[n] = keyNow[n]
        local d = virt[n] == true
        if not d then
            local ok, v = pcall(function() return pc:IsInputKeyDown(fkey(n)) end)
            d = ok and v == true
        end
        keyNow[n] = d
    end
end
local function rawDown(n) return keyNow[n] == true end
local function rawPressed(n) return keyNow[n] == true and not keyPrev[n] end
local blockInput = false   -- true while the escape menu is open: gameplay sees no keys
local function down(n) return not blockInput and keyNow[n] == true end
local function pressed(n) return not blockInput and keyNow[n] == true and not keyPrev[n] end
local function released(n) return not blockInput and not keyNow[n] and keyPrev[n] == true end
local function axis(pc, n)
    local v = 0
    pcall(function() v = pc:GetInputAnalogKeyState(fkey(n)) or 0 end)
    return v + (virtAxis[n] or 0)
end

------------------------------------------------------------------------------- state
local S = {
    pawn = nil, yaw = 0, pitch = 0, crouch = 0,
    god = false, noclip = false, slow = false, overlay = false, look = true,
    free = { R = { 0, 0, 0 }, L = { 0, 0, 0 } },
    spawned = {},          -- [fullName] = actor we spawned (destroyed on holster)
    rel = nil, relName = nil, relWait = 0,   -- muzzle rotation relative to the right controller
    jab = 0, demo = false,
    fire = { mode = 1, pressedAt = nil, ammo0 = nil, held = false },
    fps = 0, frames = 0, fpsT = 0, now = 0, lastLog = 0, lastText = 0,
    hmdOff = false,
    sel = nil, ads = 0, fovNow = 90, aimFov = nil, popupMsg = nil, inv = {},
}
local FIRE_MODES = { "UseHeldItems", "OnUsed", "FireGun" }
local function slotW() return S.sel and SLOTS[S.sel] and SLOTS[S.sel].w or nil end

local function getTime(world)
    local ok, t = pcall(function() return GS():GetRealTimeSeconds(world) end)
    if ok and type(t) == "number" then return t end
    return os.clock()
end

local function heldObject(ctrl)
    local o
    -- server-side grips are in GrippedObjects, client-authoritative ones in LocallyGrippedObjects
    for _, list in ipairs({ "GrippedObjects", "LocallyGrippedObjects" }) do
        pcall(function()
            local arr = ctrl[list]
            if not o and arr:GetArrayNum() > 0 then o = arr[1].GrippedObject end
        end)
    end
    return valid(o) and o or nil
end
local function heldActor(ctrl)
    local o = heldObject(ctrl)
    if not o then return nil end
    -- GrippedObject is the actor, or one of its components for component grips
    local ok, isActor = pcall(function() return o:IsA(StaticFindObject("/Script/Engine.Actor")) end)
    if ok and isActor then return o end
    local a
    pcall(function() a = o:GetOwner() end)
    return valid(a) and a or o
end

-- camera basis (world): location + quaternion of the view
local function viewBasis()
    local cam = S.cam
    local l = cam:K2_GetComponentLocation()
    local q = rotToQuat(S.pitch, S.yaw, 0)
    return l, q
end

------------------------------------------------------------------------------- pawn setup
local function disableHMD(pc, world)
    local hmd = cdo("/Script/HeadMountedDisplay.Default__HeadMountedDisplayFunctionLibrary")
    local was = "?"
    if hmd then
        pcall(function() was = tostring(hmd:IsHeadMountedDisplayEnabled()) end)
        pcall(function() hmd:EnableHMD(false) end)
    end
    pcall(function() KSL():ExecuteConsoleCommand(world, "stereo off", pc) end)
    S.hmdOff = true
    log("headset switched off (was enabled: " .. was .. ") - desktop view")
end

local function setGameKeys(pc, on)
    local pawn = S.pawn
    if not valid(pawn) then return end
    if on then pcall(function() pawn:EnableInput(pc) end) else pcall(function() pawn:DisableInput(pc) end) end
end

local function captureMouse(pc, on)
    local wbl = cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function() pc.bShowMouseCursor = not on end)
    if wbl then
        if on then pcall(function() wbl:SetInputMode_GameOnly(pc) end)
        else pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false) end) end
    end
end

local function setupPawn(pawn, pc, world)
    S.pawn = pawn
    S.pawnName = fullName(pawn)
    S.cam, S.L, S.R, S.Lactor, S.Ractor = nil, nil, nil, nil, nil
    pcall(function() if valid(pawn.VRReplicatedCamera) then S.cam = pawn.VRReplicatedCamera end end)
    if not S.cam then pcall(function() if valid(pawn.Camera) then S.cam = pawn.Camera end end) end
    pcall(function() if valid(pawn.LeftMotionController) then S.L = pawn.LeftMotionController end end)
    pcall(function() if valid(pawn.RightMotionController) then S.R = pawn.RightMotionController end end)
    -- classic VR template rig (hub pawn BP_VRCharacter): the hands are BP_MotionController actors
    if not S.R then pcall(function() if valid(pawn.RightController) then S.Ractor = pawn.RightController end end) end
    if not S.L then pcall(function() if valid(pawn.LeftController) then S.Lactor = pawn.LeftController end end) end
    S.cm = nil
    pcall(function() if valid(pawn.CharacterMovement) then S.cm = pawn.CharacterMovement end end)
    S.baseSpeed = nil
    pcall(function() S.baseSpeed = S.cm.MaxWalkSpeed end)
    pcall(function() S.yaw = pawn:K2_GetActorRotation().Yaw end)
    S.pitch, S.crouch, S.rel, S.relName = 0, 0, nil, nil
    if CFG.DisableHMD == 1 then disableHMD(pc, world) end
    pcall(function() S.cam.bLockToHmd = false end)
    -- stop real tracking from fighting us (if SteamVR controllers are on)
    for _, c in ipairs({ S.L, S.R }) do
        if c then pcall(function() c:SetTrackingMotionSource(FName("BTDesktop_None")) end) end
    end
    if CFG.BlockGameKeys == 1 then setGameKeys(pc, false) end
    captureMouse(pc, true)
    S.look = true
    S.spawnT = S.now
    if CFG.ScreenPercentage ~= 100 then
        pcall(function() KSL():ExecuteConsoleCommand(world, "r.ScreenPercentage " .. tostring(CFG.ScreenPercentage), pc) end)
    end
    log(string.format("pawn %s  camera=%s  hands=%s/%s  movement=%s  walk speed=%s", S.pawnName,
        S.cam and shortName(S.cam) or "NONE", S.L and "grip-L" or (S.Lactor and "actor-L" or "NONE"),
        S.R and "grip-R" or (S.Ractor and "actor-R" or "NONE"), S.cm and "CharacterMovement" or "none (direct)",
        tostring(S.baseSpeed)))
end

------------------------------------------------------------------------------- grip system
local function emptyTags() return { GameplayTags = {}, ParentTags = {} } end

local function placeAtHand(obj)
    local ctrl = S.R
    local l = ctrl:K2_GetComponentLocation()
    local r = ctrl:K2_GetComponentRotation()
    pcall(function() obj:K2_SetActorLocationAndRotation(l, r, false, {}, true) end)
end

-- Every way the game itself grips something, in order of "most like the real grip button".
-- The first one after which the right controller's GrippedObjects holds the object wins.
local GRIP_METHODS = {
    { "GripOrDropObjectClean", function(pawn, R, L, obj)
        pawn:GripOrDropObjectClean(R, L, false, pawn.GrabSphereRight, emptyTags(), true, {})
    end },
    { "TryToGrabObject", function(pawn, R, L, obj)
        pawn:TryToGrabObject(obj, obj:GetTransform(), R, L, false, { TagName = FName("None") }, FName("None"), false, {})
    end },
    { "GripObjectByInterface", function(pawn, R, L, obj)
        R:GripObjectByInterface(obj, obj:GetTransform(), false, FName("None"), FName("None"), false)
    end },
    -- last resort: a plain rigid grip (AttachmentGrip, late updates off, server-side movement, so it
    -- lands in GrippedObjects where BloodTrail Together looks)
    { "GripObject(attachment)", function(pawn, R, L, obj)
        R:GripObject(obj, obj:GetTransform(), false, FName("None"), FName("None"), 7, 4, 1, 1500, 200, false)
    end },
}

-- Desktop hands teleport every frame; physics grips lag behind and VRExpansion breaks them when the
-- object falls ConstraintBreakDistance behind. Make the object's grips rigid attachments instead.
local function makeRigid(obj)
    if CFG.RigidGrip ~= 1 then return end
    local ok, err = pcall(function()
        local g = obj.VRGripInterfaceSettings
        g.SlotDefaultGripType = 8       -- AttachmentGrip (EGripCollisionType: 7 is ManipulationGripWithWristTwist, a physics grip)
        g.FreeDefaultGripType = 8
        g.ConstraintBreakDistance = 0   -- never break
        g.LateUpdateSetting = 4         -- late updates off
    end)
    local back = "?"
    pcall(function() back = tostring(obj.VRGripInterfaceSettings.FreeDefaultGripType) .. "/" .. tostring(obj.VRGripInterfaceSettings.ConstraintBreakDistance) end)
    if not ok then log("rigid grip settings failed on " .. shortName(obj) .. ": " .. tostring(err)) end
    return back
end
local function gripInfo(ctrl)
    local info
    for _, list in ipairs({ "GrippedObjects", "LocallyGrippedObjects" }) do
        pcall(function()
            local arr = ctrl[list]
            if not info and arr:GetArrayNum() > 0 then info = arr[1] end
        end)
    end
    return info
end
local function rigidAfterGrip(ctrl)
    if CFG.RigidGrip ~= 1 then return end
    local info = gripInfo(ctrl)
    if not info then return end
    local t = -1
    pcall(function() t = info.GripCollisionType end)
    if t ~= 8 then
        local ok, err = pcall(function() ctrl:SetGripCollisionType(info, {}, 8) end)
        pcall(function() t = gripInfo(ctrl).GripCollisionType end)
        log("grip collision type -> " .. tostring(t) .. (ok and "" or (" (" .. tostring(err) .. ")")))
    end
end

local function gripRight(obj)
    local pawn, R, L = S.pawn, S.R, S.L
    if not (R and L and valid(obj)) then return false, "no grip controllers" end
    local rs = makeRigid(obj)
    local errs = {}
    for _, m in ipairs(GRIP_METHODS) do
        placeAtHand(obj)
        local ok, err = pcall(m[2], pawn, R, L, obj)
        local h = heldObject(R)
        local ha = heldActor(R)
        if h and (h == obj or ha == obj or fullName(ha) == fullName(obj) or fullName(h) == fullName(obj)) then
            rigidAfterGrip(R)
            return true, m[1] .. (rs and (", grip settings " .. rs) or "")
        end
        if h then  -- gripped something else (a holstered item next to the hand): let go of it
            pcall(function() R:DropObjectByInterface(h, 0, v3(0, 0, 0), v3(0, 0, 0)) end)
        end
        errs[#errs + 1] = m[1] .. (ok and ":no grip" or (":" .. tostring(err)))
    end
    return false, table.concat(errs, " | ")
end

local function num(v) return type(v) == "number" and v or nil end
local function ammoOf(gun)
    local a, any = 0, false
    pcall(function() local v = num(gun.Ammo) if v then a = a + v any = true end end)
    pcall(function() if valid(gun.MagRef) then local v = num(gun.MagRef.magazineAmmo) if v then a = a + v any = true end end end)
    pcall(function() if any and gun.RoundChambered == true then a = a + 1 end end)
    return any and a or nil
end

-- the weapon plus everything attached to it (magazine, light, suppressor...)
local function weaponParts(actor)
    local parts = { actor }
    pcall(function()
        local att = {}
        actor:GetAttachedActors(att)
        for _, x in ipairs(att) do
            local aa = (type(x) == "userdata" and x.get) and x:get() or x
            if valid(aa) then parts[#parts + 1] = aa end
        end
    end)
    pcall(function() if valid(actor.MagRef) then parts[#parts + 1] = actor.MagRef end end)
    return parts
end
local function stow(actor, hide)
    for _, p in ipairs(weaponParts(actor)) do
        pcall(function() p:SetActorHiddenInGame(hide) end)
        pcall(function() p:SetActorEnableCollision(not hide) end)
    end
    if hide then
        pcall(function() actor:K2_GetRootComponent():SetSimulatePhysics(false) end)
        pcall(function() actor:K2_GetRootComponent():SetEnableGravity(false) end)
        pcall(function()   -- park it out of sight under the player
            local p = S.pawn:K2_GetActorLocation()
            actor:K2_SetActorLocation(v3(p.X, p.Y, p.Z - 2000), false, {}, true)
        end)
    end
end

-- mode "holster": keep the weapon (hidden) for the next time its slot is picked, so no new weapon
-- and no new magazine is spawned and its ammo / fire mode stay as they were.
-- mode "drop": let go into the world (G). mode "destroy": remove it.
local function dropRight(mode)
    if mode == true then mode = "holster" elseif mode == false or mode == nil then mode = "drop" end
    local pawn, R, L = S.pawn, S.R, S.L
    if not R then return false end
    local obj = heldObject(R)
    if not obj then return false end
    local actor = heldActor(R)
    if S.fire.held then pcall(function() pawn:UseHeldItems(R, false) end) S.fire.held = false end
    S.vmGun, S.vm, S.heldName = nil, nil, nil
    pcall(function() local info = gripInfo(R) if info then R:SetGripPaused(info, {}, false, false) end end)
    pcall(function() actor:SetActorEnableCollision(true) end)
    local how = "none"
    pcall(function() pawn:GripOrDropObjectClean(R, L, false, pawn.GrabSphereRight, emptyTags(), false, {}) end)
    if heldObject(R) then
        pcall(function() R:DropObjectByInterface(obj, 0, v3(0, 0, 0), v3(0, 0, 0)) end)
        how = "DropObjectByInterface"
    else
        how = "GripOrDropObjectClean"
    end
    if heldObject(R) then pcall(function() R:DropAllGrips(v3(0, 0, 0), v3(0, 0, 0)) end) how = "DropAllGrips" end
    local name = fullName(actor)
    if mode == "holster" and S.heldFromHolster then
        S.heldFromHolster = false
        pcall(function() actor:K2_GetRootComponent():SetCollisionEnabled(3) end)
        local back = pcall(function() actor:TeleportToHolster() end)
        pcall(function() actor:CompleteHolstering() end)
        log("back into its holster: " .. name .. (back and "" or " (TeleportToHolster missing)"))
    elseif mode == "holster" then
        stow(actor, true)
    elseif mode == "destroy" then
        for _, p in ipairs(weaponParts(actor)) do pcall(function() p:K2_DestroyActor() end) end
        for slot, a in pairs(S.inv) do if a == actor or fullName(a) == name then S.inv[slot] = nil end end
    else
        -- dropped into the world: collision and physics back (a paused grip can leave it without)
        pcall(function()
            local root = actor:K2_GetRootComponent()
            root:SetCollisionEnabled(3)          -- QueryAndPhysics
            root:SetEnableGravity(true)
            root:SetSimulatePhysics(true)
        end)
        for slot, a in pairs(S.inv) do if fullName(a) == name then S.inv[slot] = nil end end
        S.lastDropped, S.lastDroppedActor = name, actor
    end
    log(string.format("%s right hand: %s (%s)", mode, name, how))
    return heldObject(R) == nil
end

-- R: a full magazine / tube, a round in the chamber, slide/bolt forward, ready to fire
local function gunState(gun)
    local t = {}
    for _, k in ipairs({ "CanBeFired", "RoundChambered", "FullyCocked", "BoltLockedBack", "HasSpentShell", "Ammo", "AmmoMAX", "Firingmode", "SliderGripActive", "WasSocketed" }) do
        pcall(function() t[#t + 1] = k .. "=" .. tostring(gun[k]) end)
    end
    pcall(function() local m = gun.MagRef t[#t + 1] = "Mag=" .. (valid(m) and (shortName(m) .. ":" .. tostring(m.magazineAmmo) .. "/" .. tostring(m.MaxAmmo)) or "none") end)
    return table.concat(t, " ")
end
local function reload(gun)
    if not valid(gun) then return nil end
    log("reload state before: " .. gunState(gun))
    local before = ammoOf(gun)
    pcall(function() local m = gun.MagRef if valid(m) then m.magazineAmmo = m.MaxAmmo pcall(function() m:Showbullets() end) end end)
    pcall(function() if num(gun.AmmoMAX) and gun.AmmoMAX > 0 then gun.Ammo = gun.AmmoMAX end end)
    pcall(function() if gun.BoltLockedBack == true then gun.BoltLockedBack = false pcall(function() gun:BoltRelease(false) end) end end)
    pcall(function() if gun.RoundChambered ~= true then pcall(function() gun:chamberround() end) end end)
    pcall(function() gun.RoundChambered = true end)
    pcall(function() gun.FullyCocked = true end)
    pcall(function() gun.CanBeFired = true end)
    pcall(function() gun.HasSpentShell = false end)
    local a = ammoOf(gun)
    log("reload " .. shortName(gun) .. ": ammo " .. tostring(before) .. " -> " .. tostring(a))
    log("reload state after: " .. gunState(gun))
    S.popupMsg = "RELOADED"
    return a
end

local function equip(slot)
    local entry = SLOTS[slot]
    if not entry or not S.R then return false end
    local pc = getPC()
    local world = pc and getWorld(pc)
    if not world then return false end
    if S.sel == slot and heldObject(S.R) then return true end
    if heldObject(S.R) then dropRight("holster") end
    if entry.grenade then
        -- the holster pipe bomb is reclaimed by the game's holster logic; grabbing it made the game and
        -- the mod fight over it until it crashed. This slot just readies a throw (left click).
        if heldObject(S.R) then dropRight("holster") end
        S.sel = slot
        S.popupMsg = string.format("[ %s ]  PIPE BOMB - %s TO THROW", slotKey(slot), keyLabel(B.Fire))
        return true
    end
    if entry.ref then
        -- a weapon from your holsters: take that very one out
        local a
        pcall(function() a = S.pawn[entry.ref] end)
        if not valid(a) then log("equip " .. slot .. ": holster " .. entry.ref .. " is empty") return false end
        local ok, how = gripRight(a)
        if ok then
            S.sel = slot
            S.heldName, S.regrips, S.heldActorRef, S.heldFromHolster = fullName(a), 0, a, true
            S.popupMsg = string.format("[ %s ]  %s", slotKey(slot), entry.name:upper())
            log(string.format("took %s out of the %s holster via %s", shortName(a), entry.label, how))
        else
            log("equip " .. slot .. " " .. entry.name .. ": could not grip (" .. how .. ")")
        end
        return ok
    end
    local w = entry.w
    S.heldFromHolster = false
    local a = S.inv[slot]
    local fresh = false
    if valid(a) then
        stow(a, false)
        local l = S.R:K2_GetComponentLocation()
        pcall(function() a:K2_SetActorLocation(l, false, {}, true) end)
    else
        local cls = loadClass(w[2])
        if not cls then log("equip " .. slot .. " " .. w[1] .. ": class not found " .. w[2]) return false end
        local l = S.R:K2_GetComponentLocation()
        a = spawnActor(world, cls, xform(l.X, l.Y, l.Z, S.R:K2_GetComponentRotation()), 1)
        if not a then log("equip " .. w[1] .. ": spawn failed") return false end
        fresh = true
    end
    local ok, how = gripRight(a)
    if ok then
        S.inv[slot] = a
        S.spawned[fullName(a)] = a
        if fresh then reload(a) end
        S.sel = slot
        S.heldName, S.regrips = fullName(a), 0
        S.popupMsg = string.format("[ %s ]  %s", slotKey(slot), w[1]:upper())
        S.heldActorRef = a
        log(string.format("equipped %d %s (%s) via %s%s", slot, w[1], shortName(a), how, fresh and ", new" or ", from inventory"))
    else
        log(string.format("equip %d %s: could not grip (%s)", slot, w[1], how))
        if fresh then for _, p in ipairs(weaponParts(a)) do pcall(function() p:K2_DestroyActor() end) end
        else stow(a, true) end
    end
    return ok
end

-- B: SEMI -> BURST -> AUTO (the gun's own Firingmode: 1 = semi, 2 = burst, 0 = auto)
local function toggleFireMode()
    local g = heldActor(S.R)
    if not g then return end
    local m
    pcall(function() m = num(g.Firingmode) end)
    if not m then S.popupMsg = "NO FIRE MODES" return end
    local new = ({ [1] = 2, [2] = 0, [0] = 1, [3] = 1 })[m] or 1
    pcall(function() g.Firingmode = new end)
    pcall(function()
        local snd = g.SelectFireSound
        if valid(snd) then GS():PlaySoundAtLocation(getWorld(getPC()), snd, g:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil) end
    end)
    local now
    pcall(function() now = num(g.Firingmode) end)
    S.popupMsg = (({ [0] = "FULL AUTO", [1] = "SEMI AUTO", [2] = "BURST" })[now] or tostring(now)) .. "   [" .. keyLabel(B.FireMode) .. "]"
    log("fire mode " .. tostring(m) .. " -> " .. tostring(now))
end

-- Melee: the swing is a hand animation, so the game's physics hits never happen. Instead the swing
-- traces from the eye and hands the hit to the NPC's own melee damage functions.
local function meleeHit(world)
    local g = heldActor(S.R)
    local cls = g and shortName(g) or "fist"
    local cl, q = viewBasis()
    local fx, fy, fz = qrot(q, 1, 0, 0)
    local hit = {}
    local reach = 190
    local ok, res = pcall(function()
        local c0 = { R = 0, G = 0, B = 0, A = 0 }
        local ignore = { S.pawn }
        if g then ignore[2] = g end
        -- object types Pawn (2) and PhysicsBody (3): NPC capsules and bodies
        return KSL():SphereTraceSingleForObjects(world, cl, v3(cl.X + fx * reach, cl.Y + fy * reach, cl.Z + fz * reach), 16, { 2, 3 }, false,
            ignore, 0, hit, true, c0, c0, 0)
    end)
    if not (ok and res) then log("melee swing: nothing hit" .. (ok and "" or (" (trace error " .. tostring(res) .. ")"))) return end
    local actor
    pcall(function() actor = hit.Actor:Get() end)
    if not valid(actor) then pcall(function() actor = hit.HitObjectHandle.Actor:Get() end) end
    if not valid(actor) then log("melee swing: hit, but no actor in the hit result") return end
    local an = shortName(actor)
    local ip, bone = v3(cl.X + fx * 80, cl.Y + fy * 80, cl.Z + fz * 80), "spine_02"
    pcall(function() ip = v3(hit.ImpactPoint.X, hit.ImpactPoint.Y, hit.ImpactPoint.Z) end)
    pcall(function() bone = hit.BoneName:ToString() end)
    if bone == "None" or bone == "" then   -- hit the capsule: pick head or chest by height
        bone = "spine_02"
        pcall(function() if ip.Z - actor:K2_GetActorLocation().Z > 55 then bone = "head" end end)
    end
    local h = {
        bBlockingHit = true, Location = ip, ImpactPoint = ip,
        Normal = v3(-fx, -fy, -fz), ImpactNormal = v3(-fx, -fy, -fz),
        TraceStart = cl, TraceEnd = v3(cl.X + fx * reach, cl.Y + fy * reach, cl.Z + fz * reach), BoneName = FName(bone),
    }
    local dir = v3(fx, fy, fz)
    local sharp = cls:lower():find("knife") or cls:lower():find("shank") or cls:lower():find("pick") or cls:lower():find("screw")
    local done, err
    if sharp then
        done, err = pcall(function() actor:StabbingDamage(CFG.MeleeDamage * 1.4, dir, h, getPC(), S.pawn, nil) end)
    else
        done, err = pcall(function() actor:BludgeonDamage(h, 900, dir, 2, CFG.MeleeDamage) end)
    end
    log(string.format("melee %s hit %s (%s, bone %s): %s", cls, an, sharp and "stab" or "bludgeon", bone, done and "ok" or tostring(err)))
    local hp0
    pcall(function() hp0 = num(actor.HealthOverall) end)
    S.meleeCheck = { npc = actor, hp0 = hp0, at = S.now + 0.2, hit = h, causer = sharp and "ammo_9mm_b" or "ammo_45cal_b" }
end

-- If the melee function did not hurt the NPC, hand the hit to the NPC's damage event (the path the
-- game's own bullets use; BloodTrail Together relies on it too).
local DAMAGE_TABLE = "/Game/BloodTrailWeapons/Data/DataTables/BT_DamageCauser_DataTable.BT_DamageCauser_DataTable"
local function causerRow(id)
    local dt = StaticFindObject(DAMAGE_TABLE)
    if not valid(dt) then
        pcall(LoadAsset, DAMAGE_TABLE:match("^(.-)%."))
        dt = StaticFindObject(DAMAGE_TABLE)
    end
    if not valid(dt) then return nil end
    local found
    dt:ForEachRow(function(name, row) if not found and tostring(name) == id then found = row end end)
    return found
end
local function meleeFollowUp()
    local m = S.meleeCheck
    S.meleeCheck = nil
    if not (m and valid(m.npc)) then return end
    -- NPCs use a blood-loss model: a registered hit resets TimeSinceLastDamage
    local since, dead
    pcall(function() since = num(m.npc.TimeSinceLastDamage) end)
    pcall(function() dead = m.npc.Dead == true end)
    if dead or (since and since < 0.5) then log(string.format("melee: hit registered by the NPC (%.2f s since damage)", since or -1)) return end
    local row = causerRow(m.causer)
    if not row then log("melee: damage row " .. m.causer .. " not found") return end
    local ok, err = pcall(function() m.npc:EventReceiveDamageNPC(m.hit, row, FName(m.causer), false, true) end)
    local b2
    pcall(function() b2 = num(m.npc.BleedRate) end)
    log("melee: applied through the NPC damage event: " .. (ok and ("bleed rate now " .. tostring(b2)) or tostring(err)))
end

-- H: crack (the game's own heal: inhale crack smoke)
local function useCrack()
    local before
    pcall(function() before = num(S.pawn.PlayerHealth) end)
    local ok, err = pcall(function() S.pawn:InhaleCrackSmoke() end)
    if not ok then ok, err = pcall(function() S.pawn:CrankInCracktime(true) end) end
    S.crackCheck = { at = S.now + 1.5, before = before }
    log("crack: InhaleCrackSmoke " .. (ok and "called" or tostring(err)) .. " (health " .. tostring(before) .. ")")
    S.popupMsg = "CRACK"
end

-- G: grab the grippable thing closest to the line of sight (within 3 m), or drop what you hold
local GRAB_CLASSES = { "SkeletalGun_C", "GrippableSkeletalMeshActor", "GrippableStaticMeshActor", "GrippableActor" }
local function grabNearest()
    if heldObject(S.R) then return dropRight(false) end
    local cl, q = viewBasis()
    local fx, fy, fz = qrot(q, 1, 0, 0)
    local best, bestScore, seen = nil, 1e9, {}
    -- FindAllOf matches the exact class only, so search the concrete weapon classes too, plus the
    -- weapon we dropped last
    local classes = {}
    for _, cn in ipairs(GRAB_CLASSES) do classes[#classes + 1] = cn end
    for _, w in ipairs(WEAPONS) do classes[#classes + 1] = w[2]:match("%.([^.]+)$") end
    local function candidates(cn)
        if cn == "__dropped" then return valid(S.lastDroppedActor) and { S.lastDroppedActor } or {} end
        return FindAllOf(cn) or {}
    end
    classes[#classes + 1] = "__dropped"
    for _, cn in ipairs(classes) do
        for _, a in ipairs(candidates(cn)) do
            local n = valid(a) and fullName(a)
            -- skip things attached to an actor: holstered on our own body (pipe bombs, sidearm) or a
            -- magazine sitting inside a gun - grab the loose item, not its parts
            local onMe = false
            pcall(function()
                local par = a:GetAttachParentActor()
                if valid(par) then
                    local pn = fullName(par)
                    if n == S.lastDropped then log("grab: the dropped " .. shortName(a) .. " is attached to " .. pn) end
                    onMe = pn == S.pawnName or pn:find("SkeletalGun") ~= nil or pn:find("skel") ~= nil or pn:find("Skel") ~= nil
                end
            end)
            if n and not seen[n] and not n:find("Default__") and not onMe then
                seen[n] = true
                pcall(function()
                    local p = a:K2_GetActorLocation()
                    local dx, dy, dz = p.X - cl.X, p.Y - cl.Y, p.Z - cl.Z
                    local along = dx * fx + dy * fy + dz * fz
                    local d2 = dx * dx + dy * dy + dz * dz
                    local perp = math.sqrt(math.max(0, d2 - along * along))
                    if along > 0 and along < 300 and perp < 30 + along * 0.25 then
                        local score = perp + along * 0.2 + (n:find("Mag") and 40 or 0) - (n == S.lastDropped and 60 or 0)
                        if score < bestScore then best, bestScore = a, score end
                    end
                end)
            end
        end
    end
    if not best then
        local extra = ""
        pcall(function()
            local p = S.lastDroppedActor:K2_GetActorLocation()
            local lx, ly, lz = qrot(qconj(q), p.X - cl.X, p.Y - cl.Y, p.Z - cl.Z)
            extra = string.format(" (last dropped %s is at view %.0f %.0f %.0f, world z %.0f)", shortName(S.lastDroppedActor), lx, ly, lz, p.Z)
        end)
        log("grab: nothing grippable in front of you" .. extra)
        return false
    end
    local ok, how = gripRight(best)
    log(string.format("grab %s: %s (%s)", fullName(best), ok and "OK" or "FAILED", how))
    if ok then S.heldName, S.regrips = fullName(best), 0 S.spawned[fullName(best)] = S.spawned[fullName(best)] or nil S.heldActorRef = best end
    if ok then S.relWait = 10 end
    return ok
end

-- left click: the game's own trigger path. Modes are tried in order; if a press does not change the
-- ammo count of a loaded gun, the next mode is used (and logged).
local function fireSet(on)
    local pawn, R = S.pawn, S.R
    local gun = heldActor(R)
    if not gun then return end
    local mode = FIRE_MODES[S.fire.mode]
    local ok, err
    if mode == "UseHeldItems" then
        ok, err = pcall(function() pawn:UseHeldItems(R, on) end)
    elseif mode == "OnUsed" then
        ok, err = pcall(function() if on then gun:OnUsed() else gun:OnEndUsed() end end)
    else
        ok, err = pcall(function() if on then gun:FireGun() else gun:EndFireGun() end end)
    end
    if not ok then log("fire via " .. mode .. " failed: " .. tostring(err)) end
    if on then
        S.fire.pressedAt, S.fire.ammo0, S.fire.gun = S.now, ammoOf(gun), gun
    end
end
local function fireCheck()
    local f = S.fire
    if not f.pressedAt or S.now - f.pressedAt < 0.3 then return end
    local a1 = valid(f.gun) and ammoOf(f.gun) or nil
    if f.ammo0 and a1 and f.ammo0 > 0 then
        if a1 < f.ammo0 then
            if not f.confirmed then log("trigger works via " .. FIRE_MODES[f.mode] .. " (ammo " .. f.ammo0 .. " -> " .. a1 .. ")") end
            f.confirmed = true
        elseif not f.confirmed and f.mode < #FIRE_MODES then
            f.mode = f.mode + 1
            log("trigger: no shot via " .. FIRE_MODES[f.mode - 1] .. ", next press uses " .. FIRE_MODES[f.mode])
        end
    end
    f.pressedAt = nil
end

------------------------------------------------------------------------------- debug helpers
local function setGod(on)
    S.god = on
    pcall(function() S.pawn.Invincible = on end)
    log("god mode " .. (on and "ON" or "OFF"))
end

local function spawnNPC(world)
    local cls = loadClass(NPC_CLASS)
    if not cls then log("NPC class not found") return nil end
    local p = S.pawn:K2_GetActorLocation()
    local yr = S.yaw * DEG
    local x, y = p.X + math.cos(yr) * 350, p.Y + math.sin(yr) * 350
    local a = spawnActor(world, cls, xform(x, y, p.Z + 100, { Pitch = 0, Yaw = S.yaw + 180, Roll = 0 }), 2)
    if not a then log("NPC spawn failed") return nil end
    pcall(function() a:SpawnDefaultController() end)
    log(string.format("spawned NPC %s at (%.0f, %.0f, %.0f)", fullName(a), x, y, p.Z + 100))
    return a
end

local function setNoclip(on)
    S.noclip = on
    pcall(function() S.pawn:SetActorEnableCollision(not on) end)
    pcall(function() S.cm:SetMovementMode(on and 5 or 1, 0) end)   -- 5 = flying, 1 = walking
    log("noclip " .. (on and "ON" or "OFF"))
end

local function setSlow(world, on)
    S.slow = on
    pcall(function() GS():SetGlobalTimeDilation(world, on and 0.25 or 1.0) end)
    log("slow motion " .. (on and "ON (0.25x)" or "OFF"))
end

------------------------------------------------------------------------------- 2D HUD (UMG, screen space)
-- A real 2D HUD: one widget from the game (only used as a host) whose widget tree is replaced by our
-- own canvas with images and text blocks. Screen space, so it never clips into the world, is not
-- lit by the level (no more black HUD in dark maps) and does not depend on night vision.
-- UMG colours are LINEAR (gamma is applied on screen): keep green/blue near zero or reds turn pink
local C_RED = { R = 0.80, G = 0.004, B = 0.008, A = 1 }
local C_DIM = { R = 0.22, G = 0.002, B = 0.004, A = 1 }
local C_WHITE = { R = 0.97, G = 0.95, B = 0.95, A = 1 }
local C_GREY = { R = 0.66, G = 0.62, B = 0.62, A = 1 }
local C_PANEL = { R = 0.015, G = 0.015, B = 0.02, A = 0.80 }
local C_SEL = { R = 0.28, G = 0.002, B = 0.006, A = 0.92 }
local C_SHADE = { R = 0, G = 0, B = 0, A = 0.62 }
local UI_HOSTS = { "/Game/WeaponMaster/UI/WB_AmmoCounter.WB_AmmoCounter_C", "/Game/WeaponMaster/UI/WB_PlayerDataCounter.WB_PlayerDataCounter_C" }
local HUD = nil

local function umg(n) return StaticFindObject("/Script/UMG." .. n) end
local function uiNew(H, cls) return StaticConstructObject(umg(cls), H.tree) end
local function uiPlace(slot, ax, ay, alx, aly, x, y, w, h)
    slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
    slot:SetAlignment({ X = alx, Y = aly })
    slot:SetPosition({ X = x, Y = y })
    if w then slot:SetSize({ X = w, Y = h }) else slot:SetAutoSize(true) end
end
local function uiRect(H, ax, ay, alx, aly, x, y, w, h, color)
    local img = uiNew(H, "Image")
    img:SetColorAndOpacity(color)
    local slot = H.canvas:AddChildToCanvas(img)
    uiPlace(slot, ax, ay, alx, aly, x, y, w, h)
    local e = { w = img, slot = slot, kind = "rect", shown = true, h = h }
    H.all[#H.all + 1] = e
    return e
end
local function uiFill(H, color)   -- full-screen rectangle
    local img = uiNew(H, "Image")
    img:SetColorAndOpacity(color)
    local slot = H.canvas:AddChildToCanvas(img)
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
    slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    local e = { w = img, slot = slot, kind = "rect", shown = true }
    H.all[#H.all + 1] = e
    return e
end
local function uiText(H, ax, ay, alx, aly, x, y, size, color, bold)
    local tb = uiNew(H, "TextBlock")
    pcall(function()
        local f = tb.Font
        f.Size = size
        if bold then f.TypefaceFontName = FName("Bold") end
        tb:SetFont(f)
    end)
    pcall(function() tb:SetShadowOffset({ X = 1.5, Y = 1.5 }) tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
    tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    local slot = H.canvas:AddChildToCanvas(tb)
    uiPlace(slot, ax, ay, alx, aly, x, y)
    local e = { w = tb, slot = slot, kind = "text", shown = true, color = color }
    H.all[#H.all + 1] = e
    return e
end

local textErrLogged = false
local function setText(e, s)
    if not e or e.last == s then return end
    local ok, err = pcall(function() e.w:SetText(FText(s)) end)
    if ok then e.last = s
    elseif not textErrLogged then textErrLogged = true log("HUD text failed: " .. tostring(err)) end
end
local function setColor(e, c)
    if not e or e.color == c then return end
    e.color = c
    if e.kind == "text" then pcall(function() e.w:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end)
    else pcall(function() e.w:SetColorAndOpacity(c) end) end
end
local function hudShow(e, on)
    if not e or e.shown == on then return end
    e.shown = on
    pcall(function() e.w:SetVisibility(on and 3 or 1) end)   -- HitTestInvisible / Collapsed
end
local function setWidth(e, w)
    if not e or e.width == w then return end
    e.width = w
    pcall(function() e.slot:SetSize({ X = w, Y = e.h }) end)
end

local function hudDestroy()
    if not HUD then return end
    pcall(function() HUD.widget:RemoveFromParent() end)
    HUD = nil
end

local MENU_ROWS = 13
local SLOT_W, SLOT_H, SLOT_GAP = 104, 58, 6
local function hudBuild(world, pc)
    hudDestroy()
    local widget, used
    for _, path in ipairs(UI_HOSTS) do
        local cls = loadClass(path)
        if cls then
            pcall(function() widget = cdo("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(world, cls, pc) end)
            if valid(widget) then used = path break end
        end
    end
    if not valid(widget) then log("HUD: no host widget class could be created") return end
    local H = { widget = widget, all = {}, slots = {}, rows = {} }
    H.tree = widget.WidgetTree
    H.canvas = StaticConstructObject(umg("CanvasPanel"), H.tree)
    H.tree.RootWidget = H.canvas
    -- loadout bar (bottom centre)
    local n = #SLOTS
    local total = n * SLOT_W + (n - 1) * SLOT_GAP
    for i, w in ipairs(SLOTS) do
        local x = -total / 2 + (i - 1) * (SLOT_W + SLOT_GAP)
        H.slots[i] = {
            bg = uiRect(H, 0.5, 1, 0, 1, x, -22, SLOT_W, SLOT_H, C_PANEL),
            bar = uiRect(H, 0.5, 1, 0, 1, x, -22 - SLOT_H + 3, SLOT_W, 3, C_RED),
            num = uiText(H, 0.5, 1, 0, 0, x + 8, -22 - SLOT_H + 7, 11, C_DIM, true),
            name = uiText(H, 0.5, 1, 0.5, 1, x + SLOT_W / 2, -30, 13, C_GREY, true),
        }
        H.slots[i].tag = w.tag
        setText(H.slots[i].name, w.name:upper())
    end
    -- ammo (bottom right)
    H.ammoBg = uiRect(H, 1, 1, 1, 1, -22, -22, 240, 104, C_PANEL)
    H.ammoEdge = uiRect(H, 1, 1, 1, 1, -22 - 236, -22, 4, 104, C_RED)
    H.gunName = uiText(H, 1, 1, 1, 0, -36, -22 - 96, 13, C_WHITE, true)
    H.mode = uiText(H, 1, 1, 0, 0, -22 - 220, -22 - 96, 12, C_RED, true)
    H.bullets = uiText(H, 1, 1, 1, 0, -36, -22 - 70, 9, C_RED, true)
    H.ammo = uiText(H, 1, 1, 1, 1, -100, -28, 32, C_RED, true)
    H.ammoMax = uiText(H, 1, 1, 0, 1, -94, -36, 15, C_GREY, true)
    -- health (bottom left)
    H.hpBg = uiRect(H, 0, 1, 0, 1, 22, -22, 270, 64, C_PANEL)
    H.hpEdge = uiRect(H, 0, 1, 0, 1, 22, -22, 4, 64, C_RED)
    H.hpNum = uiText(H, 0, 1, 0, 1, 40, -50, 22, C_RED, true)
    H.hpBarBg = uiRect(H, 0, 1, 0, 1, 40, -34, 230, 6, { R = 0.12, G = 0.02, B = 0.03, A = 0.9 })
    H.hpBar = uiRect(H, 0, 1, 0, 1, 40, -34, 230, 6, C_RED)
    -- white crosshair: four short lines around the centre
    H.cross = {
        uiRect(H, 0.5, 0.5, 1, 0.5, -4, 0, 9, 2, C_WHITE),
        uiRect(H, 0.5, 0.5, 0, 0.5, 4, 0, 9, 2, C_WHITE),
        uiRect(H, 0.5, 0.5, 0.5, 1, 0, -4, 2, 9, C_WHITE),
        uiRect(H, 0.5, 0.5, 0.5, 0, 0, 4, 2, 9, C_WHITE),
    }
    -- popup, flags, debug text
    H.popup = uiText(H, 0.5, 1, 0.5, 1, 0, -100, 20, C_WHITE, true)
    H.flags = uiText(H, 1, 0, 1, 0, -24, 18, 16, C_RED, true)
    H.debug = uiText(H, 0, 0, 0, 0, 20, 16, 12, C_GREY, false)
    -- escape menu (hidden until Esc)
    H.menu = { rows = {} }
    H.menu.shade = uiFill(H, C_SHADE)
    H.menu.panel = uiRect(H, 0.5, 0.5, 0.5, 0.5, 0, 0, 640, 680, C_PANEL)
    H.menu.edge = uiRect(H, 0.5, 0.5, 0.5, 0.5, -318, 0, 4, 680, C_RED)
    H.menu.title = uiText(H, 0.5, 0.5, 0.5, 0, 0, -310, 34, C_RED, true)
    H.menu.sub = uiText(H, 0.5, 0.5, 0.5, 0, 0, -262, 13, C_GREY, true)
    H.menu.vals, H.menu.arrL, H.menu.arrR = {}, {}, {}
    for i = 1, MENU_ROWS do
        H.menu.rows[i] = uiText(H, 0.5, 0.5, 0, 0, -280, -220 + (i - 1) * 38, 17, C_GREY, true)
        H.menu.vals[i] = uiText(H, 0.5, 0.5, 0.5, 0, 205, -220 + (i - 1) * 38, 17, C_GREY, true)
        H.menu.arrL[i] = uiText(H, 0.5, 0.5, 0.5, 0, 112, -222 + (i - 1) * 38, 20, C_RED, true)
        H.menu.arrR[i] = uiText(H, 0.5, 0.5, 0.5, 0, 298, -222 + (i - 1) * 38, 20, C_RED, true)
        setText(H.menu.arrL[i], "<")
        setText(H.menu.arrR[i], ">")
    end
    H.menu.hint = uiText(H, 0.5, 0.5, 0.5, 0, 0, 316, 11, C_DIM, true)
    -- radio timeline (menu radio pages): click on it to jump in the song
    H.rbar = {
        bg = uiRect(H, 0.5, 0.5, 0, 0.5, -280, 286, 560, 8, { R = 0.12, G = 0.02, B = 0.03, A = 0.95 }),
        fill = uiRect(H, 0.5, 0.5, 0, 0.5, -280, 286, 1, 8, C_RED),
        l = uiText(H, 0.5, 0.5, 0, 0, -280, 293, 11, C_GREY, true),
        r = uiText(H, 0.5, 0.5, 1, 0, 280, 293, 11, C_GREY, true),
    }
    H.rbar.fill.h = 8
    -- now playing (above the ammo panel)
    H.np = {
        bg = uiRect(H, 1, 1, 1, 1, -22, -136, 240, 62, C_PANEL),
        edge = uiRect(H, 1, 1, 1, 1, -22 - 236, -136, 4, 62, C_RED),
        tag = uiText(H, 1, 1, 0, 0, -22 - 222, -136 - 58, 10, C_RED, true),
        title = uiText(H, 1, 1, 1, 0, -34, -136 - 44, 13, C_WHITE, true),
        artist = uiText(H, 1, 1, 1, 0, -34, -136 - 26, 10, C_GREY, true),
        barBg = uiRect(H, 1, 1, 0, 1, -22 - 222, -142, 196, 3, { R = 0.12, G = 0.02, B = 0.03, A = 0.95 }),
        bar = uiRect(H, 1, 1, 0, 1, -22 - 222, -142, 1, 3, C_RED),
        time = uiText(H, 1, 1, 1, 0, -34, -136 - 58, 10, C_GREY, true),
    }
    H.np.bar.h = 3
    setText(H.menu.title, "BTDESKTOP")
    setText(H.menu.hint, "W/S: CHOOSE   A/D OR LMB/RMB: CHANGE   ENTER: SELECT   ESC: BACK")
    local function showMenu(on)
        for k, e in pairs(H.menu) do
            if k == "rows" or k == "vals" or k == "arrL" or k == "arrR" then for _, r in ipairs(e) do hudShow(r, on and (k == "rows" or k == "vals")) end else hudShow(e, on) end
        end
    end
    H.showMenu = showMenu
    pcall(function() widget:AddToViewport(20) end)
    pcall(function() widget:SetVisibility(3) end)
    showMenu(S.menu ~= nil)
    H.popupUntil = 0
    HUD = H
    log(string.format("2D HUD built (%d elements, host %s)", #H.all, used:match("([^.]+)$")))
end

local function statusLine()
    local p = S.pawn:K2_GetActorLocation()
    local r = heldActor(S.R)
    local hp = "?"
    pcall(function() hp = string.format("%.0f/%.0f", S.pawn.PlayerHealth, S.pawn.playerhealthmax) end)
    local ra = r and ammoOf(r)
    local lh = ""
    pcall(function()
        local cl, q = viewBasis()
        local l = S.L:K2_GetComponentLocation()
        local x, y, z = qrot(qconj(q), l.X - cl.X, l.Y - cl.Y, l.Z - cl.Z)
        local vis = "?"
        pcall(function() vis = tostring(S.pawn["HandMesh-Left"]:IsVisible()) end)
        lh = string.format("  Lhand(view) %.0f %.0f %.0f mesh visible %s", x, y, z, vis)
    end)
    return string.format("pos %.0f %.0f %.0f  yaw %.0f pitch %.0f  fps %.0f  hp %s\nR: %s%s%s\ngod %s  noclip %s  slow %s  fov %.0f",
        p.X, p.Y, p.Z, S.yaw % 360, S.pitch, S.fps, hp, r and shortName(r) or "-", ra and (" ammo " .. ra) or "", lh,
        S.god and "ON" or "off", S.noclip and "ON" or "off", S.slow and "ON" or "off", S.fovNow or 0)
end

local function magOf(gun)
    local cur, max
    pcall(function() if valid(gun.MagRef) then cur, max = num(gun.MagRef.magazineAmmo), num(gun.MagRef.MaxAmmo) end end)
    if not cur then pcall(function() cur, max = num(gun.Ammo), num(gun.AmmoMAX) end) end
    local ch = 0
    pcall(function() if gun.RoundChambered == true then ch = 1 end end)
    return cur, max, ch
end

-- measured on the AK (rounds per 0.6 s of trigger): 0 = full auto, 1 = semi, 2 = 3-round burst
local FIRE_MODE_NAMES = { [0] = "AUTO", [1] = "SEMI", [2] = "BURST", [3] = "SINGLE" }
local function hudUpdate(world, pc)
    if CFG.Hud ~= 1 then if HUD then hudDestroy() end return end
    if not HUD or not valid(HUD.widget) then hudBuild(world, pc) end
    local H = HUD
    if not H then return end
    for i, s in ipairs(H.slots) do
        local sel = S.sel == i
        setColor(s.bg, sel and C_SEL or C_PANEL)
        hudShow(s.bar, sel)
        setColor(s.num, sel and C_RED or C_DIM)
        setColor(s.name, sel and C_WHITE or C_GREY)
        setText(s.num, slotKey(i) .. (s.tag and ("  " .. s.tag) or ""))
    end
    local gun = heldActor(S.R)
    local cur, max, ch
    if gun then cur, max, ch = magOf(gun) end
    for _, e in ipairs({ H.ammoBg, H.ammoEdge, H.gunName, H.ammo, H.ammoMax, H.bullets, H.mode }) do hudShow(e, gun ~= nil) end
    if gun then
        setText(H.gunName, ((S.sel and SLOTS[S.sel]) and SLOTS[S.sel].name or prettyClass(shortName(gun))):upper())
        if cur then
            setText(H.ammo, tostring(cur + (ch or 0)))
            setText(H.ammoMax, "/ " .. tostring(max or "?"))
            setText(H.bullets, string.rep("I", math.min(cur, 30)) .. ((cur > 30) and "+" or ""))
            setColor(H.ammo, (cur + (ch or 0) == 0) and C_DIM or C_RED)
            local m
            pcall(function() m = num(gun.Firingmode) end)
            setText(H.mode, m and ((FIRE_MODE_NAMES[m] or tostring(m)) .. "  [" .. keyLabel(B.FireMode) .. "]") or "")
        else
            setText(H.ammo, "--") setText(H.ammoMax, "MELEE") setText(H.bullets, "") setText(H.mode, "")
        end
    end
    local hp, hpMax
    pcall(function() hp, hpMax = num(S.pawn.PlayerHealth), num(S.pawn.playerhealthmax) end)
    if hp and hpMax and hpMax > 0 then
        setText(H.hpNum, string.format("+ %d", math.floor(hp + 0.5)))
        setWidth(H.hpBar, math.floor(230 * clamp(hp / hpMax, 0, 1) + 0.5))
    end
    for _, c in ipairs(H.cross) do hudShow(c, not S.menu and CFG.Crosshair == 1) end
    local r = S.radio
    local npOn = r ~= nil and (r.mode == "playing" or r.mode == "paused") and (r.title or "") ~= ""
    for _, e in pairs(H.np) do hudShow(e, npOn) end
    if npOn then
        setText(H.np.tag, r.mode == "paused" and "RADIO - PAUSED" or "RADIO - NOW PLAYING")
        setText(H.np.title, r.title:upper():sub(1, 24))
        setText(H.np.artist, (r.artist ~= "" and r.artist or "UNKNOWN ARTIST"):upper():sub(1, 30))
        local s1, s2 = math.floor(r.pos / 1000), math.floor(r.len / 1000)
        setText(H.np.time, string.format("%d:%02d / %d:%02d", s1 // 60, s1 % 60, s2 // 60, s2 % 60))
        setWidth(H.np.bar, math.max(1, math.floor(196 * ((r.len > 0) and clamp(r.pos / r.len, 0, 1) or 0) + 0.5)))
    end
    local barOn = S.menu ~= nil and S.menu.bar == true and r ~= nil and r.len > 0
    for _, e in pairs(H.rbar) do hudShow(e, barOn) end
    if barOn then
        setWidth(H.rbar.fill, math.max(1, math.floor(560 * clamp(r.pos / r.len, 0, 1) + 0.5)))
        local s1, s2 = math.floor(r.pos / 1000), math.floor(r.len / 1000)
        setText(H.rbar.l, string.format("%d:%02d   CLICK THE BAR TO JUMP", s1 // 60, s1 % 60))
        setText(H.rbar.r, string.format("%d:%02d", s2 // 60, s2 % 60))
    end
    hudShow(H.popup, S.now < H.popupUntil)
    local f = {}
    if S.god then f[#f + 1] = "GOD" end
    if S.noclip then f[#f + 1] = "NOCLIP" end
    if S.slow then f[#f + 1] = "SLOW-MO" end
    setText(H.flags, table.concat(f, "   "))
    hudShow(H.debug, S.overlay)
    if S.overlay and S.now - S.lastText > 0.25 then S.lastText = S.now setText(H.debug, statusLine()) end
end
local function hudPopup(s)
    if HUD then setText(HUD.popup, s) HUD.popupUntil = S.now + 1.3 end
end

------------------------------------------------------------------------------- hands / viewmodel
local function setCtrl(ctrl, actor, loc, rot)
    if ctrl then
        pcall(function() ctrl:K2_SetWorldLocationAndRotation(loc, rot, false, {}, true) end)
    elseif actor then
        pcall(function() actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    end
end

-- shortest rotation turning direction u into direction v
local function fromTo(ux, uy, uz, vx, vy, vz)
    local lu = math.sqrt(ux * ux + uy * uy + uz * uz)
    local lv = math.sqrt(vx * vx + vy * vy + vz * vz)
    if lu < 1e-6 or lv < 1e-6 then return { 0, 0, 0, 1 } end
    ux, uy, uz, vx, vy, vz = ux / lu, uy / lu, uz / lu, vx / lv, vy / lv, vz / lv
    local d = ux * vx + uy * vy + uz * vz
    if d < -0.9999 then return { 0, 0, 1, 0 } end
    return qnormalize({ uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx, 1 + d })
end

-- Real shot direction. The game's bullets are pooled "InstantHit" actors; right after a shot the
-- one that moved tells where the round really went. Averaged per gun class in the gun's own space,
-- so the muzzle can be turned to put rounds exactly on the crosshair.
local BULLET_CLASSES = { "BP_9mm_B_InstantHit_C", "BP_9mm_HP_InstantHit_C", "BP_5_45_InstantHit_C", "BP_5_56_FMJ_InstantHit_C",
    "BP_45_ACP_InstantHit_C", "BP_40sw_InstantHit_C", "BP_AR10_InstantHit_C", "BP_Buckshot_InstantHit_C" }
S.calib = {}
local function bulletSnapshot()
    local snap = {}
    for _, cn in ipairs(BULLET_CLASSES) do
        for _, a in ipairs(FindAllOf(cn) or {}) do
            pcall(function()
                local n = fullName(a)
                if not n:find("Default__") then
                    local l = a:K2_GetActorLocation()
                    snap[n] = { l.X, l.Y, l.Z, a }
                end
            end)
        end
    end
    return snap
end
local function calibrateFromShot(p)
    local gun = p.gun
    if not valid(gun) then return end
    local fd = gun.FireDirection
    local start = fd:K2_GetComponentLocation()
    local best, bestD
    for n, old in pairs(p.snap) do
        pcall(function()
            local a = old[4]
            local l = a:K2_GetActorLocation()
            local moved = math.abs(l.X - old[1]) + math.abs(l.Y - old[2]) + math.abs(l.Z - old[3])
            if moved > 1 then
                local d = math.sqrt((l.X - start.X) ^ 2 + (l.Y - start.Y) ^ 2 + (l.Z - start.Z) ^ 2)
                if not bestD or d < bestD then best, bestD = { a, l }, d end
            end
        end)
    end
    if not best then log("aim calibration: no bullet found for this shot") return end
    local dx, dy, dz
    if bestD < 150 then
        dx, dy, dz = qrot(rq(best[1]:K2_GetActorRotation()), 1, 0, 0)   -- bullet still at the muzzle: its facing
    else
        dx, dy, dz = best[2].X - start.X, best[2].Y - start.Y, best[2].Z - start.Z   -- bullet at the hit point
    end
    local gq = rq(gun:K2_GetRootComponent():K2_GetComponentRotation())
    local lx, ly, lz = qrot(qconj(gq), dx, dy, dz)
    local n = math.sqrt(lx * lx + ly * ly + lz * lz)
    if n < 1e-6 then return end
    local cls = shortName(gun)
    local c = S.calib[cls] or { 0, 0, 0, 0 }
    c = { c[1] + lx / n, c[2] + ly / n, c[3] + lz / n, c[4] + 1 }
    S.calib[cls] = c
    -- how far off was this shot from the muzzle arrow?
    local fx, fy, fz = qrot(rq(fd:K2_GetComponentRotation()), 1, 0, 0)
    local dn = math.sqrt(dx * dx + dy * dy + dz * dz)
    local err = math.deg(math.acos(clamp((fx * dx + fy * dy + fz * dz) / dn, -1, 1)))
    log(string.format("aim calibration %s: shot %d was %.2f deg off the muzzle arrow (bullet %.0f cm away)", cls, c[4], err, bestD))
    S.vmGun = nil   -- rebuild the viewmodel with the new calibration
end

-- The game's visible gloves are physics actors (GraspingHand) that chase the controllers and get
-- left behind or fly off when the mod moves the controllers. Instead: the pawn's own hand meshes
-- (HandMesh-Left/Right, rigidly attached to the controllers, hidden by the game) are shown, and the
-- physics gloves are pinned to the controllers, invisible, so their touch colliders still press
-- buttons where your hand is.
local function handsSetup()
    local pawn = S.pawn
    for _, side in ipairs({ { "GraspingHandRight", S.R }, { "GraspingHandLeft", S.L } }) do
        pcall(function()
            local h = pawn[side[1]]
            if not valid(h) or not side[2] then return end
            local root = h:K2_GetRootComponent()
            pcall(function() root:SetSimulatePhysics(false) end)
            local par
            pcall(function() par = root:GetAttachParent() end)
            if not (valid(par) and fullName(par) == fullName(side[2])) then
                pcall(function() h:K2_AttachToComponent(side[2], FName("None"), 2, 2, 1, false) end)   -- snap to the controller
            end
            pcall(function() h:SetActorHiddenInGame(CFG.ShowGloves ~= 1 or S.gunHandsOn == true) end)
            pcall(function() h:SetActorEnableCollision(S.touch ~= nil) end)
        end)
    end
end
local function glovesHidden(hide)
    for _, k in ipairs({ "GraspingHandRight", "GraspingHandLeft" }) do
        pcall(function() S.pawn[k]:SetActorHiddenInGame(hide) end)
    end
end
-- every weapon carries hand meshes posed by the game's artists: the gripping hand (MainHandMesh) and
-- the support hand on the handguard / pump / under the pistol grip (OffHandMeshL). Show those instead of
-- the loose gloves: the hands then sit exactly right on every gun.
local function gunHandsShow(gun, on)
    local function hasMesh(c)
        local ok = false
        pcall(function() ok = valid(c) and valid(c.SkeletalMesh) end)
        return ok
    end
    local shown = false
    for _, k in ipairs({ "MainHandMesh", "OffHandMeshL" }) do
        pcall(function()
            local c = gun[k]
            if hasMesh(c) then
                c:SetVisibility(on, true)
                c:SetHiddenInGame(not on, true)
                if on then shown = true end
            end
        end)
    end
    for _, k in ipairs({ "OffHandMeshR", "BoltHandMeshR", "BoltHandMeshL" }) do
        pcall(function() local c = gun[k] if valid(c) then c:SetVisibility(false, true) c:SetHiddenInGame(true, true) end end)
    end
    return shown
end
local function glovesCollide(on)
    for _, k in ipairs({ "GraspingHandRight", "GraspingHandLeft" }) do
        pcall(function() S.pawn[k]:SetActorEnableCollision(on) end)
    end
end
S.handShown = {}
local function showHandMesh(name, on)
    if S.handShown[name] == on then return end
    S.handShown[name] = on
    pcall(function()
        local m = S.pawn[name]
        m:SetVisibility(on, true)
        m:SetHiddenInGame(not on, true)
    end)
end

-- controllers are posed in the space of their parent (the pawn's NetSmoother, also the camera's
-- parent), so they move with the body in the same frame: no lag, no jitter while walking
local function setCtrlRel(ctrl, p, q)
    pcall(function() ctrl:K2_SetRelativeLocationAndRotation(v3(p[1], p[2], p[3]), quatToRot(q), false, {}, true) end)
end
-- camera space -> parent space
local function camToParent(p, q)
    local cp, cq = S.camRelP, S.camRelQ
    local x, y, z = qrot(cq, p[1], p[2], p[3])
    return { cp[1] + x, cp[2] + y, cp[3] + z }, qmul(cq, q)
end
-- world -> parent space (for touching a point in the world)
local function worldToParent(w)
    local ok, r = pcall(function()
        local pt = S.R:GetAttachParent():K2_GetComponentToWorld()
        local pq = { pt.Rotation.X, pt.Rotation.Y, pt.Rotation.Z, pt.Rotation.W }
        return { qrot(qconj(pq), w.X - pt.Translation.X, w.Y - pt.Translation.Y, w.Z - pt.Translation.Z) }
    end)
    return ok and r or nil
end

local function lerp3(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
-- rotation of ang degrees about the unit axis a
local function qaxis(ax, ay, az, ang)
    local h = ang * DEG / 2
    local sn = math.sin(h)
    return { ax * sn, ay * sn, az * sn, math.cos(h) }
end
-- turn q about its own muzzle axis (fw = muzzle direction in camera space) so the weapon's top points up
local function levelGun(q, fw)
    local ux, uy, uz = qrot(q, 0, 0, 1)
    local fx, fy, fz = fw[1], fw[2], fw[3]
    -- wanted up: camera up with the muzzle direction removed
    local d = fz
    local wx, wy, wz = -d * fx, -d * fy, 1 - d * fz
    local dn = math.sqrt(wx * wx + wy * wy + wz * wz)
    local du = ux * fx + uy * fy + uz * fz
    ux, uy, uz = ux - du * fx, uy - du * fy, uz - du * fz
    local un = math.sqrt(ux * ux + uy * uy + uz * uz)
    if dn < 1e-4 or un < 1e-4 then return q end
    wx, wy, wz, ux, uy, uz = wx / dn, wy / dn, wz / dn, ux / un, uy / un, uz / un
    local cs = ux * wx + uy * wy + uz * wz
    local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
    local sn = cx * fx + cy * fy + cz * fz
    local ang = math.atan(sn, cs) / DEG
    return qnormalize(qmul(qaxis(fx, fy, fz, ang), q))
end
local function qlookLocal(from, to)
    local tx, ty, tz = to[1] - from[1], to[2] - from[2], to[3] - from[3]
    return rotToQuat(math.atan(tz, math.sqrt(tx * tx + ty * ty)) * RAD, math.atan(ty, tx) * RAD, 0)
end

-- the game turns the gloves' physics back on when it re-grips a weapon (e.g. after a shot): then the
-- glove, and the weapon it holds, drift away. Pin them back the moment they leave the controller.
local function pinGloves()
    for _, side in ipairs({ { "GraspingHandRight", S.R }, { "GraspingHandLeft", S.L } }) do
        pcall(function()
            local h = S.pawn[side[1]]
            if not valid(h) or not side[2] then return end
            local root = h:K2_GetRootComponent()
            local hl, cl = root:K2_GetComponentLocation(), side[2]:K2_GetComponentLocation()
            local d = math.abs(hl.X - cl.X) + math.abs(hl.Y - cl.Y) + math.abs(hl.Z - cl.Z)
            if d > 2 or root:IsSimulatingPhysics() then
                root:SetSimulatePhysics(false)
                h:K2_AttachToComponent(side[2], FName("None"), 2, 2, 1, false)
                if d > 20 then log(string.format("%s was %.0f cm away - pinned back", side[1], d)) end
            end
        end)
    end
end
local function updateHands(dt, mx, my, moving)
    pinGloves()
    local a = S.ads
    local sprinting = moving and down(B.Sprint) and a < 0.1 and not down(B.Fire) and not down(B.Crouch)
    S.sprintK = (S.sprintK or 0) + ((sprinting and 1 or 0) - (S.sprintK or 0)) * math.min(1, dt * 8)
    -- weapon bob: the gun trails the camera bob a little (less when aiming)
    local bt = S.camBobT or 0
    local bk = (S.camBob or 0) / math.max(0.01, CFG.ViewBob) * (1 - 0.9 * a)
    local gbx, gby, gbz = 0, 0, 0   -- the weapon is fixed in the view: it only moves with the camera
    local gun = heldActor(S.R)
    local fd
    if gun then pcall(function() if valid(gun.FireDirection) then fd = gun.FireDirection end end) end
    -- parent-space poses (body space) for both hands; filled below
    local pR, qR, pL, qL
    local eye = CFG.EyeHeight - S.crouch
    -- unarmed: hands down by your sides
    local sideR, sideL = { 8, 24, eye - 78 }, { 8, -24, eye - 78 }
    local downQ = rotToQuat(-70, 0, 0)

    if gun and CFG.RigidGrip == 1 then
        local gname = fullName(gun)
        if S.vmGun ~= gname then
            if S.gunHandsActor and valid(S.gunHandsActor) then pcall(gunHandsShow, S.gunHandsActor, false) end
            S.gunHandsActor, S.gunHandsOn = nil, false
            S.vmGun, S.vm, S.equipT, S.equipDiag = gname, nil, S.now, false
            local ok, err = pcall(function()
                local root = gun:K2_GetRootComponent()
                pcall(function() root:SetSimulatePhysics(false) end)
                pcall(function() root:SetEnableGravity(false) end)
                local info = gripInfo(S.R)
                if info then pcall(function() S.R:SetGripPaused(info, {}, true, true) end) end
                pcall(function() gun:SetActorEnableCollision(false) end)
                local gt = root:K2_GetComponentToWorld()
                local igq = qconj({ gt.Rotation.X, gt.Rotation.Y, gt.Rotation.Z, gt.Rotation.W })
                local mRot, mPos = { 0, 0, 0, 1 }, { 0, 0, 0 }
                if fd then
                    local ft = fd:K2_GetComponentToWorld()
                    mRot = qmul(igq, { ft.Rotation.X, ft.Rotation.Y, ft.Rotation.Z, ft.Rotation.W })
                    mPos = { qrot(igq, ft.Translation.X - gt.Translation.X, ft.Translation.Y - gt.Translation.Y, ft.Translation.Z - gt.Translation.Z) }
                    local c = S.calib[shortName(gun)]
                    if CFG.AimCalibrate == 1 and c and c[4] > 0 then
                        local ax, ay, az = qrot(mRot, 1, 0, 0)
                        mRot = qmul(fromTo(ax, ay, az, c[1], c[2], c[3]), mRot)
                    end
                end
                S.vm = { rot = mRot, pos = mPos, len = math.sqrt(mPos[1] ^ 2 + mPos[2] ^ 2 + mPos[3] ^ 2),
                    melee = fd == nil, level = fd == nil and ammoOf(gun) ~= nil }
                -- where the game's artists put the support hand on this weapon (OffHandMeshL, never shown:
                -- showing it makes the game drop the weapon), in weapon space
                pcall(function()
                    local oh = gun.OffHandMeshL
                    if valid(oh) and valid(oh.SkeletalMesh) then
                        local ot = oh:K2_GetComponentToWorld()
                        S.vm.oh = { p = { qrot(igq, ot.Translation.X - gt.Translation.X, ot.Translation.Y - gt.Translation.Y, ot.Translation.Z - gt.Translation.Z) },
                            q = qmul(igq, { ot.Rotation.X, ot.Rotation.Y, ot.Rotation.Z, ot.Rotation.W }) }
                    end
                end)
                -- the game's rigid AttachmentGrip keeps the weapon on the right controller; the controller
                -- is posed in body space every frame, so the weapon moves with the view in the same frame
            end)
            if not ok then log("viewmodel setup failed: " .. tostring(err)) end
        end
        if S.vm then
            local vm = S.vm
            local w = slotW()
            local gq, gp   -- weapon pose in CAMERA space
            local hip = { 31 + gbx, 10 + gby, -13 + gbz }
            if S.jab > 0 then
                S.jab = math.max(0, S.jab - dt)
                local j = math.sin((1 - S.jab / 0.3) * math.pi)
                hip = { hip[1] + 35 * j, hip[2] - 8 * j, hip[3] + 10 * j }
            end
            if vm.melee then
                -- melee: held low on the right, blade / bat angled forward and away from the view
                gq = rotToQuat(vm.level and 0 or 25, -10, 0)
                gp = { 40 + (hip[1] - 31), 22 + (hip[2] - 10), -26 + (hip[3] + 13) }
            else
                -- the muzzle points at the spot under the crosshair (camera trace, smoothed), so rounds
                -- land on the crosshair; aiming: sights (SightHeight above the bore) on the crosshair
                -- zeroed at a fixed distance: the weapon never swings with what is under the crosshair
                local d = CFG.ZeroDistance
                local aimPt = { d, 0, 0 }
                local sightH, sightX = (w and w[5]) or 3, (w and w[6]) or 0
                local m = { CFG.AimGunDistance + vm.len, sightX, -sightH }
                local gqHip = qmul(qlookLocal(hip, aimPt), qconj(vm.rot))
                do   -- refine: look from where the muzzle actually is
                    local mx_, my_, mz_ = qrot(gqHip, vm.pos[1], vm.pos[2], vm.pos[3])
                    gqHip = qmul(qlookLocal({ hip[1] + mx_, hip[2] + my_, hip[3] + mz_ }, aimPt), qconj(vm.rot))
                end
                local gqAds = qmul(qlookLocal(m, aimPt), qconj(vm.rot))
                -- level both poses: the weapon's top points up (no cant / slant)
                do
                    local function fw(qq) local x, y, z = qrot(qmul(qq, vm.rot), 1, 0, 0) return { x, y, z } end
                    gqHip = levelGun(gqHip, fw(gqHip))
                    gqAds = levelGun(gqAds, fw(gqAds))
                end
                gq = (a > 0.001) and qnormalize(qmul(gqHip, qpow(qmul(qconj(gqHip), gqAds), a))) or gqHip
                local ox, oy, oz = qrot(gqAds, vm.pos[1], vm.pos[2], vm.pos[3])
                local pAds = { m[1] - ox, m[2] - oy, m[3] - oz }
                gp = lerp3(hip, pAds, a)
                -- sprint: weapon lowered and turned in (military low-ready)
                -- reload: the weapon dips down and rolls in, then comes back up
                local ra = S.reloadAnim
                if ra then
                    local e = S.now - ra.t0
                    local k = (e < 0.25) and (e / 0.25) or ((e < 0.8) and 1 or math.max(0, 1 - (e - 0.8) / 0.3))
                    k = k * k * (3 - 2 * k)
                    gq = qmul(rotToQuat(-28 * k, 6 * k, -28 * k), gq)
                    gp = { gp[1] - 4 * k, gp[2] - 2 * k, gp[3] - 8 * k }
                end
            end
            -- The game keeps the weapon attached to the controller with its own grip offset (and may
            -- re-apply it). Instead of fighting that, read the offset and pose the controller so the
            -- weapon lands exactly where it should: controller = weapon * inverse(offset).
            -- offset of the weapon from the controller, measured from both world transforms at the same
            -- moment (works whatever chain the game holds it by: controller, hand, grip slot)
            -- The weapon is attached to the right controller (AttachmentGrip): read its offset every frame
            -- (exact, nothing to go stale after a weapon switch) and pose the controller so the weapon lands
            -- on its camera-space pose. If it is not on the controller (yet), place the weapon directly.
            local tp, tq
            pcall(function()
                local root = gun:K2_GetRootComponent()
                -- the game attaches it to the hand's grab sphere or glove, both rigid children of the right
                -- controller: the offset measured from the two world transforms is exact and lag-free
                if valid(root:GetAttachParent()) then
                    local ct = S.R:K2_GetComponentToWorld()
                    local gt = root:K2_GetComponentToWorld()
                    local ic = qconj({ ct.Rotation.X, ct.Rotation.Y, ct.Rotation.Z, ct.Rotation.W })
                    tp = { qrot(ic, gt.Translation.X - ct.Translation.X, gt.Translation.Y - ct.Translation.Y, gt.Translation.Z - ct.Translation.Z) }
                    tq = qmul(ic, { gt.Rotation.X, gt.Rotation.Y, gt.Rotation.Z, gt.Rotation.W })
                end
            end)
            if S.equipT and not S.equipDiag and S.now - S.equipT > 0.6 then
                S.equipDiag = true
                pcall(function()
                    local root = gun:K2_GetRootComponent()
                    local par = root:GetAttachParent()
                    local ct = S.R:K2_GetComponentToWorld()
                    local gt = root:K2_GetComponentToWorld()
                    local ic = qconj({ ct.Rotation.X, ct.Rotation.Y, ct.Rotation.Z, ct.Rotation.W })
                    local np = { qrot(ic, gt.Translation.X - ct.Translation.X, gt.Translation.Y - ct.Translation.Y, gt.Translation.Z - ct.Translation.Z) }
                    local nq = qmul(ic, { gt.Rotation.X, gt.Rotation.Y, gt.Rotation.Z, gt.Rotation.W })
                    local sock = "-"
                    pcall(function() sock = root:GetAttachSocketName():ToString() end)
                    log(string.format("equip diag %s: parent %s socket %s rel %s | world off %.1f %.1f %.1f q %.2f %.2f %.2f %.2f",
                        shortName(gun), valid(par) and fullName(par):match("([^.:]+)$") or "NONE", sock,
                        tp and string.format("%.1f %.1f %.1f q %.2f %.2f %.2f %.2f", tp[1], tp[2], tp[3], tq[1], tq[2], tq[3], tq[4]) or "-",
                        np[1], np[2], np[3], nq[1], nq[2], nq[3], nq[4]))
                end)
            end
            if not tp then
                pcall(function()
                    local cl, q = viewBasis()
                    local x, y, z = qrot(q, gp[1], gp[2], gp[3])
                    gun:K2_SetActorLocationAndRotation(v3(cl.X + x, cl.Y + y, cl.Z + z), quatToRot(qmul(q, gq)), false, {}, true)
                end)
                tp, tq = { 0, 0, 0 }, { 0, 0, 0, 1 }
            end
            local cq = qmul(gq, qconj(tq))
            local ox_, oy_, oz_ = qrot(cq, tp[1], tp[2], tp[3])
            pR, qR = camToParent({ gp[1] - ox_, gp[2] - oy_, gp[3] - oz_ }, cq)
            -- support hand: on the fore-end of long guns (lower when aiming so the glove stays under
            -- the sights), cupping the grip of pistols
            local shotQ = qmul(gq, vm.rot)
            local bf = { qrot(shotQ, 1, 0, 0) }
            local bd = { qrot(shotQ, 0, 0, -1) }
            local bl = { qrot(shotQ, 0, -1, 0) }
            local fore = (w and w[4]) or (vm.melee and -1 or 20)
            local lp, lq
            -- offset of the left glove's mesh from the left controller (rigid: the glove is pinned)
            local gOffP, gOffQ
            if vm.oh and not vm.melee then
                pcall(function()
                    local gm = S.pawn.GraspingHandLeft.SkeletalMeshComponent
                    local ct = S.L:K2_GetComponentToWorld()
                    local gt2 = gm:K2_GetComponentToWorld()
                    local ic = qconj({ ct.Rotation.X, ct.Rotation.Y, ct.Rotation.Z, ct.Rotation.W })
                    gOffP = { qrot(ic, gt2.Translation.X - ct.Translation.X, gt2.Translation.Y - ct.Translation.Y, gt2.Translation.Z - ct.Translation.Z) }
                    gOffQ = qmul(ic, { gt2.Rotation.X, gt2.Rotation.Y, gt2.Rotation.Z, gt2.Rotation.W })
                end)
            end
            if vm.melee then
                lp, lq = nil, nil   -- the free hand hangs at your side
            elseif vm.oh and gOffP then
                -- support hand exactly where the game poses it on this weapon (handguard, pump, under the grip)
                local ohq = qmul(gq, vm.oh.q)
                local ox2, oy2, oz2 = qrot(gq, vm.oh.p[1], vm.oh.p[2], vm.oh.p[3])
                lq = qmul(ohq, qconj(gOffQ))
                local px, py, pz = qrot(lq, gOffP[1], gOffP[2], gOffP[3])
                lp = { gp[1] + ox2 - px, gp[2] + oy2 - py, gp[3] + oz2 - pz }
                if fore > 0 and a > 0 then
                    -- aiming a long gun: the support hand drops under the handguard / pump so the glove
                    -- does not rise into the sight picture
                    local dd = 9 * a
                    lp = { lp[1] + bd[1] * dd - bf[1] * 2 * a, lp[2] + bd[2] * dd - bf[2] * 2 * a, lp[3] + bd[3] * dd - bf[3] * 2 * a }
                end
            elseif fore > 0 then
                local dn = 4 + 10 * a
                lp = { gp[1] + bf[1] * fore + bd[1] * dn, gp[2] + bf[2] * fore + bd[2] * dn, gp[3] + bf[3] * fore + bd[3] * dn }
                lq = shotQ
            else
                local dn = 7 + 9 * a
                lp = { gp[1] + bl[1] * 3 + bd[1] * dn - bf[1] * 2, gp[2] + bl[2] * 3 + bd[2] * dn - bf[2] * 2, gp[3] + bl[3] * 3 + bd[3] * dn - bf[3] * 2 }
                lq = shotQ
            end
            if lp then pL, qL = camToParent(lp, lq) else pL, qL = sideL, downQ end
            if S.now - (S.stabT or 0) > 0.5 then
                S.stabT = S.now
                pcall(function() gun.Stabilized = true end)
                pcall(function() gun.PistolStabilizer = true end)
            end
        end
        if CFG.GunHands == 1 and not S.gunHandsActor then
            S.gunHandsActor = gun
            S.gunHandsOn = gunHandsShow(gun, true)
            glovesHidden(CFG.ShowGloves ~= 1 or S.gunHandsOn)
        end
        showHandMesh("HandMesh-Right", false)   -- the weapon brings its own gripping hand
        showHandMesh("HandMesh-Left", CFG.ShowGloves ~= 1 and not S.gunHandsOn)
    else
        if S.gunHandsActor or S.gunHandsOn then
            if valid(S.gunHandsActor) then pcall(gunHandsShow, S.gunHandsActor, false) end
            S.gunHandsActor, S.gunHandsOn, S.vmGun = nil, false, nil
            glovesHidden(CFG.ShowGloves ~= 1)
        end
        showHandMesh("HandMesh-Right", CFG.ShowGloves ~= 1)
        showHandMesh("HandMesh-Left", CFG.ShowGloves ~= 1)
        local wR, wL = S.free.R, S.free.L
        if S.demo then
            local t = S.now
            wR = { 8 * math.sin(t * 2.1), 12 * math.cos(t * 1.7), 14 * math.sin(t * 1.3) }
            wL = { 8 * math.cos(t * 1.9), 12 * math.sin(t * 1.5), 14 * math.cos(t * 1.1) }
        end
        local free = (wR[1] ~= 0 or wR[2] ~= 0 or wR[3] ~= 0 or S.demo)   -- aiming with empty hands keeps them down
        if free or S.jab > 0 then
            -- raised hands (aim / free move / swing): in front of the view
            local o = lerp3({ 34, 15, -18 }, { 42, 4, -11 }, a)
            if S.jab > 0 then
                S.jab = math.max(0, S.jab - dt)
                local j = math.sin((1 - S.jab / 0.3) * math.pi)
                o = { o[1] + 35 * j, o[2] - 8 * j, o[3] + 10 * j }
            end
            pR, qR = camToParent({ o[1] + wR[1], o[2] + wR[2], o[3] + wR[3] }, { 0, 0, 0, 1 })
        else
            pR, qR = sideR, downQ
        end
        if S.demo or wL[1] ~= 0 or wL[2] ~= 0 or wL[3] ~= 0 then
            pL, qL = camToParent({ 32 + wL[1], -20 + wL[2], -26 + wL[3] }, { 0, 0, 0, 1 })
        else
            pL, qL = sideL, downQ
        end
    end

    -- click-to-touch: the hand reaches to the point you clicked and comes back
    local t = S.touch
    if t then
        local e = S.now - t.t0
        local k = (e < 0.12) and (e / 0.12) or ((e < 0.26) and 1 or math.max(0, 1 - (e - 0.26) / 0.16))
        k = k * k * (3 - 2 * k)
        local target = worldToParent(t.pt)
        if target then
            if t.left then pL = lerp3(pL, target, k) else pR = lerp3(pR, target, k) end
        end
        if e > 0.45 then
            S.touch = nil
            glovesCollide(false)
        end
    end
    if pR then setCtrlRel(S.R, pR, qR) end
    if pL then setCtrlRel(S.L, pL, qL) end
end

------------------------------------------------------------------------------- night vision, flashlight, grenades, aim trace
local function toggleNightVision()
    local ok, err = pcall(function() S.pawn:EventCycleNightVision() end)
    local mode = "?"
    pcall(function() mode = tostring(S.pawn.VisionMode) end)
    log("night vision: " .. (ok and ("vision mode " .. mode) or tostring(err)))
    S.popupMsg = (mode ~= "0" and mode ~= "?") and "NIGHT VISION ON" or "NIGHT VISION OFF"
end

local function lampVisible()
    local v = false
    pcall(function() v = S.pawn.HeadLamp:IsVisible() end)
    return v == true
end
local function toggleFlashlight()
    local want = not lampVisible()
    local ok, err = pcall(function() S.pawn:HeadlampOnOff(want) end)
    if not ok or lampVisible() ~= want then
        pcall(function() S.pawn:EventCycleHeadlamp() end)
    end
    if lampVisible() ~= want then   -- last resort: the light component itself
        pcall(function() S.pawn.HeadLamp:SetVisibility(want, false) end)
    end
    log("flashlight " .. (lampVisible() and "ON" or "OFF") .. (ok and "" or (" (HeadlampOnOff: " .. tostring(err) .. ")")))
    S.popupMsg = lampVisible() and "FLASHLIGHT ON" or "FLASHLIGHT OFF"
end

local GRENADE_CLASS = "/Game/VRExpansion/Guns/BT_MeleeWeapons/WendigoWeapons/BP_PhysPipeBomb.BP_PhysPipeBomb_C"
S.grenades = {}
local function throwGrenade(world)
    local cls = loadClass(GRENADE_CLASS)
    if not cls then log("grenade class not found") return nil end
    local cl, q = viewBasis()
    local fx, fy, fz = qrot(q, 1, 0, 0)
    local rx, ry, rz = qrot(q, 0, 1, 0)
    local p = v3(cl.X + fx * 45 - rx * 14, cl.Y + fy * 45 - ry * 14, cl.Z + fz * 45 - rz * 14 - 6)
    local a = spawnActor(world, cls, xform(p.X, p.Y, p.Z, { Pitch = S.pitch, Yaw = S.yaw, Roll = 0 }), 1)
    if not a then log("grenade spawn failed") return nil end
    pcall(function() a.Lit = true end)
    local okF, errF = pcall(function() a:BurnFuse() end)
    pcall(function()
        local root = a:K2_GetRootComponent()
        root:SetSimulatePhysics(true)
        local sp = CFG.GrenadeSpeed
        root:SetPhysicsLinearVelocity(v3(fx * sp, fy * sp, fz * sp + 250), false, FName("None"))
        root:SetPhysicsAngularVelocityInDegrees(v3(360, 90, 0), false, FName("None"))
    end)
    S.grenades[#S.grenades + 1] = { actor = a, name = fullName(a), at = S.now + CFG.GrenadeFuse, from = p }
    log("threw grenade " .. fullName(a) .. " (fuse " .. (okF and "lit" or tostring(errF)) .. ")")
    S.popupMsg = "GRENADE OUT"
    return a
end
local function grenadeTick()
    for i = #S.grenades, 1, -1 do
        local g = S.grenades[i]
        if not valid(g.actor) then
            log("grenade gone (exploded): " .. g.name)
            table.remove(S.grenades, i)
        elseif S.now >= g.at and not g.forced then
            g.forced = true
            local ok, err = pcall(function() g.actor:ExplodeInstantly() end)
            pcall(function() local l = g.actor:K2_GetActorLocation() g.land = { l.X, l.Y, l.Z } end)
            log("grenade fuse over -> ExplodeInstantly " .. (ok and "called" or tostring(err)))
        elseif g.forced and S.now >= g.at + 5 then
            pcall(function() g.actor:K2_DestroyActor() end)
            table.remove(S.grenades, i)
        end
    end
end

-- what is under the crosshair: weapons turn their muzzle towards this point
local TRACE_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local function aimTrace(world)
    local cl, q = viewBasis()
    local fx, fy, fz = qrot(q, 1, 0, 0)
    local far = v3(cl.X + fx * 10000, cl.Y + fy * 10000, cl.Z + fz * 10000)
    local hit = {}
    local ok, res = pcall(function()
        return KSL():LineTraceSingle(world, cl, far, 0, false, {}, 0, hit, true, TRACE_COLOR, TRACE_COLOR, 0)
    end)
    local p
    if ok and res then
        pcall(function() p = v3(hit.ImpactPoint.X, hit.ImpactPoint.Y, hit.ImpactPoint.Z) end)
        if not p then pcall(function() p = v3(hit.Location.X, hit.Location.Y, hit.Location.Z) end) end
    end
    if p then
        local d = math.sqrt((p.X - cl.X) ^ 2 + (p.Y - cl.Y) ^ 2 + (p.Z - cl.Z) ^ 2)
        if d < 70 then p = nil end   -- our own weapon / hand right in front of the eye
    end
    S.aimPoint = p or far
    S.aimTraceOk = ok
    -- smoothed aim distance: the muzzle converges on it, so it must not jump between near and far
    local d = math.sqrt((S.aimPoint.X - cl.X) ^ 2 + (S.aimPoint.Y - cl.Y) ^ 2 + (S.aimPoint.Z - cl.Z) ^ 2)
    S.aimDist = S.aimDist and (S.aimDist + (d - S.aimDist) * 0.15) or d
end

------------------------------------------------------------------------------- escape menu
local MAPS = {
    { "Basement (hub)", "/Game/Maps/Beta/Map_Beta_Basement" },
    { "Sandbox", "/Game/Maps/Sandbox/Map_Sandbox" },
    { "Sandbox Nu", "/Game/Maps/Sandbox/Map_Sandbox_Nu_OPT" },
    { "Futuristic Sandbox", "/Game/Maps/Sandbox/Map_FuturisticSandbox" },
    { "Fy World", "/Game/Maps/Sandbox/Map_Fy_World" },
    { "Doppleganger", "/Game/Maps/Sandbox/Map_Doppleganger" },
    { "Apartment", "/Game/Maps/Beta/Map_Beta_Apartment" },
    { "Woods Arena", "/Game/Maps/Beta/Map_Beta_WoodsArena" },
    { "Arena Jumper", "/Game/Maps/Arena/Map_Arena_Jumper" },
    { "Compound Arena", "/Game/Maps/Arena/Map_CompoundArena" },
    { "Homewrecker Arena", "/Game/Maps/Arena/Map_Homewrecker_Arena" },
    { "Slum Arena", "/Game/Maps/Arena/Map_SlumArena" },
}
for i = 1, 9 do MAPS[#MAPS + 1] = { "Raid " .. i, "/Game/Maps/Raid/Levels/V3/Map_Raid_lvl" .. i } end
local function menuCursor(on)
    local pc = getPC()
    if not pc then return end
    pcall(function() pc.bShowMouseCursor = on end)
    local wbl = cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
    if on then pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false) end)
    else pcall(function() wbl:SetInputMode_GameOnly(pc) end) end
end
local function menuClose()
    if not S.menu then return end
    S.menu = nil
    S.menuClosedT = S.now
    if HUD then HUD.showMenu(false) end
    menuCursor(false)
end
local function menuOpen(world)
    if not HUD then return end
    S.menu = { page = "main", sel = 1, top = 1, stack = {} }
    S.menuMouse = nil
    local cur = "?"
    pcall(function() cur = fullName(world):match("([^.]+)$") end)
    S.menuMap = cur:upper()
    HUD.showMenu(true)
    menuCursor(true)
    log("menu opened")
end
-- which menu row is under the mouse (rows are laid out from the screen centre in slate units)
local function menuRowUnderMouse(world)
    local wll = cdo("/Script/UMG.Default__WidgetLayoutLibrary")
    if not wll then return nil end
    local mp, vs, sc
    pcall(function() mp = wll:GetMousePositionOnViewport(world) end)
    pcall(function() vs = wll:GetViewportSize(world) end)
    pcall(function() sc = wll:GetViewportScale(world) end)
    if not (mp and vs and sc and sc > 0) then return nil end
    local cx, cy = vs.X / sc / 2, vs.Y / sc / 2
    local dx, dy = mp.X - cx, mp.Y - cy
    local moved = S.menuMouse ~= nil and math.abs(mp.X - S.menuMouse[1]) + math.abs(mp.Y - S.menuMouse[2]) > 2
    S.menuMouse = { mp.X, mp.Y }
    S.menuMouseDx, S.menuMouseDy = dx, dy
    if math.abs(dx) > 320 then return nil end
    local i = math.floor((dy + 220) / 38) + 1
    if i < 1 or i > MENU_ROWS then return nil end
    return i, moved, dx
end

-- radio: plays the music files from <game folder>\Music through a small hidden PowerShell player
-- (radio.ps1 in the mod folder; Windows Media Player engine: mp3/wav/wma/m4a/flac)
local RADIO = { on = false, seq = 0, list = {} }
RADIO.root = modDir:match("^(.*)[/\\][Bb][Tt][Vv][Rr][/\\][Bb]inaries") or modDir
RADIO.dir = RADIO.root .. "\\Music"
RADIO.cmd = modDir .. "\\radio.cmd"
RADIO.statusFile = modDir .. "\\radio.status"
RADIO.listFile = modDir .. "\\radio.list"
RADIO.SPEEDS = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 }
function RADIO.send(c)
    RADIO.seq = RADIO.seq + 1
    local f = io.open(RADIO.cmd, "w")
    if f then f:write(tostring(RADIO.seq) .. " " .. c) f:close() end
end
function RADIO.split(line)
    local t = {}
    for v in (line .. "|"):gmatch("(.-)|") do t[#t + 1] = v end
    return t
end
-- status line: mode|index|pos ms|len ms|speed|volume|shuffle|title|artist|album  -> S.radio
function RADIO.poll()
    if not RADIO.on or S.now - (RADIO.pollT or 0) < 0.2 then return end
    RADIO.pollT = S.now
    local f = io.open(RADIO.statusFile, "r")
    if not f then return end
    local line = f:read("*l")
    f:close()
    if not line or line == "" then return end
    local t = RADIO.split(line)
    S.radio = { mode = t[1], idx = tonumber(t[2]) or -1, pos = tonumber(t[3]) or 0, len = tonumber(t[4]) or 0,
        speed = tonumber(t[5]) or 1, vol = tonumber(t[6]) or 0, shuffle = t[7] == "1",
        title = t[8] or "", artist = t[9] or "", album = t[10] or "" }
    if t[1] == "nomusic" then
        RADIO.on = false
        S.popupMsg = "RADIO: NO SONGS - PUT MUSIC IN THE GAME FOLDER'S MUSIC FOLDER"
    end
    if #RADIO.list == 0 and S.now - (RADIO.listT or 0) > 1 then
        RADIO.listT = S.now
        local lf = io.open(RADIO.listFile, "r")
        if lf then
            for l in lf:lines() do
                local x = RADIO.split(l)
                RADIO.list[#RADIO.list + 1] = { title = x[1] or "?", artist = x[2] or "", album = x[3] or "", len = x[4] or "", file = x[5] or "" }
            end
            lf:close()
        end
    end
end
function RADIO.toggle(on)
    if on == nil then on = not RADIO.on end
    if on then
        RADIO.list = {}
        pcall(function() local f = io.open(RADIO.statusFile, "w") if f then f:write("starting|-1|0|0|1|0|1|LOADING SONGS...||") f:close() end end)
        pcall(function() local f = io.open(RADIO.listFile, "w") if f then f:close() end end)
        RADIO.send("vol " .. tostring(CFG.RadioVolume))
        local cmd = 'start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. modDir ..
            '\\radio.ps1" -Music "' .. RADIO.dir .. '" -Cmd "' .. RADIO.cmd .. '" -Status "' .. RADIO.statusFile ..
            '" -List "' .. RADIO.listFile .. '"'
        local ok, err = pcall(os.execute, cmd)
        log("radio on (" .. RADIO.dir .. ") " .. (ok and "" or tostring(err)))
        RADIO.on = true
        S.popupMsg = "RADIO ON"
    else
        RADIO.send("stop")
        RADIO.on = false
        S.radio = nil
        log("radio off")
        S.popupMsg = "RADIO OFF"
    end
end
function RADIO.next() if RADIO.on then RADIO.send("next") end end
function RADIO.prev() if RADIO.on then RADIO.send("prev") end end
function RADIO.pauseToggle() if RADIO.on then RADIO.send("toggle") end end
function RADIO.volume() if RADIO.on then RADIO.send("vol " .. tostring(CFG.RadioVolume)) end end
function RADIO.play(i) if not RADIO.on then RADIO.toggle(true) end RADIO.send("play " .. tostring(i)) end
function RADIO.seek(ms) if RADIO.on and S.radio then RADIO.send("seek " .. tostring(math.floor(math.max(0, ms)))) S.radio.pos = ms end end
function RADIO.seekFrac(f)
    local r = S.radio
    if r and r.len > 0 then RADIO.seek(clamp(f, 0, 1) * r.len) end
end
function RADIO.speedStep(dir)
    local r = S.radio
    local cur, idx = r and r.speed or 1, 3
    for i, v in ipairs(RADIO.SPEEDS) do if math.abs(v - cur) < 0.01 then idx = i end end
    idx = clamp(idx + dir, 1, #RADIO.SPEEDS)
    RADIO.send(string.format("speed %.2f", RADIO.SPEEDS[idx]))
end
function RADIO.fmt(ms)
    ms = math.max(0, math.floor((ms or 0) / 1000))
    return string.format("%d:%02d", ms // 60, ms % 60)
end
-- enemies hear the radio: a noise event at the player every second; loudness and range from the volume
function RADIO.noise(world)
    if not RADIO.on or CFG.RadioNoise ~= 1 or CFG.RadioVolume <= 0 or S.now - (RADIO.noiseT or 0) < 1 then return end
    if S.radio and S.radio.mode == "paused" then return end
    RADIO.noiseT = S.now
    pcall(function()
        local v = CFG.RadioVolume / 100
        cdo("/Script/AIModule.Default__AISense_Hearing"):ReportNoiseEvent(world, S.pawn:K2_GetActorLocation(), v, S.pawn, 400 + 3600 * v, FName("None"))
    end)
end

local menuBack, menuItems, menuDraw, menuCapture
do
local function menuGo(page)
    local M = S.menu
    M.stack[#M.stack + 1] = { page = M.page, sel = M.sel, top = M.top }
    M.page, M.sel, M.top = page, 1, 1
end
menuBack = function()
    local M = S.menu
    local t = table.remove(M.stack)
    if not t then menuClose() return end
    M.page, M.sel, M.top = t.page, t.sel, t.top
end
-- graphics: the engine's own GameUserSettings (saved by the engine in GameUserSettings.ini)
local QUAL = { [0] = "LOW", [1] = "MEDIUM", [2] = "HIGH", [3] = "EPIC", [4] = "CINEMATIC" }
local function GUS()
    local g
    pcall(function() g = cdo("/Script/Engine.Default__GameUserSettings"):GetGameUserSettings() end)
    return valid(g) and g or nil
end
local function gusGet(fn)
    local v
    pcall(function() local g = GUS() v = g[fn](g) end)
    return v
end
local function gusSet(fn, v, resolution)
    local ok, err = pcall(function()
        local g = GUS()
        g[fn](g, v)
        if resolution then g:ApplyResolutionSettings(false) else g:ApplyNonResolutionSettings() end
        g:SaveSettings()
    end)
    log("graphics " .. fn .. "(" .. tostring(v) .. ") " .. (ok and "ok" or tostring(err)))
end
local function console(cmd)
    pcall(function() local pc = getPC() KSL():ExecuteConsoleCommand(getWorld(pc), cmd, pc) end)
end
local function applyScreenPercentage() console("r.ScreenPercentage " .. tostring(CFG.ScreenPercentage)) end

local function mapPathOf(world)
    local path
    pcall(function() path = fullName(world):match("^%S+%s+(.-)%.[^.]+$") end)
    return path
end
local function loadMap(world, path)
    path = path or mapPathOf(world)
    menuClose()
    if path then
        log("loading map " .. path)
        pcall(function() GS():OpenLevel(world, FName(path), true, "") end)
    end
end
-- text shown on the game's wrist watch
local function watchText(field)
    local t
    pcall(function() t = S.pawn.WatchRef[field].Text:ToString() end)
    if t then t = t:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "") end
    return (t and t ~= "") and t:upper() or nil
end

local function I(label, act, value) return { label = label, act = act, value = value } end
local function stepCfg(key, step, lo, hi, after)
    return function(dir)
        local v = (CFG[key] or 0) + dir * step
        v = math.floor(v / step + 0.5) * step
        if step >= 1 then v = math.floor(v + 0.5) end
        CFG[key] = clamp(v, lo, hi)
        if after then after() end
        saveConfig()
    end
end
local function cycle(v, n, dir) return ((v or 0) + dir) % n end

menuItems = function(world, pc)
    local M = S.menu
    M.bar = nil
    local L = {}
    local function add(...) L[#L + 1] = I(...) end
    local back = function() menuBack() end
    if M.page == "main" then
        M.title, M.sub = "BTDESKTOP", "PAUSED  -  " .. (S.menuMap or "")
        add("RESUME", function() menuClose() end)
        add("RESTART MAP", function() loadMap(world, nil) end)
        add("BASEMENT (HUB)", function() loadMap(world, MAPS[1][2]) end)
        add("CHANGE MAP", function() menuGo("maps") end, function() return ">" end)
        add("WATCH", function() menuGo("watch") end, function() return ">" end)
        add("GRAPHICS", function() menuGo("graphics") end, function() return ">" end)
        add("CONTROLS", function() menuGo("controls") end, function() return ">" end)
        add("GAMEPLAY", function() menuGo("gameplay") end, function() return ">" end)
        add("RADIO", function() menuGo("radio") end, function() return ">" end)
        add(M.quitArm and "QUIT GAME - PRESS AGAIN" or "QUIT GAME", function()
            if not M.quitArm then M.quitArm = true return end
            menuClose() pcall(function() KSL():QuitGame(world, pc, 0, false) end)
        end)
    elseif M.page == "maps" then
        M.title, M.sub = "CHANGE MAP", "NOW: " .. (S.menuMap or "")
        add("< BACK", back)
        for _, m in ipairs(MAPS) do add(m[1]:upper(), function() loadMap(world, m[2]) end) end
    elseif M.page == "watch" then
        M.title, M.sub = "WATCH", "WHAT THE WRIST WATCH SHOWS IN VR"
        local hp, hpMax, kills
        pcall(function() hp, hpMax = num(S.pawn.PlayerHealth), num(S.pawn.playerhealthmax) end)
        pcall(function() kills = num(S.pawn.Kills) end)
        add("< BACK", back)
        add("HEALTH", nil, function() return hp and string.format("%d / %d", math.floor(hp + 0.5), math.floor((hpMax or 0) + 0.5)) or "-" end)
        add("CRACK", nil, function() return watchText("CrackAvailText") or "-" end)
        add("KILLS", nil, function() return kills and tostring(math.floor(kills)) or (watchText("KillsText") or "-") end)
        add("REMAINING", nil, function()
            local t, b = watchText("RemainingTopText"), watchText("RemainingBottomText")
            return (t or b) and ((t or "?") .. " / " .. (b or "?")) or "-"
        end)
        add("SCORE", nil, function() return watchText("ScoreText") or "-" end)
        add("DISTANCE", nil, function() return watchText("DISTANCEText") or watchText("MetersText") or "-" end)
        add("SMOKE CRACK (HEAL)", function() menuClose() useCrack() end, function() return "[" .. keyLabel(B.Crack) .. "]" end)
        add("NIGHT VISION", function() toggleNightVision() end, function() return "[" .. keyLabel(B.NightVision) .. "]" end)
        add("FLASHLIGHT", function() toggleFlashlight() end, function() return lampVisible() and "ON" or "OFF" end)
        add("RESTART", function() loadMap(world, nil) end)
        add("BACK TO BASEMENT", function() loadMap(world, MAPS[1][2]) end)
    elseif M.page == "graphics" then
        M.title, M.sub = "GRAPHICS", "SAVED AUTOMATICALLY"
        add("< BACK", back)
        add("QUALITY PRESET", function(dir)
            local v = gusGet("GetOverallScalabilityLevel") or 2
            if v < 0 then v = 2 end
            gusSet("SetOverallScalabilityLevel", cycle(v, 5, dir))
        end, function() local v = gusGet("GetOverallScalabilityLevel") return (v and v >= 0) and QUAL[v] or "CUSTOM" end)
        for _, g in ipairs({ { "VIEW DISTANCE", "ViewDistanceQuality" }, { "SHADOWS", "ShadowQuality" },
            { "ANTI-ALIASING", "AntiAliasingQuality" }, { "TEXTURES", "TextureQuality" }, { "EFFECTS", "VisualEffectQuality" },
            { "POST PROCESSING", "PostProcessingQuality" }, { "FOLIAGE", "FoliageQuality" }, { "SHADING", "ShadingQuality" } }) do
            add(g[1], function(dir) gusSet("Set" .. g[2], cycle(gusGet("Get" .. g[2]), 5, dir)) end,
                function() return QUAL[gusGet("Get" .. g[2]) or -1] or "-" end)
        end
        add("RESOLUTION SCALE", stepCfg("ScreenPercentage", 10, 50, 200, applyScreenPercentage),
            function() return tostring(CFG.ScreenPercentage) .. " %" end)
        add("VSYNC", function() gusSet("SetVSyncEnabled", not gusGet("IsVSyncEnabled")) end,
            function() return gusGet("IsVSyncEnabled") and "ON" or "OFF" end)
        local LIM = { 0, 30, 60, 90, 120, 144, 165, 240 }
        add("FRAME LIMIT", function(dir)
            local cur, idx = gusGet("GetFrameRateLimit") or 0, 1
            for i, v in ipairs(LIM) do if math.abs(v - cur) < 1 then idx = i end end
            gusSet("SetFrameRateLimit", LIM[(idx - 1 + dir) % #LIM + 1] + 0.0)
        end, function() local v = gusGet("GetFrameRateLimit") or 0 return (v < 1) and "UNLIMITED" or tostring(math.floor(v + 0.5)) end)
        local WM = { [0] = "FULLSCREEN", [1] = "BORDERLESS", [2] = "WINDOWED" }
        add("WINDOW MODE", function(dir) gusSet("SetFullscreenMode", cycle(gusGet("GetFullscreenMode"), 3, dir), true) end,
            function() return WM[gusGet("GetFullscreenMode") or -1] or "-" end)
        add("FIELD OF VIEW", stepCfg("FOV", 5, 60, 120, function() S.fovSet = nil end), function() return tostring(CFG.FOV) end)
    elseif M.page == "controls" then
        M.title, M.sub = "CONTROLS", M.capture and ("PRESS A KEY FOR " .. M.capture.label .. "   (ESC = CANCEL)") or "ENTER / CLICK A ROW, THEN PRESS THE NEW KEY"
        add("< BACK", back)
        add("MOUSE SENSITIVITY", stepCfg("MouseSensitivity", 0.1, 0.1, 10), function() return string.format("%.1f", CFG.MouseSensitivity) end)
        add("AIM BUTTON", function() CFG.AimToggle = (CFG.AimToggle == 1) and 0 or 1 S.aimLatch = false saveConfig() end,
            function() return CFG.AimToggle == 1 and "TOGGLE" or "HOLD" end)
        for _, act in ipairs(ACTIONS) do
            add(act[3], function()
                M.capture = { action = act[1], label = act[3], t0 = S.now, prev = {} }
            end, function()
                if M.capture and M.capture.action == act[1] then return "..." end
                return keyLabel(B[act[1]])
            end)
        end
        add("RESET ALL KEYS", function()
            for _, x in ipairs(ACTIONS) do B[x[1]] = x[2] end
            rebuildWatch() saveConfig()
        end)
    elseif M.page == "radio" then
        local r = S.radio
        M.title, M.sub = "RADIO", RADIO.on and ((r and r.mode == "paused") and "PAUSED" or "ON AIR") or ("PUT SONGS IN: " .. RADIO.dir:upper():sub(-48))
        M.bar = true
        add("< BACK", back)
        add("RADIO", function() RADIO.toggle() end, function() return (RADIO.on and "ON" or "OFF") .. "  [" .. keyLabel(B.Radio) .. "]" end)
        add("SONG", nil, function() return r and r.title ~= "" and r.title:upper():sub(1, 26) or "-" end)
        add("ARTIST", nil, function() return r and r.artist ~= "" and r.artist:upper():sub(1, 26) or "-" end)
        add("ALBUM", nil, function() return r and r.album ~= "" and r.album:upper():sub(1, 22) or "-" end)
        add("TIME (A/D: -/+ 10 S)", function(dir) if r then RADIO.seek(r.pos + dir * 10000) end end,
            function() return r and (RADIO.fmt(r.pos) .. " / " .. RADIO.fmt(r.len)) or "-" end)
        add("PLAY / PAUSE", function() RADIO.pauseToggle() end, function() return r and r.mode == "paused" and "[ PAUSED ]" or "[ PLAYING ]" end)
        add("PREVIOUS / NEXT SONG", function(dir) if dir < 0 then RADIO.prev() else RADIO.next() end end, function() return "PREV  |  NEXT" end)
        add("SPEED", function(dir) RADIO.speedStep(dir) end, function() return string.format("%.2fx", r and r.speed or 1) end)
        add("VOLUME", stepCfg("RadioVolume", 10, 0, 100, RADIO.volume), function() return tostring(CFG.RadioVolume) .. " %" end)
        add("SHUFFLE", function() if r then RADIO.send("shuffle " .. (r.shuffle and "0" or "1")) end end,
            function() return r and (r.shuffle and "ON" or "OFF") or "-" end)
        add("ENEMIES HEAR IT", function() CFG.RadioNoise = (CFG.RadioNoise == 1) and 0 or 1 saveConfig() end,
            function() return CFG.RadioNoise == 1 and "YES" or "NO" end)
        add("SONG LIST (" .. tostring(#RADIO.list) .. ")", function() menuGo("songs") end, function() return ">" end)
        add("OPEN MUSIC FOLDER", function()
            pcall(os.execute, 'mkdir "' .. RADIO.dir .. '" 2>nul')
            pcall(os.execute, 'start "" explorer "' .. RADIO.dir .. '"')
        end)
    elseif M.page == "songs" then
        local r = S.radio
        M.title, M.sub = "SONG LIST", tostring(#RADIO.list) .. " SONGS  -  ENTER / CLICK TO PLAY"
        M.bar = true
        add("< BACK", back)
        for i, sng in ipairs(RADIO.list) do
            local name = sng.title .. ((sng.artist ~= "") and ("  -  " .. sng.artist) or "")
            add(((r and r.idx == i - 1) and "* " or "") .. name:upper():sub(1, 30), function() RADIO.play(i - 1) end,
                function() return ((sng.len or ""):gsub("^00:", "")) end)
        end
    elseif M.page == "gameplay" then
        M.title, M.sub = "GAMEPLAY", "SAVED AUTOMATICALLY"
        add("< BACK", back)
        add("AIM ZOOM (FOV)", stepCfg("AimFOV", 5, 20, 85, function() S.aimFov = nil end), function() return tostring(CFG.AimFOV) end)
        add("VIEW BOB", stepCfg("ViewBob", 0.5, 0, 4), function() return CFG.ViewBob == 0 and "OFF" or string.format("%.1f", CFG.ViewBob) end)
        add("WALK SPEED", stepCfg("WalkSpeed", 25, 150, 600), function() return tostring(CFG.WalkSpeed) end)
        add("SPRINT SPEED", stepCfg("SprintMultiplier", 0.1, 1, 4), function() return string.format("x%.1f", CFG.SprintMultiplier) end)
        add("EYE HEIGHT", stepCfg("EyeHeight", 5, 120, 210), function() return tostring(CFG.EyeHeight) .. " CM" end)
        add("CROSSHAIR", function() CFG.Crosshair = (CFG.Crosshair == 1) and 0 or 1 saveConfig() end,
            function() return CFG.Crosshair == 1 and "ON" or "OFF" end)
        add("GLOVES", function()
            CFG.ShowGloves = (CFG.ShowGloves == 1) and 0 or 1
            S.handShown = {}
            pcall(handsSetup)
            saveConfig()
        end, function() return CFG.ShowGloves == 1 and "GAME GLOVES" or "SIMPLE HANDS" end)
        add("GOD MODE", function() setGod(not S.god) end, function() return S.god and "ON" or "OFF" end)
    end
    return L
end

menuDraw = function(L)
    local M = S.menu
    if not (M and HUD) then return end
    if M.sel > #L then M.sel = #L end
    if M.sel < 1 then M.sel = 1 end
    if M.sel < M.top then M.top = M.sel end
    if M.sel > M.top + MENU_ROWS - 1 then M.top = M.sel - MENU_ROWS + 1 end
    setText(HUD.menu.title, M.title or "BTDESKTOP")
    setText(HUD.menu.sub, M.sub or "")
    for i = 1, MENU_ROWS do
        local idx = M.top + i - 1
        local item = L[idx]
        local e, v = HUD.menu.rows[i], HUD.menu.vals[i]
        if item then
            local sel = idx == M.sel
            setText(e, (sel and "> " or "  ") .. item.label)
            setColor(e, sel and C_RED or (item.act and C_GREY or C_DIM))
            hudShow(e, true)
            local val = item.value and item.value() or ""
            item.cycle = item.value and item.act and M.page ~= "controls" and M.page ~= "songs" and val ~= ">" and not val:find("^%[")
            setText(v, val)
            setColor(v, sel and C_WHITE or C_GREY)
            hudShow(v, val ~= "")
            hudShow(HUD.menu.arrL[i], item.cycle and true or false)
            hudShow(HUD.menu.arrR[i], item.cycle and true or false)
            setColor(HUD.menu.arrL[i], sel and C_RED or C_DIM)
            setColor(HUD.menu.arrR[i], sel and C_RED or C_DIM)
        else
            hudShow(e, false)
            hudShow(v, false)
            hudShow(HUD.menu.arrL[i], false)
            hudShow(HUD.menu.arrR[i], false)
        end
    end
end

-- Esc > Controls: wait for the next key pressed
menuCapture = function(pc)
    local c = S.menu and S.menu.capture
    if not c then return end
    for _, n in ipairs(ALLKEYS) do
        local ok, v = pcall(function() return pc:IsInputKeyDown(fkey(n)) end)
        local d = ok and v == true
        if d and c.prev[n] == false and S.now - c.t0 > 0.15 then
            local old = B[c.action]
            for _, x in ipairs(ACTIONS) do   -- a key does one thing: the other action gets the old key
                if x[1] ~= c.action and B[x[1]] == n then B[x[1]] = old end
            end
            B[c.action] = n
            S.menu.capture = nil
            rebuildWatch()
            saveConfig()
            log("key " .. c.action .. " = " .. n)
            return
        end
        c.prev[n] = d
    end
end
end

------------------------------------------------------------------------------- self test
-- A queue of steps run by the frame loop (UE4SS cannot call game functions from inside a Lua
-- coroutine, so no coroutines here). DO = run a function, WAIT = seconds, FR = frames.
local test = { q = {}, i = 1, pass = 0, fail = 0, waitUntil = nil, waitFrames = nil, started = false }
local C = {}   -- values shared between steps
local function T(name, ok, detail)
    if ok then test.pass = test.pass + 1 else test.fail = test.fail + 1 end
    log(string.format("TEST %-36s %s  %s", name, ok and "PASS" or "FAIL", detail or ""))
end
local function DO(fn) test.q[#test.q + 1] = { fn = fn } end
local function WAIT(s) test.q[#test.q + 1] = { wait = s } end
local function FR(n) test.q[#test.q + 1] = { frames = n } end
local function KEY(k, on) DO(function() virt[k] = on or nil end) end
local function AX(k, v) DO(function() virtAxis[k] = v end) end
local function TAP(k) KEY(k, true) FR(2) KEY(k, nil) FR(2) end
local function ploc() local p = S.pawn:K2_GetActorLocation() return { p.X, p.Y, p.Z } end
local function dist2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
local function countOf(cls)
    local n = 0
    for _, a in ipairs(FindAllOf(cls) or {}) do if valid(a) then n = n + 1 end end
    return n
end
local function handLocal(ctrl)
    -- controller position in view space (forward, right, up) relative to the camera
    local cl, q = viewBasis()
    local l = ctrl:K2_GetComponentLocation()
    return { qrot(qconj(q), l.X - cl.X, l.Y - cl.Y, l.Z - cl.Z) }
end

local function testRun(now)
    while test.i <= #test.q do
        local s = test.q[test.i]
        if s.wait then
            test.waitUntil = test.waitUntil or (now + s.wait)
            if now < test.waitUntil then return end
            test.waitUntil = nil
        elseif s.frames then
            test.waitFrames = test.waitFrames or s.frames
            if test.waitFrames > 0 then test.waitFrames = test.waitFrames - 1 return end
            test.waitFrames = nil
        else
            local ok, err = pcall(s.fn)
            if not ok then log("SELFTEST step " .. test.i .. " error: " .. tostring(err)) end
        end
        test.i = test.i + 1
    end
end

local function buildSelfTest()
    WAIT(3)
    DO(function()
        log("SELFTEST start on " .. S.pawnName)
        setGod(true)
        local cz = S.cam:K2_GetComponentLocation().Z
        local pz = S.pawn:K2_GetActorLocation().Z
        T("camera at eye height", math.abs((cz - pz) - CFG.EyeHeight) < 20, string.format("eye %.0f cm above actor", cz - pz))
        local en = true
        pcall(function() en = cdo("/Script/HeadMountedDisplay.Default__HeadMountedDisplayFunctionLibrary"):IsHeadMountedDisplayEnabled() end)
        T("headset off (desktop view)", en == false, "IsHeadMountedDisplayEnabled=" .. tostring(en))
        C.p0 = ploc()
    end)
    -- movement
    KEY("W", true) WAIT(1.5) KEY("W") WAIT(0.3)
    DO(function()
        C.dWalk = dist2(C.p0, ploc())
        T("walk forward (W)", C.dWalk > 60, string.format("%.0f cm in 1.5 s", C.dWalk))
        C.p0 = ploc()
    end)
    KEY("S", true) KEY("LeftShift", true) WAIT(1.5) KEY("S") KEY("LeftShift") WAIT(0.3)   -- back the way we came
    DO(function()
        local d = dist2(C.p0, ploc())
        T("sprint (Shift+S)", d > C.dWalk * 1.3, string.format("%.0f cm in 1.5 s (walk %.0f)", d, C.dWalk))
        C.p0, C.y0 = ploc(), S.yaw
    end)
    KEY("D", true) WAIT(1.0) KEY("D") WAIT(0.3)
    DO(function()
        local p1, yr = ploc(), C.y0 * DEG
        local side = (p1[1] - C.p0[1]) * -math.sin(yr) + (p1[2] - C.p0[2]) * math.cos(yr)
        T("strafe right (D)", side > 40, string.format("%.0f cm to the right", side))
        C.y0 = S.yaw
    end)
    -- mouse look
    AX("MouseX", 4) FR(15) AX("MouseX", nil) FR(2)
    DO(function()
        local pawnYaw = S.pawn:K2_GetActorRotation().Yaw
        T("mouse turn (yaw)", math.abs(normAxis(S.yaw - C.y0)) > 20 and math.abs(normAxis(pawnYaw - S.yaw)) < 2,
            string.format("view yaw %.0f -> %.0f, pawn yaw %.0f", C.y0, S.yaw, pawnYaw))
    end)
    AX("MouseY", 2) FR(10) AX("MouseY", nil) FR(2)
    DO(function()
        local p = S.cam:K2_GetComponentRotation().Pitch
        T("mouse look up (pitch)", p > 15, string.format("camera pitch %.0f", p))
        S.pitch = 0
    end)
    FR(2)
    -- crouch / jump
    DO(function() C.c0 = S.cam:K2_GetComponentLocation().Z end)
    KEY("C", true) WAIT(0.6)
    DO(function() C.c1 = S.cam:K2_GetComponentLocation().Z end)
    KEY("C") WAIT(0.6)
    DO(function()
        T("crouch (C / Ctrl)", C.c0 - C.c1 > 45, string.format("head %.0f cm lower", C.c0 - C.c1))
        C.z0 = ploc()[3] C.zmax = C.z0
    end)
    KEY("SpaceBar", true) FR(2) KEY("SpaceBar")
    for _ = 1, 40 do FR(1) DO(function() C.zmax = math.max(C.zmax, ploc()[3]) end) end
    WAIT(1)
    DO(function() T("jump (Space)", C.zmax - C.z0 > 10, string.format("rose %.0f cm", C.zmax - C.z0)) end)
    -- hands
    FR(3)
    DO(function()
        C.hr, C.hl = handLocal(S.R), handLocal(S.L)
        local hr, hl = C.hr, C.hl
        T("unarmed: hands down by your sides", hr[2] > 15 and hl[2] < -15 and hr[3] < -50 and hl[3] < -50,
            string.format("R fwd %.0f right %.0f up %.0f | L fwd %.0f right %.0f up %.0f", hr[1], hr[2], hr[3], hl[1], hl[2], hl[3]))
    end)
    AX("MouseX", 4) FR(10) AX("MouseX", nil) FR(8)
    DO(function()
        local h2 = handLocal(S.R)
        T("hands follow the view", math.abs(h2[1] - C.hr[1]) < 3 and math.abs(h2[2] - C.hr[2]) < 3,
            string.format("view-space offset %.1f/%.1f -> %.1f/%.1f", C.hr[1], C.hr[2], h2[1], h2[2]))
    end)
    KEY("RightMouseButton", true) WAIT(0.4)
    DO(function()
        local ha = handLocal(S.R)
        T("aim, empty hand (right mouse)", ha[2] < C.hr[2] - 8 and ha[3] > C.hr[3] + 6, string.format("R right %.0f -> %.0f, up %.0f -> %.0f", C.hr[2], ha[2], C.hr[3], ha[3]))
    end)
    KEY("RightMouseButton") WAIT(0.4)
    KEY("LeftAlt", true) AX("MouseX", 3) AX("MouseY", 2) FR(10) AX("MouseX", nil) AX("MouseY", nil) KEY("LeftAlt") FR(2)
    DO(function()
        local hf = handLocal(S.R)
        T("free hand (Alt + mouse)", hf[2] > C.hr[2] + 8 and hf[3] > C.hr[3] + 4, string.format("R right %.0f up %.0f", hf[2], hf[3]))
    end)
    TAP("V")
    -- weapons
    TAP("One") WAIT(0.8)
    DO(function()
        C.g = heldActor(S.R)
        T("equip 1 = glock (grip)", C.g ~= nil and shortName(C.g):lower():find("glock") ~= nil, C.g and fullName(C.g) or "nothing held")
    end)
    FR(15) TAP("R") FR(3)
    DO(function()
        local g = C.g
        if not g then return end
        local a0 = ammoOf(g)
        T("reload (R)", a0 ~= nil and a0 > 0, "ammo " .. tostring(a0))
        local _, q = viewBasis()
        local fx, fy, fz = qrot(q, 1, 0, 0)
        local okA, dot = pcall(function()
            local mx, my, mz = qrot(rq(g.FireDirection:K2_GetComponentRotation()), 1, 0, 0)
            return mx * fx + my * fy + mz * fz
        end)
        T("gun points at the crosshair (hip)", okA and dot > 0.97, okA and string.format("muzzle . view = %.3f", dot) or tostring(dot))
    end)
    KEY("RightMouseButton", true) WAIT(0.5)
    DO(function()
        local g = C.g
        if not g then return end
        C.fovA = S.fovNow
        local okS, info = pcall(function()
            local cl, q2 = viewBasis()
            local m = g.FireDirection:K2_GetComponentLocation()
            local mx, my, mz = qrot(rq(g.FireDirection:K2_GetComponentRotation()), 1, 0, 0)
            local vx, vy, vz = qrot(q2, 1, 0, 0)
            local _, ly, lz = qrot(qconj(q2), m.X - cl.X, m.Y - cl.Y, m.Z - cl.Z)
            return { mx * vx + my * vy + mz * vz, ly, lz }
        end)
        T("aim down sights (right mouse)", okS and C.fovA < CFG.FOV - 20 and info[1] > 0.995 and math.abs(info[2]) < 2 and info[3] < 0 and info[3] > -10,
            okS and string.format("fov %.0f, barrel . view %.4f, muzzle %.1f cm right %.1f cm up", C.fovA, info[1], info[2], info[3]) or tostring(info))
    end)
    AX("MouseWheelAxis", 1) FR(1) AX("MouseWheelAxis", nil) WAIT(0.3)
    DO(function() T("zoom in while aiming (wheel)", S.fovNow < (C.fovA or 999) - 2, string.format("fov %.0f -> %.0f", C.fovA or 0, S.fovNow)) end)
    AX("MouseWheelAxis", -1) FR(1) AX("MouseWheelAxis", nil)
    KEY("RightMouseButton") WAIT(0.5)
    DO(function() T("zoom back out on release", math.abs(S.fovNow - CFG.FOV) < 1, string.format("fov %.0f", S.fovNow)) C.fired = false end)
    for i = 1, 4 do
        DO(function() C.before = C.g and ammoOf(C.g) end)
        KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") WAIT(0.45)
        DO(function()
            local after = C.g and valid(C.g) and ammoOf(C.g)
            log(string.format("  shot %d via %s: ammo %s -> %s", i, FIRE_MODES[S.fire.mode], tostring(C.before), tostring(after)))
            if C.before and after and after < C.before then C.fired = true end
        end)
    end
    DO(function() T("fire (left mouse)", C.fired, "trigger path " .. FIRE_MODES[S.fire.mode]) end)
    TAP("R") FR(3)
    for _, s in ipairs({ 3, 6, 7, 8 }) do
        TAP(DIGITS[s]) WAIT(0.8)
        DO(function()
            local h = heldActor(S.R)
            T("equip " .. s .. " = " .. WEAPONS[s][1], h ~= nil, h and fullName(h) or "nothing held")
        end)
    end
    KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") WAIT(0.4)
    TAP("Q") WAIT(0.4)
    DO(function() T("holster (Q)", heldObject(S.R) == nil, "") end)
    TAP("One") WAIT(0.8) TAP("G") WAIT(1.0)
    WAIT(0.6)
    DO(function()
        T("drop (G)", heldObject(S.R) == nil, "")
        -- look straight at the gun we just dropped
        pcall(function()
            local d
            d = S.lastDroppedActor
            local p = d:K2_GetActorLocation()
            local cl = S.cam:K2_GetComponentLocation()
            local dx, dy, dz = p.X - cl.X, p.Y - cl.Y, p.Z - cl.Z
            S.yaw = math.atan(dy, dx) * RAD
            S.pitch = math.atan(dz, math.sqrt(dx * dx + dy * dy)) * RAD
        end)
    end)
    FR(5) TAP("G") WAIT(0.8)
    DO(function()
        local gg = heldActor(S.R)
        T("grab what you look at (G)", gg ~= nil, gg and fullName(gg) or "nothing")
        S.pitch = 0
    end)
    TAP("Zero") WAIT(0.4)
    -- debug helpers
    DO(function() setGod(false) end)
    TAP("F2")
    DO(function()
        C.h0 = 0
        pcall(function() C.h0 = S.pawn.PlayerHealth end)
        pcall(function() S.pawn:BulletDamage(30) end)
    end)
    WAIT(0.3)
    DO(function()
        local h1 = 0
        pcall(function() h1 = S.pawn.PlayerHealth end)
        T("god mode (F2)", h1 >= C.h0 and S.pawn.Invincible == true, string.format("health %.0f -> %.0f after 30 damage", C.h0, h1))
    end)
    DO(function() C.n0 = countOf("BP_NPC_Man_C") end)
    TAP("F3") WAIT(1.5)
    DO(function()
        local n1 = countOf("BP_NPC_Man_C")
        T("spawn NPC (F3)", n1 > C.n0, string.format("NPCs %d -> %d", C.n0, n1))
    end)
    TAP("F4")
    DO(function() C.z0 = ploc()[3] end)
    KEY("SpaceBar", true) WAIT(0.6) KEY("SpaceBar")
    DO(function() local zn = ploc()[3] T("noclip fly (F4 + Space)", zn - C.z0 > 100, string.format("rose %.0f cm", zn - C.z0)) end)
    TAP("F4") WAIT(1.5)
    TAP("F5") FR(3)
    DO(function()
        local dil = 1
        pcall(function() dil = GS():GetGlobalTimeDilation(getWorld(getPC())) end)
        T("slow motion (F5)", math.abs(dil - 0.25) < 0.01, string.format("time dilation %.2f", dil))
    end)
    TAP("F5") FR(3)
    DO(function()
        local inView = false
        pcall(function() inView = HUD.widget:IsInViewport() end)
        T("2D HUD on screen (loadout bar, ammo, health)", HUD ~= nil and #HUD.all >= 30 and inView, HUD and (#HUD.all .. " widgets, in viewport " .. tostring(inView)) or "no HUD")
    end)
    TAP("One") WAIT(0.8)
    AX("MouseWheelAxis", -1) FR(1) AX("MouseWheelAxis", nil) WAIT(0.8)
    DO(function()
        local hw = heldActor(S.R)
        T("weapon wheel (scroll -> next slot)", S.sel == 2 and hw ~= nil, "slot " .. tostring(S.sel) .. " " .. (hw and shortName(hw) or "nothing"))
    end)
    TAP("F1") FR(3)
    DO(function() T("debug text (F1)", S.overlay == true and HUD ~= nil and HUD.debug ~= nil and HUD.debug.shown == true, "") end)
    TAP("F1")
    -- night vision / flashlight
    DO(function() C.vis0 = -1 pcall(function() C.vis0 = S.pawn.VisionMode end) end)
    TAP("N") WAIT(0.3)
    DO(function()
        local v = -1
        pcall(function() v = S.pawn.VisionMode end)
        T("night vision (N)", v ~= C.vis0, string.format("vision mode %s -> %s", tostring(C.vis0), tostring(v)))
    end)
    TAP("N") WAIT(0.3)
    DO(function() C.lamp0 = lampVisible() end)
    TAP("F") WAIT(0.3)
    DO(function() T("flashlight (F)", lampVisible() ~= C.lamp0, string.format("headlamp visible %s -> %s", tostring(C.lamp0), tostring(lampVisible()))) end)
    TAP("F") WAIT(0.3)
    -- recoil + bullets on the crosshair
    TAP("One") WAIT(0.8)
    DO(function()
        local g = heldActor(S.R)
        local ok, dot = pcall(function()
            local fd = g.FireDirection
            local mp = fd:K2_GetComponentLocation()
            local mx, my, mz = qrot(rq(fd:K2_GetComponentRotation()), 1, 0, 0)
            local ap = S.aimPoint
            local dx, dy, dz = ap.X - mp.X, ap.Y - mp.Y, ap.Z - mp.Z
            local n = math.sqrt(dx * dx + dy * dy + dz * dz)
            return (mx * dx + my * dy + mz * dz) / n
        end)
        C.snapHip = bulletSnapshot()
        C.aimAtShot = S.aimPoint
        T("muzzle aims at the crosshair point", ok and dot > 0.999, ok and string.format("muzzle . (aim point - muzzle) = %.4f, trace %s", dot, tostring(S.aimTraceOk)) or tostring(dot))
        C.pitch0, C.yaw0, C.shots0 = S.pitch, S.yaw, S.shots or 0
    end)
    KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") FR(4)
    DO(function()
        T("no recoil (view stays put)", math.abs(S.pitch - C.pitch0) < 0.01 and math.abs(S.yaw - C.yaw0) < 0.01, string.format("pitch %.2f -> %.2f, yaw %.2f -> %.2f", C.pitch0, S.pitch, C.yaw0, S.yaw))
        local c = S.calib.bp_skel_glock_C
        T("shot direction measured (aim calibration)", c ~= nil and c[4] > 0, c and (c[4] .. " shot(s)") or "no bullet seen")
        S.pitch = 0
    end)
    -- grenade
    DO(function() C.gn = #S.grenades end)
    TAP("T") WAIT(0.7)
    DO(function()
        local g = S.grenades[#S.grenades]
        local d = 0
        pcall(function() local l = g.actor:K2_GetActorLocation() d = math.sqrt((l.X - g.from.X) ^ 2 + (l.Y - g.from.Y) ^ 2) end)
        T("throw grenade (T)", #S.grenades > C.gn and d > 150, string.format("flew %.0f cm in 0.7 s", d))
    end)
    WAIT(3.5)
    -- inventory: switching back gives the same gun (no new gun, no new magazine)
    TAP("One") WAIT(0.6)
    DO(function() C.g1 = fullName(heldActor(S.R)) C.mags = countOf("BP_SkeletalMag_glock_C") end)
    TAP("Two") WAIT(0.6) TAP("One") WAIT(0.6)
    DO(function()
        local g = fullName(heldActor(S.R))
        local mags = countOf("BP_SkeletalMag_glock_C")
        T("switching back reuses the weapon", g == C.g1 and mags == C.mags, string.format("same gun %s, glock magazines %d -> %d", tostring(g == C.g1), C.mags, mags))
    end)
    -- reload from empty, then it fires again
    TAP("Three") WAIT(0.8)
    DO(function()
        local g = heldActor(S.R)
        pcall(function() g.MagRef.magazineAmmo = 0 end)
        pcall(function() g.Ammo = 0 end)
        pcall(function() g.RoundChambered = false end)
        pcall(function() g.BoltLockedBack = true end)
        C.empty = ammoOf(g)
    end)
    TAP("R") FR(3)
    DO(function() C.full = ammoOf(heldActor(S.R)) end)
    KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") WAIT(0.5)
    DO(function()
        local after = ammoOf(heldActor(S.R))
        T("reload from empty, then fire", C.full and C.full > 0 and after and after < C.full, string.format("ammo %s -> reload %s -> after a shot %s", tostring(C.empty), tostring(C.full), tostring(after)))
    end)
    -- fire mode
    DO(function() C.fm = -1 pcall(function() C.fm = heldActor(S.R).Firingmode end) end)
    TAP("B") FR(3)
    DO(function()
        local m = -1
        pcall(function() m = heldActor(S.R).Firingmode end)
        T("fire mode switch (B)", m ~= C.fm and m >= 0 and m <= 2, string.format("mode %s -> %s", tostring(C.fm), tostring(m)))
    end)
    TAP("B") FR(3)
    -- what each fire mode really does: rounds fired while the trigger is held for 0.6 s
    for _, mode in ipairs({ 0, 1, 2, 3 }) do
        TAP("R") FR(3)
        DO(function() pcall(function() heldActor(S.R).Firingmode = mode end) C.fa = ammoOf(heldActor(S.R)) end)
        KEY("LeftMouseButton", true) WAIT(0.6) KEY("LeftMouseButton") WAIT(0.4)
        DO(function() log(string.format("fire mode %d: %s rounds in 0.6 s of trigger", mode, tostring((C.fa or 0) - (ammoOf(heldActor(S.R)) or 0)))) end)
    end
    TAP("R") FR(3)
    -- melee: an NPC right in front, swing the bat
    TAP("Eight") WAIT(0.8)
    DO(function()
        local npc = spawnNPC(getWorld(getPC()))
        C.npc = npc
        pcall(function()
            local cl, q = viewBasis()
            local fx, fy = qrot(q, 1, 0, 0)
            local p = S.pawn:K2_GetActorLocation()
            npc:K2_SetActorLocation(v3(p.X + fx * 110, p.Y + fy * 110, p.Z + 95), false, {}, true)
        end)
        S.pitch = -8
    end)
    WAIT(1.0)
    DO(function()
        C.nb, C.nbl = -1, -1
        pcall(function() C.nb = C.npc.BleedRate end)
        pcall(function() C.nbl = C.npc.Blood_ML_Remaining end)
        C.nd = false pcall(function() C.nd = C.npc.Dead end)
    end)
    KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") WAIT(0.6)
    KEY("LeftMouseButton", true) FR(3) KEY("LeftMouseButton") WAIT(0.8)
    DO(function()
        local b, bl, since, d = -1, -1, 99, false
        pcall(function() b = C.npc.BleedRate end)
        pcall(function() bl = C.npc.Blood_ML_Remaining end)
        pcall(function() since = C.npc.TimeSinceLastDamage end)
        pcall(function() d = C.npc.Dead end)
        T("melee hit (bat)", (since < 2) or b > C.nb or bl < C.nbl or (d and not C.nd),
            string.format("NPC bleed rate %.1f -> %.1f, blood %.0f -> %.0f ml, %.2f s since damage, dead %s", C.nb, b, C.nbl, bl, since, tostring(d)))
        S.pitch = 0
    end)
    -- crack heals
    DO(function() setGod(false) pcall(function() S.pawn:BulletDamage(60) end) end)
    WAIT(0.4)
    DO(function() C.hc = -1 pcall(function() C.hc = S.pawn.PlayerHealth end) end)
    TAP("H") WAIT(2.5)
    DO(function()
        local h = -1
        pcall(function() h = S.pawn.PlayerHealth end)
        T("crack heals (H)", h > C.hc, string.format("health %.0f -> %.0f", C.hc, h))
        setGod(true)
    end)
    -- slot 6 (shotgun) is a real, visible gun
    TAP("Six") WAIT(0.8)
    DO(function()
        local g = heldActor(S.R)
        local vis = false
        pcall(function() vis = g:K2_GetRootComponent():IsVisible() end)
        T("slot 6 = shotgun, visible", g ~= nil and vis, g and (shortName(g) .. " visible " .. tostring(vis)) or "nothing held")
    end)
    -- escape menu + map change
    TAP("Escape") FR(3)
    DO(function() T("escape menu opens (Esc)", S.menu ~= nil, "") end)
    TAP("Down") TAP("Down") FR(2)
    DO(function() T("menu navigation (Down)", S.menu ~= nil and S.menu.sel == 3, "selected " .. tostring(S.menu and MENU_ITEMS[S.menu.sel][1])) end)
    TAP("Escape") FR(3)
    DO(function() T("escape menu closes (Esc)", S.menu == nil, "") C.pawnBefore = S.pawnName end)
    TAP("Escape") FR(3)
    DO(function() if S.menu then S.menu.sel = 4 end end)   -- SANDBOX: reload the map through the menu
    TAP("Enter")
    WAIT(14)
    DO(function()
        local w = fullName(getWorld(getPC()))
        T("change map from the menu", w:find("Map_Sandbox", 1, true) ~= nil and S.pawnName ~= C.pawnBefore and valid(S.pawn),
            "now " .. w .. ", pawn " .. tostring(S.pawnName))
    end)
    DO(function() log(string.format("SELFTEST DONE pass=%d fail=%d", test.pass, test.fail)) end)
    if CFG.SelfTestEnd == "hold" then
        TAP("One") WAIT(0.8)
        DO(function() S.demo = true setGod(true) log("SELFTEST end state: holding the glock, hands waving, god mode on (V stops waving, F2 god)") end)
    end
end

------------------------------------------------------------------------------- frame
------------------------------------------------------------------------------- diagnostics (F11)
local DIAG = { hudCalls = 0, hooked = nil }
local function diagHook()
    if DIAG.hooked ~= nil then return end
    local ok, err = pcall(RegisterHook, "/Script/Engine.HUD:ReceiveDrawHUD", function(self, sx, sy)
        DIAG.hudCalls = DIAG.hudCalls + 1
    end)
    DIAG.hooked = ok
    log("diag: hook HUD:ReceiveDrawHUD " .. (ok and "registered" or tostring(err)))
end
local function vecInView(qv, x, y, z) local cl, q = viewBasis() return qrot(qconj(q), x, y, z) end
local function diagDump(world, pc)
    log("diag: ---- start ----")
    -- HUD
    local hud
    pcall(function() hud = pc.MyHUD end)
    log("diag: pc.MyHUD = " .. (valid(hud) and fullName(hud) or "none") .. ", ReceiveDrawHUD calls so far " .. DIAG.hudCalls)
    -- widget classes available for a UMG HUD
    local wc = FindAllOf("WidgetBlueprintGeneratedClass") or {}
    local names = {}
    for i, c in ipairs(wc) do if i <= 12 then names[#names + 1] = fullName(c):match("([^.]+)$") end end
    log("diag: widget classes " .. #wc .. ": " .. table.concat(names, ", "))
    -- held gun
    local g = heldActor(S.R)
    if g then
        log("diag: held " .. fullName(g))
        local _, q = viewBasis()
        local root = g:K2_GetRootComponent()
        pcall(function()
            local socks = root:GetAllSocketNames()
            local list = {}
            for i = 1, #socks do list[#list + 1] = socks[i]:ToString() end
            log("diag: root " .. shortName(root) .. " sockets: " .. table.concat(list, ", "))
        end)
        pcall(function()
            local cs = g:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))
            for i = 1, #cs do
                local c = cs[i]
                pcall(function()
                    local l = c:K2_GetComponentLocation()
                    local fx, fy, fz = qrot(rq(c:K2_GetComponentRotation()), 1, 0, 0)
                    local cl = S.cam:K2_GetComponentLocation()
                    local lx, ly, lz = qrot(qconj(q), l.X - cl.X, l.Y - cl.Y, l.Z - cl.Z)
                    local vx, vy, vz = qrot(qconj(q), fx, fy, fz)
                    local vis = ""
                    pcall(function() vis = c:IsVisible() and " vis" or " hidden" end)
                    log(string.format("diag:   comp %-28s %-26s pos(view) %6.1f %6.1f %6.1f fwd(view) %5.2f %5.2f %5.2f%s",
                        c:GetFName():ToString(), shortName(c), lx, ly, lz, vx, vy, vz, vis))
                end)
            end
        end)
        for _, k in ipairs({ "Firingmode", "Ammo", "AmmoMAX", "RoundChambered", "BoltLockedBack", "CanBeFired", "FullyCocked", "bUseInternalMag", "shotgun", "revolver", "StartingAmmo" }) do
            pcall(function() log("diag:   " .. k .. " = " .. tostring(g[k])) end)
        end
        pcall(function() log("diag:   MagRef = " .. (valid(g.MagRef) and fullName(g.MagRef) or "none")) end)
    end
    -- damage causer rows (melee)
    pcall(function()
        local dt = StaticFindObject("/Game/BloodTrailWeapons/Data/DataTables/BT_DamageCauser_DataTable.BT_DamageCauser_DataTable")
        if not valid(dt) then pcall(LoadAsset, "/Game/BloodTrailWeapons/Data/DataTables/BT_DamageCauser_DataTable") dt = StaticFindObject("/Game/BloodTrailWeapons/Data/DataTables/BT_DamageCauser_DataTable.BT_DamageCauser_DataTable") end
        local rows = {}
        dt:ForEachRow(function(name, row) rows[#rows + 1] = tostring(name) end)
        log("diag: damage rows: " .. table.concat(rows, ", "))
    end)
    -- pooled bullets: where are they?
    for _, cn in ipairs({ "BP_9mm_B_InstantHit_C", "BP_BT_Projectile_Base_C", "BP_BulletBase_C", "BP_5_45_InstantHit_C", "BP_9mm_Bullet_C" }) do
        local all = FindAllOf(cn) or {}
        log("diag: " .. cn .. " instances " .. #all)
    end
    -- hands, controller parents, holstered loadout weapons
    pcall(function()
        local function par(c) local ok, p = pcall(function() return c:GetAttachParent() end) return ok and valid(p) and fullName(p) or "-" end
        log("diag: camera parent " .. par(S.cam) .. " | R parent " .. par(S.R) .. " | L parent " .. par(S.L))
        for _, k in ipairs({ "GraspingHandRight", "GraspingHandLeft" }) do
            local h = S.pawn[k]
            if valid(h) then
                local root = h:K2_GetRootComponent()
                local sim = "?"
                pcall(function() sim = tostring(root:IsSimulatingPhysics(FName("None"))) end)
                local l = root:K2_GetComponentLocation()
                local c = (k:find("Right") and S.R or S.L):K2_GetComponentLocation()
                log(string.format("diag: %s %s root %s (%s) sim %s parent %s, %.0f cm from its controller", k, fullName(h), root:GetFName():ToString(), shortName(root), sim, par(root),
                    math.sqrt((l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2 + (l.Z - c.Z) ^ 2)))
            else
                log("diag: " .. k .. " none")
            end
        end
        for _, k in ipairs({ "HandMesh-Right", "HandMesh-Left" }) do
            pcall(function() local m = S.pawn[k] log("diag: " .. k .. " visible " .. tostring(m:IsVisible()) .. " parent " .. par(m)) end)
        end
        for _, k in ipairs({ "ActorrefSidearm", "ActorrefLongA", "ActorrefLongB", "KnifeRef", "GUNrefSidearm", "GUNrefLongA", "GUNrefLongB", "HolsterSelectionRight", "HolsterSelectionLeft" }) do
            pcall(function() local a = S.pawn[k] log("diag: " .. k .. " = " .. (valid(a) and fullName(a) or "none")) end)
        end
    end)
    -- what is under the crosshair
    pcall(function()
        local cl, q = viewBasis()
        local fx, fy, fz = qrot(q, 1, 0, 0)
        local hit = {}
        local c0 = { R = 0, G = 0, B = 0, A = 0 }
        local ok = KSL():LineTraceSingle(world, cl, v3(cl.X + fx * 3000, cl.Y + fy * 3000, cl.Z + fz * 3000), 0, false, { S.pawn }, 0, hit, true, c0, c0, 0)
        local actor
        pcall(function() actor = hit.Actor:Get() end)
        log("diag: under the crosshair: " .. tostring(ok) .. " " .. (valid(actor) and fullName(actor) or "-"))
        if valid(actor) then
            local c = actor:GetClass()
            local fns, props = {}, {}
            c:ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end)
            c:ForEachProperty(function(pr) props[#props + 1] = pr:GetFName():ToString() .. ":" .. pr:GetClass():GetFName():ToString() end)
            log("diag:   functions: " .. table.concat(fns, ", "))
            log("diag:   properties: " .. table.concat(props, ", "))
        end
    end)
    pcall(function()
        local cl, q = viewBasis()
        local fx, fy, fz = qrot(q, 1, 0, 0)
        local hit = {}
        local c0 = { R = 0, G = 0, B = 0, A = 0 }
        KSL():LineTraceSingle(world, cl, v3(cl.X + fx * 3000, cl.Y + fy * 3000, cl.Z + fz * 3000), 0, false, { S.pawn }, 0, hit, true, c0, c0, 0)
        local actor = hit.Actor:Get()
        local cs = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))
        cs:ForEach(function(_, e)
            local c = e:get()
            pcall(function()
                local l = c:K2_GetComponentLocation()
                log(string.format("diag:   comp %s (%s) at %.0f %.0f %.0f", c:GetFName():ToString(), shortName(c), l.X, l.Y, l.Z))
            end)
        end)
    end)
    log("diag: ---- end ----")
end
-- after each shot: report where pooled/spawned bullets are relative to the view
local function diagShot()
    local _, q = viewBasis()
    local cl = S.cam:K2_GetComponentLocation()
    for _, cn in ipairs({ "BP_9mm_B_InstantHit_C", "BP_BT_Projectile_Base_C", "BP_5_45_InstantHit_C", "BP_9mm_Bullet_C" }) do
        for i, a in ipairs(FindAllOf(cn) or {}) do
            if i <= 4 and valid(a) and not fullName(a):find("Default__") then
                pcall(function()
                    local l = a:K2_GetActorLocation()
                    local fx, fy, fz = qrot(rq(a:K2_GetActorRotation()), 1, 0, 0)
                    local lx, ly, lz = qrot(qconj(q), l.X - cl.X, l.Y - cl.Y, l.Z - cl.Z)
                    local vx, vy, vz = qrot(qconj(q), fx, fy, fz)
                    local vel = ""
                    pcall(function() local v = a:GetVelocity() local x, y, z = qrot(qconj(q), v.X, v.Y, v.Z) vel = string.format(" vel(view) %.0f %.0f %.0f", x, y, z) end)
                    log(string.format("diag: shot %s pos(view) %.0f %.0f %.0f fwd(view) %.3f %.3f %.3f%s", cn, lx, ly, lz, vx, vy, vz, vel))
                end)
            end
        end
    end
end
-- Click to touch: the hand (left one while you hold a weapon) reaches to what is under the
-- crosshair (up to 2.5 m) and back; its colliders press buttons, arrows, map pictures, door knobs.
-- The basement boards' buttons (loadout arrows, round options) are trigger boxes that react when a VR
-- finger overlaps them. A desktop "touch" hands the nearest such box its own BeginOverlap event, as if
-- the glove's fingertip had touched it (and EndOverlap a moment later).
S.boardFns = {}
S.boardPress = function(pt, useLeft)
    -- every trigger box near the touch point, nearest first
    local cands = {}
    local boxes
    pcall(function() boxes = FindAllOf("BoxComponent") end)
    for _, c in ipairs(boxes or {}) do
        pcall(function()
            local l = c:K2_GetComponentLocation()
            local ext = c:GetScaledBoxExtent()
            local d = math.sqrt((l.X - pt.X) ^ 2 + (l.Y - pt.Y) ^ 2 + (l.Z - pt.Z) ^ 2)
            local r = math.max(ext.X, ext.Y, ext.Z)
            -- the buttons' boxes float a little in front of the drawn arrows (where a VR finger comes from)
            if d < math.max(r + 8, 30) and d < 150 then cands[#cands + 1] = { c = c, d = d } end
        end)
    end
    table.sort(cands, function(x, y) return x.d < y.d end)
    for _, cd in ipairs(cands) do
        local best, bestActor = cd.c, nil
        pcall(function() bestActor = best:GetOwner() end)
        if valid(bestActor) and bestActor ~= nil and fullName(bestActor) ~= S.pawnName then
            local cname = best:GetFName():ToString()
            -- components renamed so far from their event that no prefix matches (loadout board back row)
            cname = ({ backleftbutton = "Box2", backrightbutton = "Box5" })[cname] or cname
            local cls = bestActor:GetClass()
            local key = fullName(cls) .. "|" .. cname
            local fns = S.boardFns[key]
            if not fns then
                fns = {}
                -- the event is named after the component's original name, which may since have been renamed
                -- ("Box1" -> component "Box1lbutton"): take the longest event name the component name starts with
                local bestLen = 0
                pcall(function()
                    cls:ForEachFunction(function(f)
                        local n = f:GetFName():ToString()
                        local tok = n:match("^BndEvt__(.-)_K2Node_ComponentBoundEvent")
                        if tok and cname:sub(1, #tok) == tok and #tok >= bestLen then
                            if #tok > bestLen then fns = {} bestLen = #tok end
                            if n:find("BeginOverlap") then fns.b = n elseif n:find("EndOverlap") then fns.e = n end
                        end
                    end)
                end)
                S.boardFns[key] = fns
            end
            if fns.b then
                local glove = S.pawn[useLeft and "GraspingHandLeft" or "GraspingHandRight"]
                local tip
                pcall(function() tip = glove.Fingertip end)
                local ok, err = pcall(function() bestActor[fns.b](bestActor, best, glove, tip, 0, false, {}) end)
                log(string.format("touch: pressed %s.%s (%.0f cm) %s", shortName(bestActor), cname, cd.d, ok and "ok" or tostring(err)))
                if fns.e then S.boardEnd = { a = bestActor, c = best, fn = fns.e, glove = glove, tip = tip, at = S.now + 0.25 } end
                return ok
            end
        end
    end
    log(string.format("touch: no button near the touch point (%d trigger boxes within reach)", #cands))
    return false
end
local function touchUnderCrosshair(world, useLeft)
    if S.touch then return end   -- one reach at a time
    local cl, q = viewBasis()
    local fx, fy, fz = qrot(q, 1, 0, 0)
    local hit = {}
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local ign = { S.pawn }
    local g = heldActor(S.R)
    if g then ign[2] = g end
    local ok, res = pcall(function()
        return KSL():LineTraceSingle(world, cl, v3(cl.X + fx * 250, cl.Y + fy * 250, cl.Z + fz * 250), 0, false, ign, 0, hit, true, c0, c0, 0)
    end)
    local pt
    if ok and res then pcall(function() pt = v3(hit.ImpactPoint.X, hit.ImpactPoint.Y, hit.ImpactPoint.Z) end) end
    if not pt then pt = v3(cl.X + fx * 60, cl.Y + fy * 60, cl.Z + fz * 60) end
    -- reach a few cm into the surface so the hand's colliders overlap it
    pt = v3(pt.X + fx * 4, pt.Y + fy * 4, pt.Z + fz * 4)
    S.touch = { pt = pt, t0 = S.now, left = useLeft }
    glovesCollide(true)
    local okB, eB = pcall(S.boardPress, pt, useLeft)
    if not okB then log("touch: board press error " .. tostring(eB)) end
    log(string.format("touch (%s hand, %s)", useLeft and "left" or "right", (ok and res) and "hit" or "air"))
end

-- left click with a pipe bomb in the hand: throw a lit one. Lighting/throwing the game's own holster
-- pipe bomb from Lua crashed the game (0.2 s after the throw), so that one goes back to its holster
-- and a fresh, lit pipe bomb is thrown (the same thing the T key does, which is stable).
local function throwHeld()
    local pc = getPC()
    local world = pc and getWorld(pc)
    if not world then return end
    dropRight("holster")
    S.sel = nil
    throwGrenade(world)
end

-- The basement greets you with the "early access" board (BPdisclaimer); in VR you touch its ball.
-- Without hands to reach it, the mod touches it for you once per level.
local function dismissDisclaimer()
    local d = FindFirstOf("BPdisclaimer_C")
    if not valid(d) then return "none" end
    local wall0
    pcall(function() wall0 = d.WALL:K2_GetComponentLocation().Z end)
    local hitOk = pcall(function()
        local b = d.Button
        local l = b:K2_GetComponentLocation()
        d:ReceiveHit(b, S.pawn, S.L, false, l, v3(0, 0, 1), v3(0, 0, 0), {
            bBlockingHit = true, Location = l, ImpactPoint = l, Normal = v3(0, 0, 1), ImpactNormal = v3(0, 0, 1) })
    end)
    local playOk = pcall(function() d.Button_TL:PlayFromStart() end)
    pcall(function() d.Move_TL:PlayFromStart() end)
    return string.format("hit %s, timelines %s (wall z %s)", tostring(hitOk), tostring(playOk), tostring(wall0))
end

local lastWait = -100
-- A level load (map change, menu, death restart) frees every actor of the old level. Calling into
-- one of those afterwards crashes the game (access violation inside UE4SS), so when the world changes
-- every reference is dropped WITHOUT touching the objects.
local function forgetWorld()
    HUD = nil
    S.menu = nil
    S.grenades, S.spawned, S.inv = {}, {}, {}
    S.lastDroppedActor, S.lastDropped = nil, nil
    S.boardEnd, S.touchGlove = nil, nil
    S.vmGun, S.vm, S.aimGun, S.recGun, S.recAmmo = nil, nil, nil, nil, nil
    S.pawn, S.pawnName, S.cam, S.L, S.R, S.Lactor, S.Ractor, S.cm = nil, nil, nil, nil, nil, nil, nil, nil
    S.sel, S.fire.held, S.fire.gun, S.fire.pressedAt = nil, false, nil, nil
    blockInput = false
    CDO = {}
end
local function frame()
    local pc = getPC()
    local world = pc and getWorld(pc)
    local now = world and getTime(world) or os.clock()
    if world then
        local addr
        pcall(function() addr = world:GetAddress() end)
        addr = addr or fullName(world)
        if S.worldAddr ~= addr then
            if S.worldAddr ~= nil then log("new world " .. fullName(world) .. " - dropping old references") end
            S.worldAddr = addr
            forgetWorld()
        end
    end
    local pawn
    if pc then pcall(function() pawn = pc.Pawn end) end

    -- StartMap: leave the menu for the given map once, 2 s after a player controller exists. Without a
    -- headset the menu has no pawn, so this must not wait for one.
    if world and type(CFG.StartMap) == "string" and CFG.StartMap ~= "" and not S.startMapDone then
        S.startMapAt = S.startMapAt or now + 2
        if now >= S.startMapAt then
            S.startMapDone = true
            local cur = fullName(world)
            local short = CFG.StartMap:match("([^/]+)$")
            if not cur:find(short, 1, true) then
                log("opening StartMap " .. CFG.StartMap .. " (current " .. cur .. ")")
                pcall(function() GS():OpenLevel(world, FName(CFG.StartMap), true, "") end)
                return
            end
        end
    end
    if not (pc and world and valid(pawn)) then
        S.pawn = nil
        if S.menu then S.menu = nil pcall(function() HUD.showMenu(false) end) end
        if now - lastWait > 0.5 then
            lastWait = now
            -- without a headset the game may never possess its VR character: find it and possess it
            local found = {}
            if pc then
                for _, cn in ipairs({ "WendigoVrChar_C", "VRBaseCharacter", "BP_VRCharacter_C", "MotionControllerPawn_C" }) do
                    for _, a in ipairs(FindAllOf(cn) or {}) do
                        local n = valid(a) and fullName(a)
                        if n and not n:find("Default__") and not found[n] then
                            found[n] = a
                            found[#found + 1] = n
                        end
                    end
                end
                if #found > 0 then
                    local a = found[found[1]]
                    log("possessing " .. found[1] .. " (" .. #found .. " candidate(s))")
                    local ok, err = pcall(function() pc:Possess(a) end)
                    if not ok then log("Possess failed: " .. tostring(err)) end
                elseif world and not (CFG.StartMap ~= "" and not S.startMapDone) then
                    -- no character at all: 1st try the game mode's RestartPlayer, then spawn the
                    -- Sandbox player class at a PlayerStart ourselves
                    -- count only while this world has had no pawn for a while: a death / level restart
                    -- also leaves no pawn for a moment, and spawning into that transition crashed the game
                    local wn = fullName(world)
                    if S.noPawnWorld ~= wn then S.noPawnWorld, S.noPawnSince, S.spawnTry = wn, now, 0 end
                    local n = 0
                    if now - S.noPawnSince >= 1.0 then S.spawnTry = S.spawnTry + 1 n = S.spawnTry end
                    if n == 1 then
                        local ok, err = pcall(function() GS():GetGameMode(world):RestartPlayer(pc) end)
                        log("no player character: GameMode RestartPlayer -> " .. (ok and "called" or tostring(err)))
                    elseif n >= 2 and n <= 4 then
                        local cls = loadClass(CFG.PlayerClass)
                        local t = xform(0, 0, 200)
                        pcall(function()
                            local ps = FindFirstOf("PlayerStart")
                            if valid(ps) then
                                local l, r = ps:K2_GetActorLocation(), ps:K2_GetActorRotation()
                                t = xform(l.X, l.Y, l.Z, { Pitch = 0, Yaw = r.Yaw, Roll = 0 })
                            end
                        end)
                        local a = cls and spawnActor(world, cls, t, 2)
                        if a then
                            local ok, err = pcall(function() pc:Possess(a) end)
                            log("spawned " .. fullName(a) .. " and possessed it: " .. (ok and "ok" or tostring(err)))
                        else
                            log("could not spawn the player class " .. tostring(CFG.PlayerClass))
                        end
                    end
                end
            end
            if now - (S.waitLogT or 0) > 5 then
                S.waitLogT = now
                log(string.format("waiting for a pawn: controller=%s (%s) world=%s pawn=%s characters=%d", tostring(pc ~= nil),
                    pc and shortName(pc) or "-", world and fullName(world) or "nil", tostring(valid(pawn)), #found))
            end
        end
        return
    end
    S.noPawnWorld = nil
    local dt = clamp(now - (S.now or now), 0, 0.1)
    S.now = now
    S.frames = S.frames + 1
    if now - S.fpsT >= 1 then S.fps = S.frames / (now - S.fpsT) S.frames, S.fpsT = 0, now end

    -- (UE4SS hands out a new Lua wrapper per access, so compare names, not userdata)
    if not valid(S.pawn) or S.pawnName ~= fullName(pawn) then
        hudDestroy()
        setupPawn(pawn, pc, world)
        S.sel, S.ads, S.fovNow = nil, 0, CFG.FOV
        S.disclaimerAt = now + 0.5
        S.inv, S.spawned, S.vmGun, S.vm, S.heldName, S.heldActorRef = {}, {}, nil, nil, nil, nil
        S.handsAt = now + 0.3
        S.handShown = {}
        if CFG.SelfTest == 1 and not test.started and S.R then
            test.started = true
            buildSelfTest()
        end
    end
    if not S.cam then return end

    if now - (S.slotsT or 0) > 1 then
        S.slotsT = now
        local list, sig = {}, {}
        for _, h in ipairs(test.started and {} or HOLSTER_REFS) do
            local a
            pcall(function() a = S.pawn[h[1]] end)
            if valid(a) then
                local cls = shortName(a)
                local row = weaponRowForClass(cls)
                local nm = row and row[1] or prettyClass(cls)
                local gren = cls:find("PipeBomb") ~= nil
                if gren then nm = "Pipe bomb" end
                list[#list + 1] = { name = nm, tag = h[2], ref = (not gren) and h[1] or nil, grenade = gren, label = h[2], w = row or { nm, "", 0, 20, 3 } }
                sig[#sig + 1] = h[1] .. "=" .. cls
            end
        end
        for _, w in ipairs(WEAPONS) do list[#list + 1] = { name = w[1], w = w } sig[#sig + 1] = w[1] end
        local ssig = table.concat(sig, ",")
        if ssig ~= S.slotsSig then
            -- keep the selection on the same weapon
            local selName = S.sel and SLOTS[S.sel] and SLOTS[S.sel].name
            SLOTS = list
            S.sel = nil
            for i, e in ipairs(SLOTS) do if e.name == selName then S.sel = i end end
            if S.slotsSig ~= nil then log("loadout: " .. ssig) end
            S.slotsSig = ssig
            hudDestroy()
        end
    end
    if now - (S.cursorT or 0) > 1 then
        S.cursorT = now
        pcall(function() if pc.bShowMouseCursor ~= (S.menu ~= nil) then pc.bShowMouseCursor = (S.menu ~= nil) end end)
    end
    if S.handsAt and now >= S.handsAt then
        S.handsAt = now + 3   -- the game can respawn its gloves: pin them again every few seconds
        pcall(handsSetup)
    end
    if S.disclaimerAt and now >= S.disclaimerAt then
        S.disclaimerAt = nil
        local ok, r = pcall(dismissDisclaimer)
        if ok and r ~= "none" then log("early-access board acknowledged: " .. r) end
    end

    -- self test drives virtual keys
    if test.started then testRun(now) end

    readKeys(pc)

    -- escape menu: while open it takes the keys (W/S/Up/Down/wheel, Enter/Space/click)
    blockInput = false
    if rawPressed("Escape") then
        if S.menu then
            if S.menu.capture then S.menu.capture = nil
            elseif S.menu.page ~= "main" then menuBack()
            else menuClose() end
        else
            if S.fire.held then fireSet(false) S.fire.held = false end
            menuOpen(world)
        end
    end
    local inMenu = S.menu ~= nil
    if inMenu then
        if S.menu.capture then
            menuCapture(pc)
        else
            local L = menuItems(world, pc)
            local wm = axis(pc, "MouseWheelAxis")
            if wm ~= 0 and now - (S.menuWheelT or 0) < 0.08 then wm = 0 elseif wm ~= 0 then S.menuWheelT = now end
            local sel0 = S.menu.sel
            if rawPressed("W") or rawPressed("Up") or wm > 0 then S.menu.sel = math.max(1, S.menu.sel - 1) end
            if rawPressed("S") or rawPressed("Down") or wm < 0 then S.menu.sel = math.min(#L, S.menu.sel + 1) end
            local row, moved, mdx = menuRowUnderMouse(world)
            if row and moved then
                local idx = S.menu.top + row - 1
                if L[idx] then S.menu.sel = idx end
            end
            if S.menu.sel ~= sel0 then S.menu.quitArm = nil end
            local it = L[S.menu.sel]
            local dir
            if rawPressed("Enter") or rawPressed("SpaceBar") then dir = 1 end
            if rawPressed("LeftMouseButton") and S.menu.bar and S.menuMouseDy and S.menuMouseDy > 276 and S.menuMouseDy < 300
                and math.abs(S.menuMouseDx or 999) <= 290 then
                RADIO.seekFrac(((S.menuMouseDx or 0) + 280) / 560)
            end
            if rawPressed("LeftMouseButton") and row ~= nil then
                -- click: on a value row, the left arrow lowers it and the right arrow raises it
                local cyc = false
                if it and it.act and it.value and S.menu.page ~= "controls" and S.menu.page ~= "songs" then
                    local v = it.value() or ""
                    cyc = v ~= ">" and not v:find("^%[")
                end
                if cyc and mdx and mdx > 60 then dir = (mdx < 205) and -1 or 1 else dir = 1 end
            end
            if it and it.value and (rawPressed("D") or rawPressed("Right")) then dir = 1 end
            if it and it.value and (rawPressed("A") or rawPressed("Left") or (rawPressed("RightMouseButton") and row ~= nil)) then dir = -1 end
            if it and it.act and dir then
                log("menu: " .. S.menu.page .. " / " .. it.label .. " (" .. dir .. ")")
                local okA, eA = pcall(it.act, dir)
                if not okA then log("menu action error: " .. tostring(eA)) end
            end
        end
        if S.menu then
            local okM, eM = pcall(function() menuDraw(menuItems(world, pc)) end)
            if not okM then log("menu error: " .. tostring(eM)) end
        end
        blockInput = S.menu ~= nil   -- no gameplay input behind the menu
    end

    -- toggles
    if pressed(B.NightVision) then toggleNightVision() end
    if pressed(B.Flashlight) then toggleFlashlight() end
    if pressed(B.Grenade) or pressed("MiddleMouseButton") then throwGrenade(world) end
    if pressed("F1") then S.overlay = not S.overlay log("debug text " .. (S.overlay and "ON" or "OFF")) end
    if pressed("F2") then setGod(not S.god) end
    if pressed("F3") then spawnNPC(world) end
    if pressed("F4") then setNoclip(not S.noclip) end
    if pressed("F5") then setSlow(world, not S.slow) end
    if pressed("F6") then S.look = not S.look captureMouse(pc, S.look) log("mouse " .. (S.look and "captured" or "released")) end
    if pressed("F7") then
        S.gameKeys = not S.gameKeys
        setGameKeys(pc, S.gameKeys)
        log("game's own keys " .. (S.gameKeys and "ON" or "OFF"))
    end
    if pressed("F8") then log("STATUS " .. statusLine():gsub("\n", " | ")) end
    if pressed("J") then diagHook() pcall(diagDump, world, pc) S.diagShots = 6 end
    if pressed(B.ResetHands) then S.free.R, S.free.L, S.demo = { 0, 0, 0 }, { 0, 0, 0 }, false end
    for i = 1, 12 do if SLOTS[i] and pressed(B["Slot" .. i]) then equip(i) end end
    if pressed(B.Holster) then dropRight("holster") S.sel = nil end
    if pressed(B.FireMode) then toggleFireMode() end
    if pressed(B.Radio) then RADIO.toggle() end
    if pressed(B.RadioNext) then RADIO.next() end
    RADIO.poll()
    RADIO.noise(world)
    if pressed(B.Interact) then
        local okT, eT = pcall(touchUnderCrosshair, world, heldActor(S.R) ~= nil)
        if not okT then log("touch error: " .. tostring(eT)) end
    end
    if pressed(B.Crack) then useCrack() end
    if pressed(B.Grab) then grabNearest() end
    if pressed(B.Reload) and not S.reloadAnim then
        local g = heldActor(S.R)
        if g and ammoOf(g) then
            if S.fire.held then fireSet(false) S.fire.held = false end
            S.reloadAnim = { t0 = now, gun = g }
            pcall(function() local snd = g.MagEjectSound if valid(snd) then GS():PlaySoundAtLocation(world, snd, g:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil) end end)
        end
    end
    if S.reloadAnim then
        local ra = S.reloadAnim
        if not ra.done and now - ra.t0 > 0.55 then
            ra.done = true
            local h = heldActor(S.R)
            if valid(ra.gun) and h and fullName(h) == fullName(ra.gun) then
                reload(ra.gun)
                pcall(function() local snd = ra.gun.MagInsertSound if valid(snd) then GS():PlaySoundAtLocation(world, snd, ra.gun:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil) end end)
            end
        end
        if now - ra.t0 > 1.1 then S.reloadAnim = nil end
    end
    if pressed(B.Fire) then
        local g = heldActor(S.R)
        local hasMuzzle = false
        pcall(function() hasMuzzle = valid(g.FireDirection) end)
        if g and not hasMuzzle and ammoOf(g) then hasMuzzle = true end   -- e.g. the 12 gauge
        if g and shortName(g):find("PipeBomb") then
            throwHeld()
        elseif g and hasMuzzle and (S.reloadAnim or now - (S.equipT or 0) < 0.3) then
            log("no shot: weapon lowered (reloading / drawing)")
        elseif g and hasMuzzle then
            -- learn the real shot direction from the first rounds of each gun type
            local c = S.calib[shortName(g)]
            if valid(g.FireDirection) and (not c or c[4] < 3) then
                local okS, snap = pcall(bulletSnapshot)
                if okS then S.calibPending = { snap = snap, gun = g, frames = 3 } end
            end
            fireSet(true) S.fire.held = true
        elseif g then
            S.jab = 0.3   -- melee: swing, the hit lands a moment later
            S.meleeAt = now + 0.12
        elseif S.sel and SLOTS[S.sel] and SLOTS[S.sel].grenade then
            throwGrenade(world)
        elseif now - (S.spawnT or 0) > 2 then
            local okT, eT = pcall(touchUnderCrosshair, world, false)   -- empty hand: press / touch what you click on
            if not okT then log("touch error: " .. tostring(eT)) end
        end
    end
    if S.boardEnd and now >= S.boardEnd.at then
        local be = S.boardEnd
        S.boardEnd = nil
        pcall(function() be.a[be.fn](be.a, be.c, be.glove, be.tip, 0) end)
    end
    if S.meleeAt and now >= S.meleeAt then S.meleeAt = nil pcall(meleeHit, world) end
    if S.meleeCheck and now >= S.meleeCheck.at then pcall(meleeFollowUp) end
    if S.calibPending then
        S.calibPending.frames = S.calibPending.frames - 1
        if S.calibPending.frames <= 0 then
            local okC, eC = pcall(calibrateFromShot, S.calibPending)
            if not okC then log("aim calibration error: " .. tostring(eC)) end
            S.calibPending = nil
        end
    end
    if S.crackCheck and now >= S.crackCheck.at then
        local after
        pcall(function() after = num(S.pawn.PlayerHealth) end)
        log("crack: health " .. tostring(S.crackCheck.before) .. " -> " .. tostring(after))
        S.crackCheck = nil
    end
    if released(B.Fire) and S.fire.held then fireSet(false) S.fire.held = false end
    fireCheck()

    -- the game sometimes lets go of a weapon by itself (a fresh character setting up its hands, two-hand
    -- logic): if what we equipped is no longer held and we did not drop it, grip it again
    if S.heldName and S.R and now - (S.regripT or 0) > 0.3 then
        S.regripT = now
        if not heldObject(S.R) then
            local a = S.spawned[S.heldName] or S.heldActorRef
            if valid(a) and (S.regrips or 0) < 2 then
                S.regrips = (S.regrips or 0) + 1
                S.vmGun, S.vm = nil, nil
                pcall(function() local root = a:K2_GetRootComponent() root:SetSimulatePhysics(false) end)
                local ok, how = gripRight(a)
                log("weapon slipped out of the hand - re-grip " .. (ok and "OK" or "failed") .. " (" .. how .. ")")
            elseif not valid(a) or (S.regrips or 0) >= 2 then
                if valid(a) then log("weapon keeps leaving the hand - letting the game have it") end
                S.heldName, S.sel = nil, nil
            end
        else
            S.regrips = 0
        end
    end

    -- count rounds fired (no recoil: the view and the weapon only move when you move them)
    do
        local g = heldActor(S.R)
        local am = g and ammoOf(g)
        local gn = g and fullName(g)
        if gn and gn == S.recGun and am and S.recAmmo and am < S.recAmmo then
            S.shots = (S.shots or 0) + 1
            if (S.diagShots or 0) > 0 then S.diagShots = S.diagShots - 1 pcall(diagShot) end
        end
        S.recGun, S.recAmmo = gn, am
    end

    -- look / free hand / zoom / weapon wheel
    local mx, my = 0, 0
    if S.look and not inMenu then mx, my = axis(pc, "MouseX"), axis(pc, "MouseY") end
    if now - (S.spawnT or 0) < 0.6 or (S.menuClosedT and now - S.menuClosedT < 0.15) then mx, my = 0, 0 end
    mx, my = clamp(mx, -30, 30), clamp(my, -30, 30)
    local wheel = inMenu and 0 or axis(pc, "MouseWheelAxis")
    if (CFG.AimToggle == 1 and pressed(B.Aim)) or pressed(B.AimToggle) then S.aimLatch = not S.aimLatch end
    if CFG.AimToggle ~= 1 and pressed(B.Aim) then S.aimLatch = false end
    local aiming = (S.aimLatch == true or (CFG.AimToggle ~= 1 and down(B.Aim))) and not S.reloadAnim and heldActor(S.R) ~= nil
    local sens = CFG.MouseSensitivity * (S.fovNow / CFG.FOV)   -- slower turning when zoomed in
    if down("LeftAlt") or down("X") then
        local h = down("LeftAlt") and S.free.R or S.free.L
        h[2] = clamp(h[2] + mx * sens * 0.6, -45, 45)
        h[3] = clamp(h[3] + my * sens * 0.6, -45, 45)
        h[1] = clamp(h[1] + wheel * 3, -25, 40)
        mx, my = 0, 0
    else
        S.yaw = normAxis(S.yaw + mx * sens)
        S.pitch = clamp(S.pitch + my * sens, -85, 85)
        -- arrow keys turn too (110 deg/s)
        local kt = ((down("Right") and 1 or 0) - (down("Left") and 1 or 0)) * 110 * dt
        local kp = ((down("Up") and 1 or 0) - (down("Down") and 1 or 0)) * 80 * dt
        if kt ~= 0 then S.yaw = normAxis(S.yaw + kt) end
        if kp ~= 0 then S.pitch = clamp(S.pitch + kp, -85, 85) end
        if wheel ~= 0 then
            if aiming then
                S.aimFov = clamp((S.aimFov or CFG.AimFOV) - wheel * 5, 15, CFG.FOV - 5)   -- zoom in / out
            elseif now - (S.wheelT or 0) > 0.12 then
                S.wheelT = now
                local n = #SLOTS
                local cur = S.sel or 0
                equip(((cur - 1 + (wheel < 0 and 1 or -1)) % n) + 1)
            end
        end
    end
    S.ads = clamp(S.ads + (aiming and 1 or -1) * dt * 7, 0, 1)
    local ease = S.ads * S.ads * (3 - 2 * S.ads)
    local fov = CFG.FOV + ((S.aimFov or CFG.AimFOV) - CFG.FOV) * ease
    if math.abs(fov - (S.fovSet or -1)) > 0.01 then
        S.fovSet = fov
        pcall(function() S.cam:SetFieldOfView(fov) end)
    end
    S.fovNow = fov

    -- movement
    local f = (down(B.Forward) and 1 or 0) - (down(B.Back) and 1 or 0)
    local r = (down(B.Right) and 1 or 0) - (down(B.Left) and 1 or 0)
    local yr = S.yaw * DEG
    local crouchKey = down(B.Crouch)
    S.viewStill = (mx == 0 and my == 0 and f == 0 and r == 0)
    if S.noclip then
        local q = rotToQuat(S.pitch, S.yaw, 0)
        local fx, fy, fz = qrot(q, 1, 0, 0)
        local u = (down(B.Jump) and 1 or 0) - (crouchKey and 1 or 0)
        local sp = CFG.NoclipSpeed * (down(B.Sprint) and 2 or 1) * dt
        local dx = (fx * f - math.sin(yr) * r) * sp
        local dy = (fy * f + math.cos(yr) * r) * sp
        local dz = (fz * f + u) * sp
        if dx ~= 0 or dy ~= 0 or dz ~= 0 then
            local p = pawn:K2_GetActorLocation()
            pcall(function() pawn:K2_SetActorLocation(v3(p.X + dx, p.Y + dy, p.Z + dz), false, {}, true) end)
        end
        pcall(function() S.cm.Velocity = v3(0, 0, 0) end)
    else
        if S.cm and S.baseSpeed then
            local want = (CFG.WalkSpeed > 0 and CFG.WalkSpeed or S.baseSpeed) * ((down(B.Sprint) and not aiming and not crouchKey) and CFG.SprintMultiplier or 1)
            if crouchKey then want = want * 0.55 end
            pcall(function() if S.cm.MaxWalkSpeed ~= want then S.cm.MaxWalkSpeed = want end end)
        end
        if f ~= 0 or r ~= 0 then
            local dx, dy = math.cos(yr) * f - math.sin(yr) * r, math.sin(yr) * f + math.cos(yr) * r
            local n = math.sqrt(dx * dx + dy * dy)
            dx, dy = dx / n, dy / n
            if S.cm then
                pcall(function() pawn:AddMovementInput(v3(dx, dy, 0), 1.0, true) end)
            else  -- pawn without a movement component (VR template hub pawn)
                local sp = 250 * (down(B.Sprint) and CFG.SprintMultiplier or 1) * dt
                local p = pawn:K2_GetActorLocation()
                pcall(function() pawn:K2_SetActorLocation(v3(p.X + dx * sp, p.Y + dy * sp, p.Z), true, {}, false) end)
            end
        end
        if pressed(B.Jump) then pcall(function() pawn:Jump() end) end
    end
    local wantCrouch = (crouchKey and not S.noclip) and CFG.CrouchDrop or 0
    S.crouch = S.crouch + (wantCrouch - S.crouch) * math.min(1, dt * 12)

    -- pawn + camera
    pcall(function() pawn:K2_SetActorRotation({ Pitch = 0, Yaw = S.yaw, Roll = 0 }, false) end)
    pcall(function() pc:SetControlRotation({ Pitch = S.pitch, Yaw = S.yaw, Roll = 0 }) end)
    -- military-style view bob: a dip on every step, a sway from foot to foot and a little roll;
    -- faster and heavier when sprinting, mostly gone when aiming
    local movingNow = (f ~= 0 or r ~= 0) and not S.noclip
    local onGround = true
    pcall(function() onGround = not S.cm:IsFalling() end)
    local sprintNow = movingNow and down(B.Sprint) and S.ads < 0.1 and not crouchKey
    S.camBobT = (S.camBobT or 0) + ((movingNow and onGround) and dt * (sprintNow and 11.5 or 7.5) or 0)
    local bobWant = (movingNow and onGround) and CFG.ViewBob * (sprintNow and 1.8 or 1) * (1 - 0.8 * S.ads) or 0
    S.camBob = (S.camBob or 0) + (bobWant - (S.camBob or 0)) * math.min(1, dt * 6)
    local bt = S.camBobT
    local bobZ = -math.abs(math.sin(bt)) * S.camBob
    local bobY = math.sin(bt) * S.camBob * 0.45
    local bobRoll = math.sin(bt) * S.camBob * 0.35
    local bobPitch = -math.abs(math.cos(bt)) * S.camBob * 0.15
    S.camRelP = { 0, bobY, CFG.EyeHeight - S.crouch + bobZ }
    S.camRelQ = rotToQuat(S.pitch + bobPitch, 0, bobRoll)
    pcall(function()
        S.cam:K2_SetRelativeLocationAndRotation(v3(S.camRelP[1], S.camRelP[2], S.camRelP[3]), quatToRot(S.camRelQ), false, {}, true)
    end)

    -- god mode keeps health full
    if S.god then
        pcall(function()
            pawn.Invincible = true
            if pawn.PlayerHealth < pawn.playerhealthmax then pawn.PlayerHealth = pawn.playerhealthmax end
        end)
    end

    pcall(aimTrace, world)
    pcall(grenadeTick)
    updateHands(dt, mx, my, (f ~= 0 or r ~= 0) and not S.noclip)

    local okH, eH = pcall(hudUpdate, world, pc)
    if not okH and now - (S.hudErrT or 0) > 5 then S.hudErrT = now log("HUD error: " .. tostring(eH)) end
    if S.popupMsg then hudPopup(S.popupMsg) S.popupMsg = nil end
    if S.overlay and now - S.lastLog > 2 then S.lastLog = now log("overlay: " .. statusLine():gsub("\n", " | ")) end
end

local frameErrors = 0
LoopInGameThreadAfterFrames(1, function()
    local ok, err = pcall(frame)
    if not ok then
        frameErrors = frameErrors + 1
        if frameErrors < 20 or frameErrors % 600 == 0 then log("frame error: " .. tostring(err)) end
    end
    return false
end)
log("BTDesktop 1.3.2 loaded. SelfTest=" .. tostring(CFG.SelfTest) .. ". Keys: Esc > Controls, or README.md in the BTDesktop mod folder")
