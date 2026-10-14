#Requires -Version 5.1
<#
.SYNOPSIS
    sping - Continuous ping monitor with live dashboard, sound alerts and logging.

.PARAMETER Target
    One or more hostnames or IP addresses to ping.

.PARAMETER List
    Name of a target list in sping.ini next to this script.

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
    sping google.de 8.8.8.8
    sping -l itcs
    sping 192.168.1.1 -i 500
    sping server01 -n 20
    sping 8.8.8.8 -NoSound -NoLog
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Target,

    [Parameter()]
    [Alias('l')]
    [string]$List,

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
$VERSION      = '1.1.0'
$HISTORY_SIZE = 300   # how many pings to keep for the sparkline

# ─────────────────────────────────────────────────────────────────────────────
#  State object
# ─────────────────────────────────────────────────────────────────────────────
$targetStates    = [System.Collections.Generic.List[object]]::new()
$dashboardOrigin = $null
$dashboardHeight = 0
$logFile         = $null

# ─────────────────────────────────────────────────────────────────────────────
#  Resolve targets
# ─────────────────────────────────────────────────────────────────────────────
if ($List) {
    if ($Target.Count -gt 0) {
        Write-Host 'sping: Use either -l <list> or direct targets, not both.' -ForegroundColor Red
        exit 1
    }

    $listFile = Join-Path $PSScriptRoot 'sping.ini'
    if (-not (Test-Path -LiteralPath $listFile -PathType Leaf)) {
        Write-Host "sping: Target list file not found: $listFile" -ForegroundColor Red
        exit 1
    }

    $listTargets = [System.Collections.Generic.List[string]]::new()
    $currentSection = ''
    $foundRequestedList = $false
    foreach ($line in [System.IO.File]::ReadAllLines($listFile)) {
        $trimmedLine = $line.Trim()
        if (-not $trimmedLine -or $trimmedLine.StartsWith(';') -or $trimmedLine.StartsWith('#')) { continue }

        if ($trimmedLine -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].Trim()
            if ([string]::Equals($currentSection, $List, [System.StringComparison]::OrdinalIgnoreCase)) {
                $foundRequestedList = $true
            }
            continue
        }

        if ($trimmedLine -match '^([^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2]
            $isListSection = [string]::Equals($currentSection, 'lists', [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($currentSection, 'targets', [System.StringComparison]::OrdinalIgnoreCase)
            $isNamedList = $isListSection -and
                [string]::Equals($key, $List, [System.StringComparison]::OrdinalIgnoreCase)
            $isLegacyList = [string]::Equals($currentSection, $List, [System.StringComparison]::OrdinalIgnoreCase) -and
                $key -match '^targets?$'
            if ($isNamedList -or $isLegacyList) {
                $foundRequestedList = $true
                foreach ($listTarget in ($value -split ',')) {
                    $listTarget = $listTarget.Trim()
                    if ($listTarget) { $listTargets.Add($listTarget) }
                }
            }
        }
    }

    if (-not $foundRequestedList) {
        Write-Host "sping: List '$List' was not found in $listFile." -ForegroundColor Red
        exit 1
    }
    if ($listTargets.Count -eq 0) {
        Write-Host "sping: List '$List' contains no targets." -ForegroundColor Red
        exit 1
    }
    $Target = $listTargets.ToArray()
} elseif ($Target.Count -eq 0) {
    Write-Host 'sping: Provide targets or use -l <list>.' -ForegroundColor Red
    exit 1
}

foreach ($targetValue in $Target) {
    foreach ($targetName in ($targetValue -split ',')) {
        $targetName = $targetName.Trim()
        if (-not $targetName) { continue }

        $parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($targetName, [ref]$parsedAddress)) {
            $resolvedIP = $parsedAddress.ToString()
        } else {
            try {
                $dnsResult  = [System.Net.Dns]::GetHostEntry($targetName)
                $resolvedIP = ($dnsResult.AddressList | Select-Object -First 1).ToString()
            } catch {
                Write-Host "sping: Cannot resolve hostname '$targetName'." -ForegroundColor Red
                exit 1
            }
        }

        $displayTarget = if ($targetName -eq $resolvedIP) { $targetName } else { "$targetName [$resolvedIP]" }
        $stats = [PSCustomObject]@{
            Sent             = 0
            Received         = 0
            Lost             = 0
            LastStatus       = 'unknown'
            CurrentStatus    = 'unknown'
            StartTime        = [datetime]::Now
            LastChange       = $null
            LastLatency      = $null
            LatencyHistory   = [System.Collections.Generic.List[object]]::new()
            MinLatency       = [int]::MaxValue
            MaxLatency       = 0
            TotalLatency     = 0L
            ConsecutiveFails = 0
        }
        $targetStates.Add([PSCustomObject]@{
            Name         = $targetName
            ResolvedIP   = $resolvedIP
            Display      = $displayTarget
            Stats        = $stats
        })
    }
}
if ($targetStates.Count -eq 0) {
    Write-Host 'sping: At least one target is required.' -ForegroundColor Red
    exit 1
}
$sessionStartTime = [datetime]::Now
foreach ($targetState in $targetStates) { $targetState.Stats.StartTime = $sessionStartTime }

# ─────────────────────────────────────────────────────────────────────────────
#  Logging  (StreamWriter keeps file open – avoids Add-Content collisions)
# ─────────────────────────────────────────────────────────────────────────────
$logWriter = $null
if (-not $NoLog) {
    $safeTarget = if ($targetStates.Count -eq 1) {
        $targetStates[0].Name -replace '[^\w\-\.]', '_'
    } else {
        'multiple_targets'
    }
    $logDir  = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logFile = Join-Path $logDir "sping_${safeTarget}_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    try {
        $logWriter = [System.IO.StreamWriter]::new($logFile, $true, [System.Text.Encoding]::UTF8)
        $logWriter.AutoFlush = $true
        $logWriter.WriteLine(
            "# sping v$VERSION  |  Session started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  Targets: $(($targetStates.Display) -join ', ')"
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

function Get-Sparkline ([int]$maxChars, $targetStats) {
    $bars   = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $block  = [char]0x2588   # █ used for failed pings
    $count  = $targetStats.LatencyHistory.Count
    $take   = [Math]::Min($maxChars, $count)
    $items  = if ($take -gt 0) { $targetStats.LatencyHistory.GetRange($count - $take, $take) } else { @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($val in $items) {
        if ($null -eq $val) {
            $result.Add([PSCustomObject]@{ Ch = $block; Fail = $true })
        } else {
            $m   = [Math]::Max($targetStats.MaxLatency, 1)
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

    $stats = $targetStates[0].Stats
    $displayTarget = $targetStates[0].Display

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

    if ($targetStates.Count -gt 1) {
        $script:dashboardHeight = ($targetStates.Count * 8) + 7
        Write-Host "$tl$hLine$tr" -ForegroundColor DarkCyan
        Row " sping v$VERSION  |  $($targetStates.Count) targets" 'Cyan'
        Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan

        foreach ($targetState in $targetStates) {
            $targetStats = $targetState.Stats
            $isTargetOnline = $targetStats.CurrentStatus -eq 'online'
            $targetColor = if ($isTargetOnline) { 'Green' } else { 'Red' }
            $targetDot = if ($isTargetOnline) { [char]0x25CF } else { [char]0x25CB }
            $targetStatus = if ($isTargetOnline) { 'ONLINE' } else { 'OFFLINE' }
            $targetElapsed = [datetime]::Now - $targetStats.StartTime

            Row " $($targetState.Display)" 'Cyan'
            Row " Status: $targetDot $targetStatus   Runtime: $(Format-Duration $targetElapsed)   $((Get-Date).ToString('HH:mm:ss'))" $targetColor
            if ($targetStats.LastChange) {
                Row " Last change: $(Format-Ago $targetStats.LastChange) ago  (-> $($targetStats.CurrentStatus.ToUpper()))" 'DarkGray'
            } else {
                Row ' No status change yet' 'DarkGray'
            }

            $pct = if ($targetStats.Sent -gt 0) { '{0:F1}' -f (100.0 * $targetStats.Lost / $targetStats.Sent) } else { '0.0' }
            $uptime = if ($targetStats.Sent -gt 0) { '{0:F1}' -f (100.0 * $targetStats.Received / $targetStats.Sent) } else { '100.0' }
            $avgLat = if ($targetStats.Received -gt 0) { '{0:F1}' -f ($targetStats.TotalLatency / $targetStats.Received) } else { '—' }
            $minLat = if ($targetStats.MinLatency -eq [int]::MaxValue) { '—' } else { "$($targetStats.MinLatency) ms" }
            $maxLat = if ($targetStats.MaxLatency -eq 0 -and $targetStats.Received -eq 0) { '—' } else { "$($targetStats.MaxLatency) ms" }
            Row (" Sent: {0,6}  Received: {1,6}  Lost: {2,5} ({3}%)" -f $targetStats.Sent, $targetStats.Received, $targetStats.Lost, $pct)
            Row " Latency: ~ $avgLat  |  Min: $minLat  |  Max: $maxLat  |  Uptime: $uptime%"

            $sparkWidth = $inner
            $histShown = [Math]::Min($sparkWidth, $targetStats.LatencyHistory.Count)
            Row " History (last $histShown pings):" 'DarkGray'
            $spark = Get-Sparkline $sparkWidth $targetStats
            Write-Host "$vl" -NoNewline -ForegroundColor DarkCyan
            $runBuf = [System.Text.StringBuilder]::new()
            $runFail = $null
            foreach ($item in $spark) {
                if ($null -eq $runFail) { $runFail = $item.Fail }
                if ($item.Fail -eq $runFail) {
                    $null = $runBuf.Append([string]$item.Ch)
                } else {
                    Write-Host $runBuf.ToString() -NoNewline -ForegroundColor $(if ($runFail) { 'Red' } else { 'Green' })
                    $runBuf.Clear() | Out-Null
                    $runFail = $item.Fail
                    $null = $runBuf.Append([string]$item.Ch)
                }
            }
            if ($runBuf.Length -gt 0) {
                Write-Host $runBuf.ToString() -NoNewline -ForegroundColor $(if ($runFail) { 'Red' } else { 'Green' })
            }
            Write-Host (' ' * [Math]::Max(0, $sparkWidth - $spark.Length)) -NoNewline
            Write-Host "$vl" -ForegroundColor DarkCyan
            Write-Host "$ml$hLine$mr" -ForegroundColor DarkCyan
        }

        $elapsed = [datetime]::Now - $targetStates[0].Stats.StartTime
        Row " [Ctrl+C to quit]   Runtime: $(Format-Duration $elapsed)   $(if ($logFile) { Split-Path $logFile -Leaf } else { 'Logging: off' })" 'DarkGray'
        Write-Host "$bl$hLine$br" -ForegroundColor DarkCyan
        return
    }
    $script:dashboardHeight = 17

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
    $spark      = Get-Sparkline $sparkWidth $stats   # always returns object[]
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

function Start-SinglePing ([string]$targetIP) {
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
    }).AddArgument($targetIP).AddArgument($w).AddArgument($pingBuffer).AddArgument($pingOptions)

    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{
        PowerShell = $ps
        Runspace   = $rs
        Handle     = $handle
        Deadline   = $w + 1500
    }
}

function Complete-SinglePing ($pendingPing) {
    $done = $pendingPing.Handle.AsyncWaitHandle.WaitOne($pendingPing.Deadline)

    $pingResult = [PSCustomObject]@{ Success = $false; Latency = $null }
    if ($done) {
        try {
            $out = $pendingPing.PowerShell.EndInvoke($pendingPing.Handle)
            if ($out.Count -gt 0) { $pingResult = $out[0] }
        } catch { }
    } else {
        try { $pendingPing.PowerShell.Stop() } catch { }   # abandon the stuck thread
    }
    try { $pendingPing.PowerShell.Dispose() } catch { }
    try { $pendingPing.Runspace.Dispose() } catch { }
    return $pingResult
}

# ─────────────────────────────────────────────────────────────────────────────
#  Summary (printed on exit)
# ─────────────────────────────────────────────────────────────────────────────
function Write-Summary {
    foreach ($targetState in $targetStates) {
        $stats = $targetState.Stats
        $totalTime = [datetime]::Now - $stats.StartTime
        $pct      = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Lost / $stats.Sent) } else { '0.0' }
        $uptime   = if ($stats.Sent -gt 0) { '{0:F1}' -f (100.0 * $stats.Received / $stats.Sent) } else { '100.0' }
        $avgLat   = if ($stats.Received -gt 0) { '{0:F1}' -f ($stats.TotalLatency / $stats.Received) } else { '—' }
        $minLat   = if ($stats.MinLatency -eq [int]::MaxValue) { '—' } else { "$($stats.MinLatency) ms" }
        $maxLat   = if ($stats.MaxLatency -eq 0 -and $stats.Received -eq 0) { '—' } else { "$($stats.MaxLatency) ms" }

        Write-Host ""
        Write-Host "  sping Summary: $($targetState.Display)" -ForegroundColor Cyan
        Write-Host "  Runtime  : $(Format-Duration $totalTime)" -ForegroundColor White
        Write-Host "  Sent     : $($stats.Sent)    Received: $($stats.Received)    Lost: $($stats.Lost) ($pct%)" -ForegroundColor White
        Write-Host "  Uptime   : $uptime%" -ForegroundColor White
        Write-Host "  Latency  : ~ $avgLat  |  Min: $minLat  |  Max: $maxLat" -ForegroundColor White
    }
    if ($logFile) { Write-Host "  Log      : $logFile" -ForegroundColor DarkGray }
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

        # Start every target before waiting so slow targets do not serialize the cycle.
        $pendingPings = [System.Collections.Generic.List[object]]::new()
        foreach ($targetState in $targetStates) {
            $pendingPings.Add([PSCustomObject]@{
                Target = $targetState
                Ping   = Start-SinglePing $targetState.ResolvedIP
            })
        }

        foreach ($pendingPing in $pendingPings) {
            $targetState = $pendingPing.Target
            $stats = $targetState.Stats
            $result = Complete-SinglePing $pendingPing.Ping
            $timestamp = [datetime]::Now
            $stats.Sent++

            if ($result.Success) {
                $stats.Received++
                $stats.ConsecutiveFails = 0
                $stats.CurrentStatus = 'online'
                $stats.LastLatency = $result.Latency
                $stats.TotalLatency += $result.Latency
                if ($result.Latency -lt $stats.MinLatency) { $stats.MinLatency = $result.Latency }
                if ($result.Latency -gt $stats.MaxLatency) { $stats.MaxLatency = $result.Latency }
                $null = $stats.LatencyHistory.Add($result.Latency)
                Write-Log ("[{0}] {1} OK {2} ms" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff'), $targetState.Display, $result.Latency)
            } else {
                $stats.Lost++
                $stats.ConsecutiveFails++
                $stats.CurrentStatus = 'offline'
                $stats.LastLatency = $null
                $null = $stats.LatencyHistory.Add($null)
                Write-Log ("[{0}] {1} FAIL timeout" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff'), $targetState.Display)
            }

            while ($stats.LatencyHistory.Count -gt $HISTORY_SIZE) { $stats.LatencyHistory.RemoveAt(0) }

            if ($stats.CurrentStatus -ne $stats.LastStatus -and $stats.LastStatus -ne 'unknown') {
                $stats.LastChange = $timestamp
                $changeMsg = "[{0}] ### {1}: {2} -> {3} ###" -f $timestamp.ToString('yyyy-MM-dd HH:mm:ss'), $targetState.Display, $stats.LastStatus.ToUpper(), $stats.CurrentStatus.ToUpper()
                Write-Log $changeMsg
                Invoke-Sound $stats.CurrentStatus
            }
            $stats.LastStatus = $stats.CurrentStatus
        }

        # ── Redraw dashboard (every second) ───────────────────────────────────
        if (([datetime]::Now - $lastDraw).TotalMilliseconds -ge 900 -or $targetStates[0].Stats.Sent -eq 1) {
            Draw-Dashboard
            $lastDraw = [datetime]::Now
        }

        # ── Stop if -n reached ────────────────────────────────────────────────
        if ($n -gt 0 -and @($targetStates | Where-Object { $_.Stats.Sent -lt $n }).Count -eq 0) { break }

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
        $bottom.Y += $script:dashboardHeight
        try { $Host.UI.RawUI.CursorPosition = $bottom } catch { Write-Host "" }
    }

    Write-Summary

    Write-Log ""
    $totalSent = ($targetStates | ForEach-Object { $_.Stats.Sent } | Measure-Object -Sum).Sum
    $totalReceived = ($targetStates | ForEach-Object { $_.Stats.Received } | Measure-Object -Sum).Sum
    $totalLost = ($targetStates | ForEach-Object { $_.Stats.Lost } | Measure-Object -Sum).Sum
    $endMsg = "# Session ended: {0}  |  Sent: {1}  Received: {2}  Lost: {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $totalSent, $totalReceived, $totalLost
    Write-Log $endMsg

    if ($logWriter) { try { $logWriter.Close(); $logWriter.Dispose() } catch { } }
}
