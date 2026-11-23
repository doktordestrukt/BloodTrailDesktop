# BloodTrail Desktop radio: plays the music files in the game folder's Music folder (shuffled) with the
# Windows Media Player engine. Started hidden by the mod (M key / Esc > Radio); controlled through a small
# command file (stop / next / vol N); quits by itself when the game closes.
param([string]$Music, [string]$Cmd, [string]$Status)
$ErrorActionPreference = "SilentlyContinue"
function Set-Status([string]$t) { [IO.File]::WriteAllText($Status, $t) }
if (-not (Test-Path -LiteralPath $Music)) { New-Item -ItemType Directory -Force $Music | Out-Null }
$exts = @(".mp3", ".wav", ".wma", ".m4a", ".flac", ".aac", ".ogg")
$files = @(Get-ChildItem -LiteralPath $Music -File -Recurse | Where-Object { $exts -contains $_.Extension.ToLower() })
if ($files.Count -eq 0) { Set-Status "NO MUSIC - put songs in $Music"; exit }
$wmp = New-Object -ComObject WMPlayer.OCX
$wmp.settings.autoStart = $true
$vol = 60
$lastCmd = ""
function Read-Cmd {
    $c = ""
    try { $c = [IO.File]::ReadAllText($Cmd).Trim() } catch {}
    return $c
}
while ($true) {
    foreach ($f in ($files | Get-Random -Count $files.Count)) {
        $wmp.URL = $f.FullName
        $wmp.settings.volume = $vol
        $wmp.controls.play()
        Set-Status $f.BaseName
        $started = $false
        for ($i = 0; ; $i++) {
            Start-Sleep -Milliseconds 300
            if (-not (Get-Process -Name "BTVR-Win64-Shipping" -ErrorAction SilentlyContinue)) { $wmp.controls.stop(); exit }
            $c = Read-Cmd
            if ($c -ne $lastCmd) {
                $lastCmd = $c
                if ($c -eq "stop") { $wmp.controls.stop(); Set-Status "OFF"; exit }
                if ($c -like "vol *") { $vol = [int]($c.Substring(4)); $wmp.settings.volume = $vol }
                if ($c -like "next*") { break }
            }
            $st = $wmp.playState   # 3 = playing, 1 = stopped, 8 = ended
            if ($st -eq 3) { $started = $true }
            if ($started -and ($st -eq 1 -or $st -eq 8)) { break }
            if (-not $started -and $i -gt 40) { break }   # file would not play: skip it
        }
    }
}
