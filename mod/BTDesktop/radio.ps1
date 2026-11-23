# BloodTrail Desktop radio player.
# Plays the music files in the game folder's Music folder through the Windows media player engine (WinRT MediaPlayer),
# hidden, started by the mod (M key / Esc > Radio). The mod controls it through a command file and
# reads a status file and a song list:
#   commands (one line, "<seq> <command>"): play N | next | prev | toggle | pause | resume | seek MS |
#             speed X | vol 0-100 | shuffle 0/1 | stop
#   status:   mode|index|position ms|length ms|speed|volume|shuffle|title|artist|album
#   list:     one line per song: title|artist|album|length text|file name
# Quits by itself when the game closes.
param([string]$Music, [string]$Cmd, [string]$Status, [string]$List)
$ErrorActionPreference = "SilentlyContinue"

$null = [Windows.Media.Playback.MediaPlayer, Windows.Media, ContentType = WindowsRuntime]
$null = [Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]
$player = New-Object Windows.Media.Playback.MediaPlayer

function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }

if (-not (Test-Path -LiteralPath $Music)) { New-Item -ItemType Directory -Force $Music | Out-Null }
$exts = @(".mp3", ".wav", ".wma", ".m4a", ".aac", ".flac", ".mid")
$files = @(Get-ChildItem -LiteralPath $Music -File -Recurse | Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name)
if ($files.Count -eq 0) { Write-Utf8 $Status "nomusic|-1|0|0|1|0|0|NO MUSIC - put songs in the Music folder||"; exit }

# song details from the Windows shell (Title, Contributing artists, Album, Length columns)
$songs = @()
$shell = New-Object -ComObject Shell.Application
$cols = @{}
foreach ($f in $files) {
    $folder = $shell.Namespace($f.DirectoryName)
    if ($cols.Count -eq 0) {
        for ($i = 0; $i -lt 330; $i++) {
            $h = $folder.GetDetailsOf($null, $i)
            if ($h -and -not $cols.ContainsKey($h)) { $cols[$h] = $i }
        }
    }
    $item = $folder.ParseName($f.Name)
    function Col($name) { if ($cols.ContainsKey($name)) { return ($folder.GetDetailsOf($item, $cols[$name]) -replace "[|\r\n]", " ").Trim() } return "" }
    $title = Col "Title"; if (-not $title) { $title = $f.BaseName }
    $artist = Col "Contributing artists"; if (-not $artist) { $artist = Col "Album artist" }
    $songs += [pscustomobject]@{ File = $f.FullName; Title = $title; Artist = $artist; Album = (Col "Album"); Length = (Col "Length") }
}
Write-Utf8 $List (($songs | ForEach-Object { "$($_.Title)|$($_.Artist)|$($_.Album)|$($_.Length)|$([IO.Path]::GetFileName($_.File))" }) -join "`n")

$vol = 60; $speed = 1.0; $shuffle = $true; $idx = -1; $lastCmd = ""; $paused = $false; $started = $false
function Open-Song([int]$n) {
    $script:idx = (($n % $songs.Count) + $songs.Count) % $songs.Count
    $player.Source = [Windows.Media.Core.MediaSource]::CreateFromUri([Uri]$songs[$script:idx].File)
    $player.Volume = $script:vol / 100.0
    $player.PlaybackSession.PlaybackRate = $script:speed
    $player.Play()
    $script:paused = $false
    $script:started = $false
}
function Next-Song {
    if ($shuffle -and $songs.Count -gt 1) { $n = $idx; while ($n -eq $idx) { $n = Get-Random -Maximum $songs.Count }; Open-Song $n }
    else { Open-Song ($idx + 1) }
}
function Read-Cmd { try { return [IO.File]::ReadAllText($Cmd).Trim() } catch { return "" } }

Next-Song
$tick = 0
while ($true) {
    Start-Sleep -Milliseconds 200
    $tick++
    if (($tick % 10) -eq 0 -and -not (Get-Process -Name "BTVR-Win64-Shipping" -ErrorAction SilentlyContinue)) { break }
    $c = Read-Cmd
    if ($c -and $c -ne $lastCmd) {
        $lastCmd = $c
        $parts = $c -split " ", 3
        $verb = if ($parts.Count -ge 2) { $parts[1] } else { "" }
        $arg = if ($parts.Count -ge 3) { $parts[2] } else { "" }
        switch ($verb) {
            "stop"    { $player.Pause(); $player.Dispose(); Write-Utf8 $Status "off|-1|0|0|1|0|0|||"; exit }
            "next"    { Next-Song }
            "prev"    { Open-Song ($idx - 1) }
            "play"    { Open-Song ([int]$arg) }
            "pause"   { $player.Pause(); $paused = $true }
            "resume"  { $player.Play(); $paused = $false }
            "toggle"  { if ($paused) { $player.Play(); $paused = $false } else { $player.Pause(); $paused = $true } }
            "seek"    { $player.PlaybackSession.Position = [TimeSpan]::FromMilliseconds([double]$arg) }
            "speed"   { $speed = [double]::Parse($arg, [Globalization.CultureInfo]::InvariantCulture); $player.PlaybackSession.PlaybackRate = $speed }
            "vol"     { $vol = [int]$arg; $player.Volume = $vol / 100.0 }
            "shuffle" { $shuffle = ($arg -eq "1") }
        }
    }
    $ps = $player.PlaybackSession
    $st = [string]$ps.PlaybackState
    $pos = [int64]$ps.Position.TotalMilliseconds
    $len = [int64]$ps.NaturalDuration.TotalMilliseconds
    if ($st -eq "Playing") { $started = $true }
    # song finished (the player pauses at the end): next one
    if ($started -and -not $paused -and $st -ne "Playing" -and $len -gt 0 -and $pos -ge $len - 400) { Next-Song; continue }
    $mode = if ($paused) { "paused" } elseif ($st -eq "Playing") { "playing" } else { $st.ToLower() }
    $s = $songs[$idx]
    Write-Utf8 $Status ("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}" -f $mode, $idx, $pos, $len, $speed.ToString([Globalization.CultureInfo]::InvariantCulture), $vol, [int]$shuffle, $s.Title, $s.Artist, $s.Album)
}
$player.Dispose()
