<#
.SYNOPSIS
    Always-on-top desktop overlay for the Detection Alert mod's turret eye.

.DESCRIPTION
    The in-game HUD draws through the engine's Gui calls, so detection_alert.lua also writes its live state to
    %APPDATA%\Arrowhead\Helldivers2\DetectionAlertStatus.log (Chef Shared Loader's folder for mod logs, one line per
    tick, throttled). This script polls that file's last line and renders a small
    borderless, always-on-top window showing the turret eye glow outside the game window.

    Below the state label it shows the mod's counts. "enemies"/"near you" are real counts of units
    whose resource hash is in the mod's enemy whitelist: how many the last sampler pass found alive,
    and how many of those were within 35 m of you. They read "-" until the first pass of a mission
    finishes. "alerted" is enemy units currently outside their calm animation states (the mod learns
    each enemy type's calm states during quiet stretches, so it reads 0 for the first minute or so);
    it cannot tell searching from detected-you. "active" is the number of enemies whose animation
    changed in the last sampler pass.

.USAGE
    powershell -ExecutionPolicy Bypass -File tools\overlay\DetectionAlertOverlay.ps1
    Drag with left mouse button to reposition. Right-click to exit.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StatusPath = Join-Path $env:APPDATA 'Arrowhead\Helldivers2\DetectionAlertStatus.log'

# Dark navy backdrop, matches the mod's own red-ember/alert eye theme.
$BackdropColor = [System.Drawing.Color]::FromArgb(230, 10, 14, 26)
$IdleTextColor = [System.Drawing.Color]::FromArgb(255, 180, 190, 210)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(40, 40)
$form.Size = New-Object System.Drawing.Size(220, 128)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $BackdropColor

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'DETECTION ALERT'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $IdleTextColor
$titleLabel.AutoSize = $false
$titleLabel.Size = New-Object System.Drawing.Size(220, 16)
$titleLabel.Location = New-Object System.Drawing.Point(0, 4)
$titleLabel.TextAlign = 'MiddleCenter'
$form.Controls.Add($titleLabel)

$stateLabel = New-Object System.Windows.Forms.Label
$stateLabel.Text = 'WAITING...'
# Font size 10 (down from 11) so the state labels fit on one line.
$stateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$stateLabel.ForeColor = $IdleTextColor
$stateLabel.AutoSize = $false
$stateLabel.Size = New-Object System.Drawing.Size(220, 28)
$stateLabel.Location = New-Object System.Drawing.Point(0, 56)
$stateLabel.TextAlign = 'MiddleCenter'
$form.Controls.Add($stateLabel)

# Two lines under the state label: "searching / detected you" and "active units".
$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = ''
$countLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$countLabel.ForeColor = $IdleTextColor
$countLabel.AutoSize = $false
$countLabel.Size = New-Object System.Drawing.Size(220, 36)
$countLabel.Location = New-Object System.Drawing.Point(0, 86)
$countLabel.TextAlign = 'MiddleCenter'
$form.Controls.Add($countLabel)

# The eye: a filled circle whose color is driven by the mod's eye_color (r,g,b in 0..1).
$eyePanel = New-Object System.Windows.Forms.Panel
$eyeSize = 48
$eyePanel.Size = New-Object System.Drawing.Size($eyeSize, $eyeSize)
$eyePanel.Location = New-Object System.Drawing.Point(($form.Width - $eyeSize) / 2, 24)
$eyePanel.BackColor = [System.Drawing.Color]::FromArgb(255, 89, 5, 5)
$eyeRegionPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$eyeRegionPath.AddEllipse(0, 0, $eyeSize, $eyeSize)
$eyePanel.Region = New-Object System.Drawing.Region($eyeRegionPath)
$form.Controls.Add($eyePanel)
$eyePanel.BringToFront()

# Borderless window: drag with left button, right-click to exit.
$dragging = $false
$dragStart = New-Object System.Drawing.Point(0, 0)
$dragHandler = {
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $dragging = $true
        $dragStart = $e.Location
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $form.Close()
    }
}
$dragMoveHandler = {
    param($sender, $e)
    if ($dragging) {
        $form.Location = New-Object System.Drawing.Point(
            ($form.Location.X + $e.X - $dragStart.X),
            ($form.Location.Y + $e.Y - $dragStart.Y))
    }
}
$dragEndHandler = { $dragging = $false }
foreach ($control in @($form, $titleLabel, $stateLabel, $countLabel, $eyePanel)) {
    $control.Add_MouseDown($dragHandler)
    $control.Add_MouseMove($dragMoveHandler)
    $control.Add_MouseUp($dragEndHandler)
}

# Tails the status file: reads only the last line, tolerant of the game writing concurrently.
function Get-LastStatusLine {
    if (-not (Test-Path $StatusPath)) {
        return $null
    }
    try {
        $stream = [System.IO.File]::Open($StatusPath, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object System.IO.StreamReader($stream)
        $last = $null
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line) { $last = $line }
        }
        $reader.Close()
        $stream.Close()
        return $last
    } catch {
        return $null
    }
}

function Parse-StatusLine([string]$line) {
    if (-not $line) { return $null }
    # searching, the count fields and nearby are all optional, so older log lines (written before
    # those fields existed) still parse; the nearby value is no longer shown. A count of -1 means
    # the mod has no number yet (no sampler pass has completed this mission).
    $pattern = 't=(?<t>[\d.\-]+) detected=(?<d>[01]) intensity=(?<i>[\d.\-]+) r=(?<r>[\d.\-]+) g=(?<g>[\d.\-]+) b=(?<b>[\d.\-]+)(?: nearby=[01])?(?: searching=(?<s>[01]))?(?: search_count=(?<sc>-?\d+))?(?: detect_count=(?<dc>-?\d+))?(?: active_units=(?<au>-?\d+))?(?: count_source=(?<cs>\w+))?(?: alerted_units=(?<al>-?\d+))?(?: team_alerted=(?<ta>-?\d+))?(?: team_mode=(?<tm>\w+))?'
    $match = [regex]::Match($line, $pattern)
    if (-not $match.Success) { return $null }
    return [PSCustomObject]@{
        T           = [double]$match.Groups['t'].Value
        Detected    = $match.Groups['d'].Value -eq '1'
        Intensity   = [double]$match.Groups['i'].Value
        R           = [double]$match.Groups['r'].Value
        G           = [double]$match.Groups['g'].Value
        B           = [double]$match.Groups['b'].Value
        Searching   = $match.Groups['s'].Success -and ($match.Groups['s'].Value -eq '1')
        SearchCount = $(if ($match.Groups['sc'].Success) { [int]$match.Groups['sc'].Value } else { -1 })
        DetectCount = $(if ($match.Groups['dc'].Success) { [int]$match.Groups['dc'].Value } else { -1 })
        ActiveUnits = $(if ($match.Groups['au'].Success) { [int]$match.Groups['au'].Value } else { $null })
        CountSource = $(if ($match.Groups['cs'].Success) { $match.Groups['cs'].Value } else { 'none' })
        AlertedUnits = $(if ($match.Groups['al'].Success) { [int]$match.Groups['al'].Value } else { $null })
        TeamAlerted = $(if ($match.Groups['ta'].Success) { [int]$match.Groups['ta'].Value } else { $null })
        TeamMode = $(if ($match.Groups['tm'].Success) { $match.Groups['tm'].Value } else { 'off' })
    }
}

# Two lines. The first is the real enemy counts from the hash whitelist (count_source=hashes), shown only
# once a sampler pass has produced them. The second is activity: "alerted" is enemies near you outside their
# calm states, "team" is the same around your squadmates and reads "?" unless the mod positively identified
# which player unit is you (team_mode=me). 'ready' is the pre-split name for 'me' and is accepted so older
# logs still read; 'aggro' is the pre-whitelist count source and is accepted for the same reason.
function Format-Counts($status) {
    $alerted = if ($null -ne $status.AlertedUnits) { "$($status.AlertedUnits)" } else { '-' }
    $team = if (($status.TeamMode -eq 'me' -or $status.TeamMode -eq 'ready') -and $null -ne $status.TeamAlerted) { "$($status.TeamAlerted)" } elseif ($status.TeamMode -eq 'off') { 'off' } else { '?' }
    $active = if ($null -ne $status.ActiveUnits) { "$($status.ActiveUnits)" } else { '-' }
    if (($status.CountSource -eq 'hashes' -or $status.CountSource -eq 'aggro') -and $status.SearchCount -ge 0 -and $status.DetectCount -ge 0) {
        return "enemies: $($status.SearchCount)   near you: $($status.DetectCount)`nalerted: $alerted   team: $team   active: $active"
    }
    return "alerted: $alerted   team: $team`nactive: $active"
}

$lastSeenAt = Get-Date
# The mod writes a line every 0.5 s while it runs and logging is on. When its t= stops moving -- logging
# turned off in the game's options menu, or the game closed -- the last line is old news, so show WAITING
# rather than a state that may no longer hold. Judged by t=, not the file's time: Windows can hold back
# the modified time of a file the game keeps open.
$StaleSeconds = 3
$script:lastT = $null
$script:lastTChangedAt = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $status = Parse-StatusLine (Get-LastStatusLine)
    if ($null -ne $status) {
        if ($status.T -ne $script:lastT) {
            $script:lastT = $status.T
            $script:lastTChangedAt = Get-Date
        } elseif (((Get-Date) - $script:lastTChangedAt).TotalSeconds -gt $StaleSeconds) {
            $status = $null
        }
    }
    if ($null -eq $status) {
        $stateLabel.Text = 'WAITING...'
        $stateLabel.ForeColor = $IdleTextColor
        $countLabel.Text = ''
        return
    }
    $lastSeenAt = Get-Date
    $eyePanel.BackColor = [System.Drawing.Color]::FromArgb(
        255,
        [int]([math]::Round($status.R * 255)),
        [int]([math]::Round($status.G * 255)),
        [int]([math]::Round($status.B * 255)))
    $countLabel.Text = Format-Counts $status
    if ($status.Detected) {
        $stateLabel.Text = 'DETECTED'
        $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 70, 70)
    } elseif ($status.Searching) {
        $stateLabel.Text = 'SEARCHING'
        $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 180, 60)
    } else {
        $stateLabel.Text = 'HIDDEN'
        $stateLabel.ForeColor = $IdleTextColor
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
