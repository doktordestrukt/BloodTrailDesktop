# BloodTrail Desktop installer.
# Finds Blood Trail, installs UE4SS if it is missing (bundled, checksum-verified), installs the
# BTDesktop mod and keeps the game's sound on without a headset. Nothing in the game's own files is
# changed or replaced. Run through Install.bat / Uninstall.bat, or:
#   powershell -ExecutionPolicy Bypass -File installer\install.ps1 [-GameDir <path>] [-Uninstall] [-ResetConfig] [-Quiet]
param(
    [string]$GameDir = "",
    [switch]$Uninstall,
    [switch]$ResetConfig,   # replace an existing (edited) BTDesktop.ini with the default one
    [switch]$KeepUE4SS,     # uninstall: leave UE4SS in place even if this installer put it there
    [switch]$Quiet          # no folder picker, no prompts (for scripts / tests)
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Version = "1.3.2"
$UE4SSZip = Join-Path $Root "third_party\ue4ss\UE4SS_v3.0.1-1181-g83330635.zip"
$UE4SSSha = "b9a166a756605b21058a64cde93bcaab1a855dba3553e5c7e6ce0fa8fdfad7b9"
$Marker = ".installed-by-btdesktop"

function Say([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }
function Ok([string]$t)   { Write-Host "  [ OK ] " -ForegroundColor Red -NoNewline; Write-Host $t }
function Info([string]$t) { Write-Host "  [ .. ] " -ForegroundColor DarkRed -NoNewline; Write-Host $t -ForegroundColor Gray }
function Fail([string]$t) { Write-Host ""; Write-Host "  [FAIL] $t" -ForegroundColor Red; Write-Host ""; exit 1 }

function Banner {
    Write-Host ""
    Write-Host "  ____  _                 _ _____          _ _ " -ForegroundColor Red
    Write-Host " | __ )| | ___   ___   __| |_   _| __ __ _(_) |" -ForegroundColor Red
    Write-Host " |  _ \| |/ _ \ / _ \ / _`` | | || '__/ _`` | | |" -ForegroundColor Red
    Write-Host " | |_) | | (_) | (_) | (_| | | || | | (_| | | |" -ForegroundColor DarkRed
    Write-Host " |____/|_|\___/ \___/ \__,_| |_||_|  \__,_|_|_|" -ForegroundColor DarkRed
    Write-Host "  // D E S K T O P   v$Version  -  keyboard + mouse, no headset" -ForegroundColor White
    Write-Host "  ---------------------------------------------------------------" -ForegroundColor DarkRed
    Write-Host ""
}

# ------------------------------------------------------------------ find the game
function Test-GameDir([string]$d) {
    return $d -and (Test-Path -LiteralPath (Join-Path $d "BTVR\Binaries\Win64\BTVR-Win64-Shipping.exe"))
}
function Find-Game {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($k in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $roots.Add(($v -replace '/', '\')) } }
        } catch {}
    }
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        $libs.Add($r)
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $vdf), '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $d = Join-Path $l "steamapps\common\Blood Trail"
        if (Test-GameDir $d) { return $d }
    }
    # common places, every drive
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        foreach ($sub in @("SteamLibrary\steamapps\common\Blood Trail", "Steam\steamapps\common\Blood Trail",
                           "Program Files (x86)\Steam\steamapps\common\Blood Trail", "Games\Blood Trail")) {
            $d = Join-Path $drv $sub
            if (Test-GameDir $d) { return $d }
        }
    }
    return $null
}
function Pick-Folder {
    Add-Type -AssemblyName System.Windows.Forms
    $f = New-Object System.Windows.Forms.FolderBrowserDialog
    $f.Description = "Select your Blood Trail folder (the one that contains BTVR)"
    $f.ShowNewFolderButton = $false
    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $f.SelectedPath }
    return $null
}

# ------------------------------------------------------------------ sound without a headset
# The game ships UnfocusedVolumeMultiplier=0.0. Without a headset it never gets "VR focus", so the
# engine treats it as unfocused and mutes everything. Override that in the user's own Engine.ini
# (%LOCALAPPDATA%, not a game file); uninstall removes it again.
function Set-DesktopAudio([bool]$on) {
    $cfg = Join-Path $env:LOCALAPPDATA "BTVR\Saved\Config\WindowsNoEditor\Engine.ini"
    if (-not (Test-Path (Split-Path $cfg))) {
        if (-not $on) { return }
        New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
    }
    $lines = @()
    if (Test-Path $cfg) { $lines = @(Get-Content -LiteralPath $cfg) }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -like ';BTDesktop-begin*') { $skip = $true; continue }
        if ($l -like ';BTDesktop-end*') { $skip = $false; continue }
        if ($skip) { continue }
        # the engine can rewrite Engine.ini and drop the comment markers: remove our section anyway
        if ($l -eq '[Audio]' -and ($i + 1) -lt $lines.Count -and $lines[$i + 1] -eq 'UnfocusedVolumeMultiplier=1.0') { $i++; continue }
        $out.Add($l)
    }
    if ($on) {
        $out.Add(";BTDesktop-begin (desktop play: keep the game's sound without VR focus)")
        $out.Add("[Audio]")
        $out.Add("UnfocusedVolumeMultiplier=1.0")
        $out.Add(";BTDesktop-end")
    }
    [IO.File]::WriteAllLines($cfg, $out, (New-Object Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ main
Banner

if (Get-Process -Name "BTVR-Win64-Shipping", "BTVR" -ErrorAction SilentlyContinue) {
    Fail "Blood Trail is running. Close the game first, then run this again."
}

if ($GameDir) {
    if (-not (Test-GameDir $GameDir)) { Fail "Not a Blood Trail folder: $GameDir" }
} else {
    Info "Looking for Blood Trail (Steam libraries)..."
    $GameDir = Find-Game
    if (-not $GameDir -and -not $Quiet) {
        Info "Not found automatically - pick the Blood Trail folder."
        $GameDir = Pick-Folder
    }
    if (-not (Test-GameDir $GameDir)) { Fail "Blood Trail was not found. Run again with -GameDir `"<your Blood Trail folder>`"." }
}
Ok "Game: $GameDir"

$Win64 = Join-Path $GameDir "BTVR\Binaries\Win64"
$UE    = Join-Path $Win64 "ue4ss"
$Mods  = Join-Path $UE "Mods"
$Dst   = Join-Path $Mods "BTDesktop"

if ($Uninstall) {
    if (Test-Path -LiteralPath $Dst) { Remove-Item -Recurse -Force -LiteralPath $Dst; Ok "Removed the BTDesktop mod" }
    else { Info "BTDesktop mod was not installed" }
    Set-DesktopAudio $false
    Ok "Removed the desktop sound setting from Engine.ini"
    if (-not $KeepUE4SS -and (Test-Path -LiteralPath (Join-Path $UE $Marker))) {
        # only if nothing else uses it: other mods (folders that did not come with UE4SS) keep it
        $stock = @("BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod",
                   "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod", "shared")
        $others = @(Get-ChildItem -Directory -LiteralPath $Mods -ErrorAction SilentlyContinue | Where-Object { $stock -notcontains $_.Name })
        if ($others.Count -eq 0) {
            Remove-Item -Recurse -Force -LiteralPath $UE
            $proxy = Join-Path $Win64 "dwmapi.dll"
            if (Test-Path -LiteralPath $proxy) { Remove-Item -Force -LiteralPath $proxy }
            Ok "Removed UE4SS (it was installed by this installer and no other mod uses it)"
        } else {
            Info "Kept UE4SS: other mods use it ($(($others | ForEach-Object Name) -join ', '))"
        }
    }
    Write-Host ""
    Say "  BloodTrail Desktop is uninstalled. The game is back to VR as normal." "White"
    Write-Host ""
    exit 0
}

# --- UE4SS
$haveUE = (Test-Path -LiteralPath (Join-Path $UE "UE4SS.dll")) -or (Test-Path -LiteralPath (Join-Path $Win64 "UE4SS.dll"))
if ($haveUE) {
    Ok "UE4SS found - keeping it"
    if (-not (Test-Path -LiteralPath $Mods)) {
        if (Test-Path -LiteralPath (Join-Path $Win64 "Mods")) { $Mods = Join-Path $Win64 "Mods"; $Dst = Join-Path $Mods "BTDesktop" }
        else { New-Item -ItemType Directory -Force $Mods | Out-Null }
    }
} else {
    if (Test-Path -LiteralPath (Join-Path $Win64 "dwmapi.dll")) {
        Fail "Another mod already uses dwmapi.dll (the name UE4SS needs). Remove it or install UE4SS yourself, then run this again."
    }
    if (-not (Test-Path -LiteralPath $UE4SSZip)) { Fail "The bundled UE4SS zip is missing: $UE4SSZip" }
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $UE4SSZip).Hash.ToLower()
    if ($sha -ne $UE4SSSha) { Fail "UE4SS zip checksum mismatch - refusing to install it" }
    Info "Installing UE4SS 3.0.1 (checksum verified)..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($UE4SSZip)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }                      # folder entry
            if ($e.FullName -like "*.exe") { continue }          # never put executables into the game
            $target = [IO.Path]::GetFullPath((Join-Path $Win64 $e.FullName))
            if (-not $target.StartsWith([IO.Path]::GetFullPath($Win64))) { continue }
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
    # Blood Trail is UE 4.27.2: pin it instead of auto-detecting (known-good setting)
    $set = Join-Path $UE "UE4SS-settings.ini"
    $t = [IO.File]::ReadAllText($set)
    $t = $t -replace '(?m)^MajorVersion =[ \t]*(?=\r?$)', 'MajorVersion = 4'
    $t = $t -replace '(?m)^MinorVersion =[ \t]*(?=\r?$)', 'MinorVersion = 27'
    [IO.File]::WriteAllText($set, $t, (New-Object Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $UE $Marker) -Value "UE4SS was installed by BloodTrail Desktop $Version" -Encoding ASCII
    Ok "UE4SS installed"
}

# --- the mod
$Src = Join-Path $Root "mod\BTDesktop"
New-Item -ItemType Directory -Force (Join-Path $Dst "Scripts") | Out-Null
Copy-Item -Force (Join-Path $Src "Scripts\main.lua") (Join-Path $Dst "Scripts\main.lua")
Copy-Item -Force (Join-Path $Src "README.md") (Join-Path $Dst "README.md")
Copy-Item -Force (Join-Path $PSScriptRoot "fix_sound.ps1") (Join-Path $Dst "fix_sound.ps1")
Copy-Item -Force (Join-Path $Src "radio.ps1") (Join-Path $Dst "radio.ps1")
$music = Join-Path $GameDir "Music"
if (-not (Test-Path -LiteralPath $music)) { New-Item -ItemType Directory -Force $music | Out-Null }
Set-Content -LiteralPath (Join-Path $music "PUT YOUR MUSIC HERE.txt") -Value "BloodTrail Desktop radio: put mp3 / wav / wma / m4a / flac files in this folder, then press M in game (or Esc > Radio)." -Encoding ASCII
Ok "Radio music folder: $music"
$ini = Join-Path $Dst "BTDesktop.ini"
if ((Test-Path -LiteralPath $ini) -and -not $ResetConfig) {
    Ok "Kept your BTDesktop.ini (use -ResetConfig for the default one)"
} else {
    $text = [IO.File]::ReadAllText((Join-Path $Src "BTDesktop.ini"))
    [IO.File]::WriteAllText($ini, $text, (New-Object Text.UTF8Encoding($false)))   # UTF-8 without BOM
}
New-Item -ItemType File -Force (Join-Path $Dst "enabled.txt") | Out-Null
Ok "BTDesktop mod installed to $Dst"

# --- VR co-op mod: two mods both driving the pawn do not mix
$btt = Join-Path $Mods "BloodTrailTogether\enabled.txt"
if (Test-Path -LiteralPath $btt) {
    Info "Note: BloodTrail Together is enabled too. For desktop play you can disable it (rename its enabled.txt)."
}

Set-DesktopAudio $true
Ok "Game sound kept on without a headset (Engine.ini override in %LOCALAPPDATA%)"

Write-Host ""
Say "  INSTALLED." "Red"
Write-Host ""
Say "  Last step, once:  Steam -> right-click Blood Trail -> Properties -> Launch Options:" "White"
Say "                    -nohmd" "Red"
Say "  (so SteamVR stays closed). Then start the game from Steam and click into its window." "Gray"
Say "  No sound? Run FixSound.bat while the game is running." "Gray"
Write-Host ""
exit 0
