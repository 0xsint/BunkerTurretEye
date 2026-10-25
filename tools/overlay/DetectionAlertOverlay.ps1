<#
.SYNOPSIS
    Always-on-top desktop overlay for the Detection Alert mod's turret eye.

.DESCRIPTION
    Neither Bingus Shared Loader nor HD2Runtime expose a safe in-game HUD/draw API, so
    detection_alert.lua instead writes its live state to
    %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\DetectionAlertStatus.log (one line per
    tick, throttled). This script polls that file's last line and renders a small
    borderless, always-on-top window showing the turret eye glow outside the game window.

.USAGE
    powershell -ExecutionPolicy Bypass -File tools\overlay\DetectionAlertOverlay.ps1
    Drag with left mouse button to reposition. Right-click to exit.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StatusPath = Join-Path $env:LOCALAPPDATA 'CowboyBingus\Helldivers2\Logs\DetectionAlertStatus.log'

# Dark navy backdrop, matches the mod's own red-ember/alert eye theme.
$BackdropColor = [System.Drawing.Color]::FromArgb(230, 10, 14, 26)
$IdleTextColor = [System.Drawing.Color]::FromArgb(255, 180, 190, 210)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(40, 40)
$form.Size = New-Object System.Drawing.Size(220, 96)
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
# Font size 10 (down from 11) so the longest label, "ENEMIES NEARBY", still fits on one line.
$stateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$stateLabel.ForeColor = $IdleTextColor
$stateLabel.AutoSize = $false
$stateLabel.Size = New-Object System.Drawing.Size(220, 28)
$stateLabel.Location = New-Object System.Drawing.Point(0, 56)
$stateLabel.TextAlign = 'MiddleCenter'
$form.Controls.Add($stateLabel)

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
foreach ($control in @($form, $titleLabel, $stateLabel, $eyePanel)) {
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
    # nearby/searching are optional so older log lines (written before those fields
    # existed) still parse.
    $pattern = 't=(?<t>[\d.\-]+) detected=(?<d>[01]) intensity=(?<i>[\d.\-]+) r=(?<r>[\d.\-]+) g=(?<g>[\d.\-]+) b=(?<b>[\d.\-]+)(?: nearby=(?<n>[01]) searching=(?<s>[01]))?'
    $match = [regex]::Match($line, $pattern)
    if (-not $match.Success) { return $null }
    return [PSCustomObject]@{
        Detected  = $match.Groups['d'].Value -eq '1'
        Intensity = [double]$match.Groups['i'].Value
        R         = [double]$match.Groups['r'].Value
        G         = [double]$match.Groups['g'].Value
        B         = [double]$match.Groups['b'].Value
        Nearby    = $match.Groups['n'].Success -and ($match.Groups['n'].Value -eq '1')
        Searching = $match.Groups['s'].Success -and ($match.Groups['s'].Value -eq '1')
    }
}

$lastSeenAt = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    $status = Parse-StatusLine (Get-LastStatusLine)
    if ($null -eq $status) {
        $stateLabel.Text = 'WAITING...'
        $stateLabel.ForeColor = $IdleTextColor
        return
    }
    $lastSeenAt = Get-Date
    $eyePanel.BackColor = [System.Drawing.Color]::FromArgb(
        255,
        [int]([math]::Round($status.R * 255)),
        [int]([math]::Round($status.G * 255)),
        [int]([math]::Round($status.B * 255)))
    if ($status.Detected) {
        $stateLabel.Text = 'DETECTED'
        $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 70, 70)
    } elseif ($status.Searching) {
        $stateLabel.Text = 'SEARCHING'
        $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 180, 60)
    } elseif ($status.Nearby) {
        $stateLabel.Text = 'ENEMIES NEARBY'
        $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 230, 210, 80)
    } else {
        $stateLabel.Text = 'HIDDEN'
        $stateLabel.ForeColor = $IdleTextColor
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
