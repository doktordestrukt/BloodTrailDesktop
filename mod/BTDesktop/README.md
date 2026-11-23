# BloodTrail Desktop - mod folder

Play Blood Trail with keyboard and mouse and no headset. This is the installed mod folder
(`ue4ss\Mods\BTDesktop`). Project page, installer and updates:
https://github.com/doktordestrukt/BloodTrailDesktop

- `Scripts\main.lua` - the mod
- `BTDesktop.ini` - your settings (kept when you update)
- `fix_sound.ps1` - unmutes the game in the Windows Volume Mixer (run it while the game runs)
- `enabled.txt` - delete it to switch the mod off without uninstalling

## Start without a headset

1. Recommended, so SteamVR does not start at all: Steam -> right-click Blood Trail -> Properties ->
   General -> Launch Options: `-nohmd`. (Arguments passed on the command line or to `BTVR.exe` are
   dropped: the game's Steam DRM relaunches it through Steam, which only passes these launch options.)
2. Start the game from Steam. You start in the basement (the game's hub). Without a headset the game
   never spawns a player, so about 1.5 s after a level loads the mod asks the game mode to
   `RestartPlayer` and, if that does nothing, spawns `WendigoVrChar_C` at the PlayerStart and possesses
   it. It then switches the HMD off (`EnableHMD(false)` + `stereo off`) and takes over camera and hands.
   `StartMap` (e.g. `/Game/Maps/Sandbox/Map_Sandbox`) starts on another map instead; Esc changes maps.
   The basement's "early access" board (touch the ball, in VR) is acknowledged for you.
3. Click into the game window once so it captures the mouse.

## Keys

| Key | Action |
|---|---|
| W A S D | move (relative to where you look) |
| Mouse | look (yaw turns the pawn, pitch tilts the view; slower while zoomed) |
| Arrow keys | turn / look up and down (keyboard alternative to the mouse) |
| Shift | sprint (not while aiming or crouching) |
| Ctrl | crouch (head 60 cm lower) |
| Space | jump (noclip: fly up) |
| Right mouse (hold) / Z (toggle) | aim down sights: zoom to `AimFOV`, sights centred under the white crosshair |
| Mouse wheel while aiming | zoom in / out (15 - 85 degrees) |
| Mouse wheel | next / previous weapon on the loadout bar |
| 1 - 9, 0, -, = | take out the weapon in that slot (slots 10-12: 0, -, =; the knife and bat are on 0 and -). The first slots are the weapons in your holsters (chosen on the basement's WEAPON LOADOUT board: HIP, BACK, LEFT), then the spawnable ones. The same gun comes back each time |
| Left mouse | trigger of the held gun, a melee swing that really hits, throw a held pipe bomb - or with empty hands: touch what you click on |
| E | touch / press what is under the crosshair (buttons, board arrows, map pictures, door knobs): the hand reaches out and back (the left hand while you hold a weapon) |
| B | fire mode: SEMI -> BURST -> AUTO (the gun's own `Firingmode`) |
| R | reload: the weapon dips down, the magazine is swapped, it comes back up (no shooting while lowered) |
| M | radio on / off: plays the music in the game folder's `Music` folder; enemies hear it (Esc > Radio: volume, next song, on/off for enemies) |
| . (period) | radio: next song |
| H | crack (the game's own heal, `InhaleCrackSmoke`) |
| N | night vision |
| F | flashlight (head lamp) |
| T or middle mouse | throw a lit pipe bomb |
| Esc | menu: resume, restart, change map (21 maps), WATCH (health, crack, kills, score...), GRAPHICS, CONTROLS (rebind every key), GAMEPLAY |
| Q | holster: put the weapon away (kept for next time - no new gun, no new magazine) |
| G | grab the grippable thing nearest your line of sight (up to 3 m), or drop what you hold |
| Alt + mouse (+ wheel) | move the right hand freely (left/right, up/down, wheel = forward/back) |
| X + mouse (+ wheel) | move the left hand freely |
| V | reset both hands (also stops the self test's hand waving) |
| F1 | debug text on/off (position, yaw/pitch, fps, health, held items, fov; also logged every 2 s) |
| F2 | god mode (`Invincible` + health kept full) |
| F3 | spawn an AI NPC (`BP_NPC_Man`) 3.5 m in front of you |
| F4 | noclip (fly through walls; Space up, Ctrl/C down, Shift faster) |
| F5 | slow motion (global time dilation 0.25) |
| F6 | release / capture the mouse |
| F7 | turn the game's own pawn keyboard keys back on / off |
| F8 | write a status line to the log |
| J | write diagnostics (HUD, held gun, damage table, bullets) to the log |

Avoid Ctrl+H / Ctrl+J: those are UE4SS dump keys.

## Menu and settings

Esc opens the menu. GRAPHICS changes the engine's quality settings (preset, view distance, shadows,
anti-aliasing, textures, effects, post processing, foliage, shading, resolution scale, vsync, frame
limit, window mode, field of view). CONTROLS rebinds every key (pick a row, press the new key) and
sets mouse sensitivity and hold/toggle aiming. GAMEPLAY: aim zoom, view bob, walk/sprint speed, eye
height, crosshair, gloves, god mode. WATCH shows what the wrist watch shows in VR. Everything is saved
in `BTDesktop.ini` (keys as `Key_<Action>=`).

## Radio

Put music files (mp3, wav, wma, m4a, flac) in the `Music` folder inside the Blood Trail game folder
(the installer creates it) and press M. Songs play shuffled through a small hidden player (`radio.ps1`)
that stops when you press M again or close the game. While it plays, enemies hear a noise at your
position every second: the louder the volume, the further away they hear it.

## Sound

If the game is silent, check the Windows Volume Mixer: Windows remembers a mute per program, and
Blood Trail was muted there. `fix_sound.ps1` (in the mod folder) lists where the game's sound goes
and unmutes it while the game runs:
`powershell -ExecutionPolicy Bypass -File fix_sound.ps1`.

Also, the game ships `UnfocusedVolumeMultiplier=0.0`. Without a headset it never gets "VR focus", so the
engine treats it as unfocused and mutes everything. the installer adds
`[Audio] UnfocusedVolumeMultiplier=1.0` to your own `%LOCALAPPDATA%\BTVR\Saved\Config\WindowsNoEditor\Engine.ini`
(not a game file) and uninstalling removes it.

## HUD (black and red, 2D)

- Bottom centre: loadout bar (holster slots, then the spawnable weapons); the current weapon's slot is red.
- Bottom right: weapon name, fire mode (SEMI / BURST / AUTO), rounds / magazine size, bullet ticks.
- Bottom left: health number and bar.
- Centre: a white crosshair. It is where the rounds go: the muzzle is turned towards the point under it.
- A weapon name pops up when you switch. Top right: GOD / NOCLIP / SLOW-MO. Top left: debug text (F1).

It is a real 2D UMG HUD: one of the game's own widget classes (`WB_AmmoCounter`) is created only as a
host and its widget tree is replaced by the mod's canvas, images and text blocks. Screen space, so it
never clips into the world, is not darkened by dark maps and does not need night vision.

## Weapons (number keys)

The loadout bar starts with your holster slots (HIP, BACK, LEFT - set them on the basement's WEAPON
LOADOUT board, the arrows work with a click), then these spawnable weapons:

| Weapon | Class |
|---|---|
| Glock | `/Game/VRExpansion/Guns/skeletalguns/bp_skel_glock.bp_skel_glock_C` |
| 92FS | `.../skeletalguns/bp_skel_92fs.bp_skel_92fs_C` |
| AK | `.../skeletalguns/bp_Skel_ak.bp_Skel_ak_C` |
| AR | `.../skeletalguns/BP_SkelARNEW.BP_SkelARNEW_C` |
| Vector | `.../skeletalguns/bp_skel_vector.bp_skel_vector_C` |
| Shotgun | `.../skeletalguns/bp_Skel_shotgun.bp_Skel_shotgun_C` |
| Hunting knife | `/Game/VRExpansion/Guns/BT_MeleeWeapons/WendigoWeapons/NewWeapons/Bp_HuntingKnife_V3.Bp_HuntingKnife_V3_C` |
| Bat | `/Game/VRExpansion/Guns/BT_MeleeWeapons/WendigoWeapons/BatBP.BatBP_C` |

## How it works

- Pawn: `WendigoVrChar_C` (VRExpansion `VRCharacter`). Movement uses `AddMovementInput`; the view
  sets `VRReplicatedCamera`'s relative location (eye height) and pitch, and the actor's yaw.
- Hands: `LeftMotionController` / `RightMotionController` are posed every frame in body space (the
  pawn's NetSmoother, the camera's parent), so they move with you in the same frame: no lag or jitter
  while walking. The pawn's own rigid hand meshes (`HandMesh-Left/Right`) are shown; the game's
  physics gloves (`GraspingHand`), which chased the controllers and flew off, are pinned to the
  controllers invisibly and only collide while reaching to touch something. Unarmed, the hands hang at
  your sides. No mouse sway and no recoil: the weapon only moves when you move.
- View bob: a dip on every step, sway from foot to foot and a little roll; heavier when sprinting,
  mostly off when aiming. Sprinting lowers the weapon to a low-ready.
- Grip: the weapon is spawned once per slot and gripped through the pawn's `TryToGrabObject`
  (fallbacks: `GripOrDropObjectClean`, `GripObjectByInterface`, `GripObject`). Holstering hides it and
  keeps it, so switching back gives the same gun with its ammo and fire mode, and no new magazines.
- Viewmodel: the game's grip is paused (`SetGripPaused`; the weapon stays in the grip list = still held
  for the game) and the weapon's physics and collision are off. The game
  keeps the weapon on the right controller with its own grip offset; the mod measures that offset each
  frame and poses the controller so the weapon lands exactly where it should (camera-space pose), so it
  stays perfectly still in view while you walk, strafe or turn. The muzzle
  (`FireDirection`) is always turned towards the point under the crosshair (camera line trace,
  smoothed). Measured from the game's pooled bullets: rounds leave exactly along `FireDirection`, so
  shots land on the crosshair. Aiming down sights puts each weapon's sights under the crosshair
  (per-weapon sight height / offset, checked in game for every gun).
- Both hands: the left controller goes to the fore-end of long guns (lower while aiming so the glove
  does not cover the sights) and cups the grip of pistols; the gun is marked `Stabilized`.
- Trigger: the pawn's `UseHeldItems(hand, pressed)` (hold for auto / burst). Fire modes are the gun's
  `Firingmode`: measured 0 = full auto, 1 = semi, 2 = 3-round burst.
- Reload: magazine and gun ammo full, bolt released, round chambered (works from empty).
- Melee: the swing traces from the eye; a hit goes to the NPC's `BludgeonDamage` / `StabbingDamage`,
  and if the NPC did not register it, to its damage event (the path the game's bullets use).
- Crack: the pawn's own `InhaleCrackSmoke`.

## Settings (`BTDesktop.ini` in the installed mod folder)

`DisableHMD`, `BlockGameKeys`, `EyeHeight`, `CrouchDrop`, `MouseSensitivity`, `SprintMultiplier`,
`NoclipSpeed`, `SelfTest`, `SelfTestEnd`, `StartMap`, `PlayerClass`, `FOV`, `AimFOV`, `AimGunDistance`,
`AimToggle`, `Hud`, `RigidGrip`, `MeleePitch`, `MeleeDamage`, `WalkSpeed`, `SprintMultiplier`, `ViewBob`. See the comments in the file.
`SelfTest` must stay 0 for normal play (it presses keys for you for about two minutes).

## Self test

With `SelfTest=1` the mod presses its own virtual keys once the pawn
exists and checks every feature (eye height, headset off, walk, sprint, strafe, mouse yaw/pitch,
crouch, jump, hands, aim, free hand, equip, reload, hip aim, aim down sights, zoom, fire, other weapons,
holster, drop, grab, god mode, NPC spawn, noclip, slow motion, HUD, weapon wheel, debug text).
Results go to `ue4ss\UE4SS.log` as `[BTDesktop] TEST <name> PASS|FAIL <detail>` and finish with
`SELFTEST DONE pass=N fail=M`. With `SelfTestEnd=hold` it then keeps the glock in hand, waves both
hands and turns god mode on.
