#Requires -Version 5.1
<#
.SYNOPSIS
    sping - Continuous ping monitor with live dashboard, sound alerts and logging.

.PARAMETER Target
    Hostname or IP address to ping.

.PARAMETER n
    Number of pings to send. Default: 0 (unlimited).

.PARAMETER i
    Interval between pings in milliseconds. Default: 1000.

.PARAMETER w
    Timeout per ping in milliseconds. Default: 3000.

.PARAMETER NoSound
    Disable sound alerts on status changes.

.PARAMETER NoLog
    Disable automatic logging (logging is on by default).

.EXAMPLE
    sping google.de
    sping 192.168.1.1 -i 500
    sping server01 -n 20
    sping 8.8.8.8 -NoSound -NoLog
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Target,

    [Parameter()]
    [int]$n = 0,           # 0 = unlimited

    [Parameter()]
    [int]$i = 1000,        # interval ms

    [Parameter()]
    [int]$w = 3000,        # timeout ms

    [Parameter()]
    [switch]$NoSound,

    [Parameter()]
    [switch]$NoLog
)

# ─────────────────────────────────────────────────────────────────────────────
#  Config
# ─────────────────────────────────────────────────────────────────────────────
$VERSION      = '1.0.0'
$HISTORY_SIZE = 300   # how many pings to keep for the sparkline

# ─────────────────────────────────────────────────────────────────────────────
#  State object
# ─────────────────────────────────────────────────────────────────────────────
$stats = [PSCustomObject]@{
    Sent             = 0
    Received         = 0
    Lost             = 0
    LastStatus       = 'unknown'   # previous cycle
    CurrentStatus    = 'unknown'   # this cycle
    StartTime        = [datetime]::Now
    LastChange       = $null       # datetime of last status change
    LatencyHistory   = [System.Collections.Generic.List[object]]::new()
    MinLatency       = [int]::MaxValue
    MaxLatency       = 0
    TotalLatency     = 0L
    ConsecutiveFails = 0
}

$dashboardOrigin = $null
$logFile         = $null

# ─────────────────────────────────────────────────────────────────────────────
#  Resolve host
# ─────────────────────────────────────────────────────────────────────────────
$resolvedIP = $null
try {
    $dnsResult  = [System.Net.Dns]::GetHostEntry($Target)
    $resolvedIP = ($dnsResult.AddressList | Select-Object -First 1).ToString()
} catch {
    if ($Target -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $resolvedIP = $Target
    } else {
        Write-Host "sping: Cannot resolve hostname '$Target'." -ForegroundColor Red
        exit 1
    }
}

$displayTarget = if ($Target -eq $resolvedIP) { $Target } else { "$Target  [$resolvedIP]" }

# ─────────────────────────────────────────────────────────────────────────────
#  Logging  (StreamWriter keeps file open – avoids Add-Content collisions)
# ─────────────────────────────────────────────────────────────────────────────
$logWriter = $null
if (-not $NoLog) {
    $safeTarget = $Target -replace '[^\w\-\.]', '_'
    $logDir  = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logFile = Join-Path $logDir "sping_${safeTarget}_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    try {
        $logWriter = [System.IO.StreamWriter]::new($logFile, $true, [System.Text.Encoding]::UTF8)
        $logWriter.AutoFlush = $true
        $logWriter.WriteLine(
            "# sping v$VERSION  |  Session started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Target: $displayTarget"
        )
    } catch {
        Write-Host "Warning: Could not open log file: $_" -ForegroundColor Yellow
        $logWriter = $null
        $logFile   = $null
    }
}

function Write-Log ([string]$msg) {
    if ($logWriter) { try { $logWriter.WriteLine($msg) } catch { } }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Sound  (synchronous – only fires on rare status changes)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Sound ([string]$type) {
    if ($NoSound) { return }
    switch ($type) {
        'online'  {
            # Ascending major arpeggio – C E G C  (positive, "success")
            [Console]::Beep(523, 120)   # C5
            [Console]::Beep(659, 120)   # E5
            [Console]::Beep(784, 120)   # G5
            [Console]::Beep(1047, 1350)  # C6
        }
        'offline' {
            # Descending minor sequence – A F D A  (ominous, "warning")
            [Console]::Beep(440, 200)   # A4
            [Console]::Beep(349, 200)   # F4
            [Console]::Beep(294, 200)   # D4
            [Console]::Beep(220, 1600)   # A3 – long final low note
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────────────────────
function Format-Duration ([timespan]$ts) {
    if ($ts.TotalHours -ge 1) { return $ts.ToString('hh\:mm\:ss') }
    return $ts.ToString('mm\:ss')
}

function Format-Ago ([datetime]$t) {
    $d = [datetime]::Now - $t
    if ($d.TotalSeconds -lt 60)  { return "$([int]$d.TotalSeconds)s" }
    if ($d.TotalMinutes -lt 60)  { return "$([int]$d.TotalMinutes)m $($d.Seconds)s" }
    return "$([int]$d.TotalHours)h $($d.Minutes)m"
}

function Get-Sparkline ([int]$maxChars) {
    $bars   = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $block  = [char]0x2588   # █ used for failed pings
    $count  = $stats.LatencyHistory.Count
    $take   = [Math]::Min($maxChars, $count)
    $items  = if ($take -gt 0) { $stats.LatencyHistory.GetRange($count - $take, $take) } else { @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($val in $items) {
        if ($null -eq $val) {
            $result.Add([PSCustomObject]@{ Ch = $block; Fail = $true })
        } else {
            $m   = [Math]::Max($stats.MaxLatency, 1)
            $idx = [int](($val / $m) * ($bars.Length - 1))
            $idx = [Math]::Max(0, [Math]::Min($idx, $bars.Length - 1))
            $result.Add([PSCustomObject]@{ Ch = $bars[$idx]; Fail = $false })
        }
    }
    # Comma operator forces return as array – prevents PS unrolling a single item
    # into a bare PSCustomObject (which has no .Count, breaking padding arithmetic)
    return ,$result.ToArray()
}

# ─────────────────────────────────────────────────────────────────────────────
#  Dashboard
# ─────────────────────────────────────────────────────────────────────────────
$spinner = [char[]]@('|', '/', '-', '\')
$spinIdx = 0

function Draw-Dashboard {
    # First call: save cursor position; subsequent calls: return there
    if ($null -eq $script:dashboardOrigin) {
        $script:dashboardOrigin = $Host.UI.RawUI.CursorPosition
    } else {
        $Host.UI.RawUI.CursorPosition = $script:dashboardOrigin
    }

    $W = [Math]::Min($Host.UI.RawUI.WindowSize.Width - 1, 114)
    $inner = $W - 2   # usable width between borders

    $isOnline      = $stats.CurrentStatus -eq 'online'
    $statusColor   = if ($isOnline) { 'Green' } else { 'Red' }
    $statusDot     = if ($isOnline) { [char]0x25CF } else { [char]0x25CB }  # ● / ○
    $statusLabel   = if ($isOnline) { 'ONLINE ' } else { 'OFFLINE' }

    $elapsed   = [datetime]::Now - $stats.StartTime
    $spin      = $spinner[$script:spinIdx % $spinner.Length]
    $script:spinIdx++

    $hLine  = [string]([char]0x2550) * ($W - 2)   # ═
    $tl     = [char]0x2554  # ╔
    $tr     = [char]0x2557  # ╗
    $bl     = [char]0x255A  # ╚
    $br     = [char]0x255D  # ╝
    $ml     = [char]0x2560  # ╠
    $mr     = [char]0x2563  # ╣
    $vl     = [char]0x2551  # ║

    function Row ([string]$content, [string]$color = 'White') {
        Write-Host "$vl" -NoNewline -ForegroundColor DarkCyan
        $cell = $content.PadRight($inner).Substring(0, [Math]::Min($content.Length, $inner)).PadRight($inner)
        Write-Host $cell -NoNewline -ForegroundColor $color
        Write-Host "$vl" -ForegroundColor DarkCyan
    }

    # Header bar
    Write-Host "$tl$hLine$tr" -ForegroundColor DarkCyan

    # Title
    Row " sping v$VERSION  |  $displayTarget" 'Cyan'

    Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan

    # Status line
    Write-Host "$vl " -NoNewline -ForegroundColor DarkCyan
    Write-Host "Status: $statusDot $statusLabel" -NoNewline -ForegroundColor $statusColor
    $rt    = Format-Duration $elapsed
    $time  = (Get-Date).ToString('HH:mm:ss')
    $right = "  Runtime: $rt   $spin $time"
    # 1(space) + 8("Status: ") + 1(dot) + 1(space) + 7(label) = 18 chars already written
    $pad   = $inner - 18 - $right.Length
    Write-Host "$right$(' ' * [Math]::Max(0,$pad))" -NoNewline -ForegroundColor Gray
    Write-Host "$vl" -ForegroundColor DarkCyan

    # Last change
    if ($stats.LastChange) {
        $ago = Format-Ago $stats.LastChange
        Row " Last change: $ago ago  (-> $($stats.CurrentStatus.ToUpper()))" 'DarkGray'
    } else {
        Row " No status change yet" 'DarkGray'
    }

    Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan

    # Statistics
    $pct      = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Lost    / $stats.Sent) } else { '0.0' }
    $uptime   = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Received / $stats.Sent) } else { '100.0' }
    $avgLat   = if ($stats.Received -gt 0) { '{0:F1}' -f ($stats.TotalLatency / $stats.Received) } else { '—' }
    $minLat   = if ($stats.MinLatency -eq [int]::MaxValue) { '—' } else { "$($stats.MinLatency) ms" }
    $maxLat   = if ($stats.MaxLatency -eq 0 -and $stats.Received -eq 0) { '—' } else { "$($stats.MaxLatency) ms" }
    $pctStr    = $pct    + '%'
    $uptimeStr = $uptime + '%'

    $s = $stats.Sent; $r = $stats.Received; $l = $stats.Lost
    Row (" Sent: $($s.ToString().PadLeft(6))  Received: $($r.ToString().PadLeft(6))  Lost: $($l.ToString().PadLeft(5)) ($pctStr)")

    Row (" Latency: ~ $avgLat  |  Min: $minLat  |  Max: $maxLat  |  Uptime: $uptimeStr")

    Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan

    # Sparkline – label row
    $sparkWidth = $inner
    $histShown  = [Math]::Min($sparkWidth, $stats.LatencyHistory.Count)
    Row " History (last $histShown pings):" 'DarkGray'
    # Sparkline – bar row (full inner width)
    # Build coloured segments, then flush per-colour run to avoid per-char wrap artifacts
    $spark      = Get-Sparkline $sparkWidth   # always returns object[]
    $barCount   = $spark.Length               # use .Length – safe for any array
    $sparPad    = [Math]::Max(0, $sparkWidth - $barCount)
    Write-Host "$vl" -NoNewline -ForegroundColor DarkCyan
    $runBuf  = [System.Text.StringBuilder]::new()
    $runFail = $null
    foreach ($item in $spark) {
        if ($null -eq $runFail) { $runFail = $item.Fail }
        if ($item.Fail -eq $runFail) {
            $null = $runBuf.Append([string]$item.Ch)
        } else {
            $runCol = if ($runFail) { 'Red' } else { 'Green' }
            Write-Host $runBuf.ToString() -NoNewline -ForegroundColor $runCol
            $runBuf.Clear() | Out-Null
            $runFail = $item.Fail
            $null = $runBuf.Append([string]$item.Ch)
        }
    }
    if ($runBuf.Length -gt 0) {
        $runCol = if ($runFail) { 'Red' } else { 'Green' }
        Write-Host $runBuf.ToString() -NoNewline -ForegroundColor $runCol
    }
    # Padding + right border as one call so the border char is never alone at the
    # terminal edge (prevents auto-wrap placing it at col 0 of the following row)
    Write-Host (' ' * $sparPad) -NoNewline
    Write-Host "$vl" -ForegroundColor DarkCyan

    # Footer
    Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan
    $logNote = if ($logFile) { "Log: $(Split-Path $logFile -Leaf)" } else { 'Logging: off' }
    Row " [Ctrl+C to quit]   $logNote" 'DarkGray'
    Write-Host "$bl$hLine$br" -ForegroundColor DarkCyan
}

# ─────────────────────────────────────────────────────────────────────────────
#  Ping engine  (uses .NET directly for accurate RTT)
# ─────────────────────────────────────────────────────────────────────────────
$pingOptions = New-Object System.Net.NetworkInformation.PingOptions
$pingOptions.Ttl = 128
$pingBuffer  = [byte[]]::new(32)

function Invoke-SinglePing {
    # Ping.Send / SendPingAsync both rely on IcmpSendEcho2 (Win32), which hangs
    # indefinitely when the NIC is physically disconnected – no timeout fires.
    # Fix: run the blocking Send on a background Runspace thread and enforce a
    # hard wall-clock deadline via AsyncWaitHandle.WaitOne().  If we time out,
    # Stop() the runspace and return FAIL so the main loop keeps going.
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        param($ip, $timeout, $buf, $opts)
        $ping = [System.Net.NetworkInformation.Ping]::new()
        try {
            $r = $ping.Send($ip, $timeout, $buf, $opts)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                return [PSCustomObject]@{ Success = $true; Latency = [int]$r.RoundtripTime }
            }
        } catch { }
        finally { $ping.Dispose() }
        return [PSCustomObject]@{ Success = $false; Latency = $null }
    }).AddArgument($resolvedIP).AddArgument($w).AddArgument($pingBuffer).AddArgument($pingOptions)

    $handle   = $ps.BeginInvoke()
    $deadline = $w + 1500    # hard ceiling: ping timeout + 1.5 s grace
    $done     = $handle.AsyncWaitHandle.WaitOne($deadline)

    $pingResult = [PSCustomObject]@{ Success = $false; Latency = $null }
    if ($done) {
        try {
            $out = $ps.EndInvoke($handle)
            if ($out.Count -gt 0) { $pingResult = $out[0] }
        } catch { }
    } else {
        try { $ps.Stop() } catch { }   # abandon the stuck thread
    }
    try { $ps.Dispose() } catch { }
    try { $rs.Dispose() } catch { }
    return $pingResult
}

# ─────────────────────────────────────────────────────────────────────────────
#  Summary (printed on exit)
# ─────────────────────────────────────────────────────────────────────────────
function Write-Summary {
    $totalTime = [datetime]::Now - $stats.StartTime
    $pct      = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Lost    / $stats.Sent) } else { '0.0' }
    $uptime   = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Received / $stats.Sent) } else { '100.0' }
    $avgLat   = if ($stats.Received -gt 0) { '{0:F1}' -f ($stats.TotalLatency / $stats.Received) } else { '—' }
    $minLat   = if ($stats.MinLatency -eq [int]::MaxValue) { '—' } else { "$($stats.MinLatency) ms" }
    $maxLat   = if ($stats.MaxLatency -eq 0 -and $stats.Received -eq 0) { '—' } else { "$($stats.MaxLatency) ms" }
    $pctStr    = $pct    + '%'
    $uptimeStr = $uptime + '%'

    Write-Host ""
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  sping Summary: $displayTarget" -ForegroundColor Cyan
    Write-Host "  Runtime  : $(Format-Duration $totalTime)" -ForegroundColor White
    Write-Host "  Sent     : $($stats.Sent)    Received: $($stats.Received)    Lost: $($stats.Lost) ($pctStr)" -ForegroundColor White
    Write-Host "  Uptime   : $uptimeStr" -ForegroundColor White
    Write-Host "  Latency  : ~ $avgLat  |  Min: $minLat  |  Max: $maxLat" -ForegroundColor White
    if ($logFile) {
        Write-Host "  Log      : $logFile" -ForegroundColor DarkGray
    }
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}

# ─────────────────────────────────────────────────────────────────────────────
#  Main loop
# ─────────────────────────────────────────────────────────────────────────────
try { [Console]::CursorVisible = $false } catch { }
Clear-Host
Write-Host ""    # margin so dashboard doesn't start at line 0

Write-Log ""
Write-Log ("# Interval: {0}ms  |  Timeout: {1}ms  |  Count: {2}" -f $i, $w, $(if ($n -eq 0) {'unlimited'} else {$n}))

try {
    $lastDraw = [datetime]::MinValue

    while ($true) {
        $cycleStart = [datetime]::Now

        # ── Ping ──────────────────────────────────────────────────────────────
        $result    = Invoke-SinglePing
        $timestamp = [datetime]::Now
        $stats.Sent++

        if ($result.Success) {
            $stats.Received++
            $stats.ConsecutiveFails = 0
            $stats.CurrentStatus    = 'online'
            $lat                    = $result.Latency
            $stats.TotalLatency    += $lat
            if ($lat -lt $stats.MinLatency) { $stats.MinLatency = $lat }
            if ($lat -gt $stats.MaxLatency) { $stats.MaxLatency = $lat }
            $null = $stats.LatencyHistory.Add($lat)
            Write-Log ("[{0}] OK      {1,5} ms" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff'), $lat)
        } else {
            $stats.Lost++
            $stats.ConsecutiveFails++
            $stats.CurrentStatus = 'offline'
            $null = $stats.LatencyHistory.Add($null)
            Write-Log ("[{0}] FAIL    timeout" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff'))
        }

        # keep history bounded
        while ($stats.LatencyHistory.Count -gt $HISTORY_SIZE) { $stats.LatencyHistory.RemoveAt(0) }

        # ── Status change? ────────────────────────────────────────────────────
        if ($stats.CurrentStatus -ne $stats.LastStatus -and $stats.LastStatus -ne 'unknown') {
            $stats.LastChange = $timestamp
            $changeMsg = "[{0}] ### STATUS CHANGE: {1} -> {2} ###" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss'), $stats.LastStatus.ToUpper(), $stats.CurrentStatus.ToUpper()
            Write-Log $changeMsg
            Invoke-Sound $stats.CurrentStatus
        }
        $stats.LastStatus = $stats.CurrentStatus

        # ── Redraw dashboard (every second) ───────────────────────────────────
        if (([datetime]::Now - $lastDraw).TotalMilliseconds -ge 900 -or $stats.Sent -eq 1) {
            Draw-Dashboard
            $lastDraw = [datetime]::Now
        }

        # ── Stop if -n reached ────────────────────────────────────────────────
        if ($n -gt 0 -and $stats.Sent -ge $n) { break }

        # ── Wait remaining interval ───────────────────────────────────────────
        $spent = ([datetime]::Now - $cycleStart).TotalMilliseconds
        $wait  = [int][Math]::Max(0, $i - $spent)
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch { }

    # Move cursor below the dashboard before printing summary
    $bottom = $script:dashboardOrigin
    if ($bottom) {
        $bottom.Y += 17
        try { $Host.UI.RawUI.CursorPosition = $bottom } catch { Write-Host "" }
    }

    Write-Summary

    Write-Log ""
    $endMsg = "# Session ended: {0}  |  Sent: {1}  Received: {2}  Lost: {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $stats.Sent, $stats.Received, $stats.Lost
    Write-Log $endMsg

    if ($logWriter) { try { $logWriter.Close(); $logWriter.Dispose() } catch { } }
}
