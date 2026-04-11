<#
.SYNOPSIS
    Shared logging module for Nova scripts.

.DESCRIPTION
    Provides colour-coded, timestamped console and file logging functions used
    by Nova.ps1, Bootstrap.ps1, and Trigger.ps1.  Prefixes are configurable
    via Set-NovaLogPrefix so each script can retain its own visual identity
    while sharing a single implementation.

    Every log entry is prefixed with a timestamp ([yyyy-MM-dd HH:mm:ss]) and
    optionally written to a log file when file logging is enabled via
    Start-NovaLog.

    Default prefixes (Trigger style):
        Write-Step    --  "  [>] ..."   Cyan
        Write-Success --  "  [+] ..."   Green
        Write-Warn    --  "  [!] ..."   Yellow
        Write-Fail    --  "  [X] ..."   Red

    Additional log levels:
        Write-Info    --  "  [i] ..."   White     (informational detail)
        Write-Detail  --  "  [.] ..."   DarkGray  (verbose/debug data)
        Write-Section --  "=== ... ===" Magenta   (phase/section headers)
        Write-Data    --  key=value     Gray      (structured data logging)
#>

Set-StrictMode -Version Latest

# ── Module-scoped prefix variables ──────────────────────────────────────────
$script:StepPrefix    = '  [>]'
$script:SuccessPrefix = '  [+]'
$script:WarnPrefix    = '  [!]'
$script:FailPrefix    = '  [X]'
$script:InfoPrefix    = '  [i]'
$script:DetailPrefix  = '  [.]'

# ── File logging state ─────────────────────────────────────────────────────
$script:LogFilePath   = ''
$script:LogFileActive = $false

# ── Private helpers ────────────────────────────────────────────────────────

function Get-NovaTimestamp {
    <# Returns a formatted timestamp string for log entries. #>
    return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

function Write-NovaLogFile {
    <#
    .SYNOPSIS  Appends a plain-text (no colour codes) line to the active log file.
    .DESCRIPTION
        Only writes when file logging has been enabled via Start-NovaLog.
        Errors are silently suppressed so logging never breaks the caller.
    #>
    param([string]$Line)
    if (-not $script:LogFileActive -or -not $script:LogFilePath) { return }
    try {
        $Line | Out-File -FilePath $script:LogFilePath -Append -Encoding utf8 -Force
    } catch {
        Write-Debug "Nova.Logging: failed to write log line: $_"
    }
}

# ── Public Functions ───────────────────────────────────────────────────────

function Start-NovaLog {
    <#
    .SYNOPSIS  Enables file logging to the specified path.
    .DESCRIPTION
        Once called, all Write-Step / Write-Success / Write-Warn / Write-Fail /
        Write-Info / Write-Detail / Write-Section / Write-Data calls will also
        append timestamped plain-text entries to the log file.  The file is
        created if it does not exist.  Call Stop-NovaLog to finalize.
    .PARAMETER Path
        Full path to the log file.  Parent directory is created if missing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Setting in-memory module state and creating a log file -- benign side-effect')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    $parentDir = Split-Path $Path -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        $null = New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue
    }
    $script:LogFilePath   = $Path
    $script:LogFileActive = $true
    $ts = Get-NovaTimestamp
    Write-NovaLogFile "[$ts] ── Nova log started ──"
    Write-NovaLogFile "[$ts] Log file: $Path"
    Write-NovaLogFile "[$ts] Host: $($env:COMPUTERNAME)"
    Write-NovaLogFile "[$ts] User: $($env:USERNAME)"
    Write-NovaLogFile "[$ts] PS Version: $($PSVersionTable.PSVersion)"
    Write-NovaLogFile "[$ts] OS: $([System.Environment]::OSVersion.VersionString)"
}

function Stop-NovaLog {
    <#
    .SYNOPSIS  Finalizes file logging and writes a closing entry.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Setting in-memory module state only -- no system side-effects')]
    [OutputType([void])]
    [CmdletBinding()]
    param()
    if ($script:LogFileActive) {
        $ts = Get-NovaTimestamp
        Write-NovaLogFile "[$ts] ── Nova log ended ──"
    }
    $script:LogFileActive = $false
}

function Get-NovaLogPath {
    <#
    .SYNOPSIS  Returns the path of the active log file, or empty string if logging is not active.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param()
    if ($script:LogFileActive) { return $script:LogFilePath }
    return ''
}

function Set-NovaLogPrefix {
    <#
    .SYNOPSIS  Configures the message prefix used by Write-Step / Success / Warn / Fail / Info / Detail.
    .PARAMETER Step     Prefix for Write-Step (informational progress).
    .PARAMETER Success  Prefix for Write-Success (completion).
    .PARAMETER Warn     Prefix for Write-Warn (non-fatal warning).
    .PARAMETER Fail     Prefix for Write-Fail (error).
    .PARAMETER Info     Prefix for Write-Info (informational detail).
    .PARAMETER Detail   Prefix for Write-Detail (verbose/debug data).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Setting in-memory module state only -- no system side-effects')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [string]$Step,
        [string]$Success,
        [string]$Warn,
        [string]$Fail,
        [string]$Info,
        [string]$Detail
    )
    if ($PSBoundParameters.ContainsKey('Step'))    { $script:StepPrefix    = $Step    }
    if ($PSBoundParameters.ContainsKey('Success')) { $script:SuccessPrefix = $Success }
    if ($PSBoundParameters.ContainsKey('Warn'))    { $script:WarnPrefix    = $Warn    }
    if ($PSBoundParameters.ContainsKey('Fail'))    { $script:FailPrefix    = $Fail    }
    if ($PSBoundParameters.ContainsKey('Info'))    { $script:InfoPrefix    = $Info    }
    if ($PSBoundParameters.ContainsKey('Detail'))  { $script:DetailPrefix  = $Detail  }
}

function Write-Step {
    <#
    .SYNOPSIS  Writes a timestamped cyan progress message to the console and log file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "`n[$ts] $($script:StepPrefix) $Message" -ForegroundColor Cyan
    Write-NovaLogFile "[$ts] STEP    $($script:StepPrefix) $Message"
}

function Write-Success {
    <#
    .SYNOPSIS  Writes a timestamped green success message to the console and log file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "[$ts] $($script:SuccessPrefix) $Message" -ForegroundColor Green
    Write-NovaLogFile "[$ts] OK      $($script:SuccessPrefix) $Message"
}

function Write-Warn {
    <#
    .SYNOPSIS  Writes a timestamped yellow warning message to the console and log file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "[$ts] $($script:WarnPrefix) $Message" -ForegroundColor Yellow
    Write-NovaLogFile "[$ts] WARN    $($script:WarnPrefix) $Message"
}

function Write-Fail {
    <#
    .SYNOPSIS  Writes a timestamped red error message to the console and log file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "[$ts] $($script:FailPrefix) $Message" -ForegroundColor Red
    Write-NovaLogFile "[$ts] FAIL    $($script:FailPrefix) $Message"
}

function Write-Info {
    <#
    .SYNOPSIS  Writes a timestamped informational message to the console and log file.
    .DESCRIPTION
        Use for detailed informational output that supplements Write-Step.
        Renders in white for readability without drawing attention like
        success/warning/error messages.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "[$ts] $($script:InfoPrefix) $Message" -ForegroundColor White
    Write-NovaLogFile "[$ts] INFO    $($script:InfoPrefix) $Message"
}

function Write-Detail {
    <#
    .SYNOPSIS  Writes a timestamped verbose/debug message to the console and log file.
    .DESCRIPTION
        Use for low-level diagnostic data that is useful for troubleshooting
        but not needed during normal operation.  Renders in DarkGray to be
        visually subdued.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Message)
    $ts = Get-NovaTimestamp
    Write-Host "[$ts] $($script:DetailPrefix) $Message" -ForegroundColor DarkGray
    Write-NovaLogFile "[$ts] DETAIL  $($script:DetailPrefix) $Message"
}

function Write-Section {
    <#
    .SYNOPSIS  Writes a prominent section header to the console and log file.
    .DESCRIPTION
        Use to visually separate major phases of a deployment (e.g., disk
        partitioning, image download, driver injection).  Renders with a
        separator line above and below for visibility.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param([string]$Title)
    $ts = Get-NovaTimestamp
    $separator = '=' * 60
    Write-Host ''
    Write-Host "[$ts] $separator" -ForegroundColor Magenta
    Write-Host "[$ts]   $Title" -ForegroundColor Magenta
    Write-Host "[$ts] $separator" -ForegroundColor Magenta
    Write-NovaLogFile ''
    Write-NovaLogFile "[$ts] $separator"
    Write-NovaLogFile "[$ts]   $Title"
    Write-NovaLogFile "[$ts] $separator"
}

function Write-Data {
    <#
    .SYNOPSIS  Writes structured key-value data to the console and log file.
    .DESCRIPTION
        Use to log structured information such as configuration values,
        system properties, or step parameters.  Accepts a hashtable of
        key-value pairs and formats them as aligned lines.
    .PARAMETER Label
        A short label describing the data group (e.g., "Disk Info", "Network").
    .PARAMETER Data
        A hashtable (or ordered dictionary) of key-value pairs to log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Intentional coloured console output for operator visibility')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [hashtable]$Data
    )
    $ts = Get-NovaTimestamp
    Write-Host "[$ts]   --- $Label ---" -ForegroundColor Gray
    Write-NovaLogFile "[$ts]   --- $Label ---"
    foreach ($key in $Data.Keys) {
        $val = $Data[$key]
        Write-Host "[$ts]     $key = $val" -ForegroundColor Gray
        Write-NovaLogFile "[$ts]     $key = $val"
    }
}

function Show-NovaLogViewer {
    <#
    .SYNOPSIS  Opens a simple WinForms-based log viewer for WinPE.
    .DESCRIPTION
        Displays the contents of a Nova log file in a scrollable, resizable
        window with auto-refresh (tail) capability.  Designed for use in
        WinPE where GUI text editors are unavailable.

        The viewer colour-codes lines by log level:
          STEP/[>]  = Cyan     OK/[+]   = Green
          WARN/[!]  = Yellow   FAIL/[X] = Red
          INFO/[i]  = Black    DETAIL   = Gray

        Press F5 or click Refresh to reload the file.  The viewer auto-refreshes
        every 3 seconds when the Auto-Refresh checkbox is enabled.
    .PARAMETER Path
        Path to the log file to display.  Defaults to the active log file
        from Start-NovaLog if not specified.
    .PARAMETER NonBlocking
        When set, the viewer is shown non-modally so the calling script
        continues execution.  Default is modal (blocks until closed).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Fallback message when WinForms is unavailable')]
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [switch]$NonBlocking
    )

    if (-not $Path) {
        $Path = Get-NovaLogPath
    }
    if (-not $Path -or -not (Test-Path $Path)) {
        Write-Warn "Log file not found: $Path"
        return
    }

    # Attempt to load WinForms -- available in WinPE with the .NET component
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Warn "WinForms not available -- cannot show log viewer. View the log file directly: $Path"
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nova Log Viewer - $Path"
    $form.Size = New-Object System.Drawing.Size(900, 600)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    # Text box for log content
    $textBox = New-Object System.Windows.Forms.RichTextBox
    $textBox.Dock = 'Fill'
    $textBox.ReadOnly = $true
    $textBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $textBox.ForeColor = [System.Drawing.Color]::White
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $textBox.WordWrap = $false
    $textBox.ScrollBars = 'Both'

    # Toolbar panel
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Top'
    $toolbar.Height = 35
    $toolbar.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Refresh (F5)'
    $btnRefresh.Location = New-Object System.Drawing.Point(5, 5)
    $btnRefresh.Size = New-Object System.Drawing.Size(100, 25)
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    $chkAutoRefresh = New-Object System.Windows.Forms.CheckBox
    $chkAutoRefresh.Text = 'Auto-Refresh (3s)'
    $chkAutoRefresh.Location = New-Object System.Drawing.Point(115, 8)
    $chkAutoRefresh.ForeColor = [System.Drawing.Color]::White
    $chkAutoRefresh.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $chkAutoRefresh.AutoSize = $true

    $btnScrollEnd = New-Object System.Windows.Forms.Button
    $btnScrollEnd.Text = 'Scroll to End'
    $btnScrollEnd.Location = New-Object System.Drawing.Point(270, 5)
    $btnScrollEnd.Size = New-Object System.Drawing.Size(100, 25)
    $btnScrollEnd.FlatStyle = 'Flat'
    $btnScrollEnd.ForeColor = [System.Drawing.Color]::White
    $btnScrollEnd.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(380, 8)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGray

    $toolbar.Controls.Add($btnRefresh)
    $toolbar.Controls.Add($chkAutoRefresh)
    $toolbar.Controls.Add($btnScrollEnd)
    $toolbar.Controls.Add($lblStatus)

    # Load and colour-code content
    $loadContent = {
        param($tb, $filePath, $statusLabel)
        if (-not (Test-Path $filePath)) { return }
        $lines = Get-Content $filePath -ErrorAction SilentlyContinue
        if (-not $lines) { return }
        $tb.Clear()
        $tb.SuspendLayout()
        foreach ($line in $lines) {
            $colour = [System.Drawing.Color]::White
            if ($line -match 'STEP|(\[\>\])') {
                $colour = [System.Drawing.Color]::Cyan
            } elseif ($line -match 'OK\s|(\[\+\])') {
                $colour = [System.Drawing.Color]::LightGreen
            } elseif ($line -match 'WARN|(\[\!\])') {
                $colour = [System.Drawing.Color]::Yellow
            } elseif ($line -match 'FAIL|(\[\X\])') {
                $colour = [System.Drawing.Color]::FromArgb(255, 100, 100)
            } elseif ($line -match 'INFO|(\[i\])') {
                $colour = [System.Drawing.Color]::White
            } elseif ($line -match 'DETAIL|(\[\.\])') {
                $colour = [System.Drawing.Color]::Gray
            } elseif ($line -match '====') {
                $colour = [System.Drawing.Color]::FromArgb(200, 150, 255)
            }
            $tb.SelectionStart = $tb.TextLength
            $tb.SelectionColor = $colour
            $tb.AppendText("$line`n")
        }
        $tb.ResumeLayout()
        # Scroll to end
        $tb.SelectionStart = $tb.TextLength
        $tb.ScrollToCaret()
        $lineCount = $lines.Count
        if ($statusLabel) { $statusLabel.Text = "$lineCount lines | $(Get-Date -Format 'HH:mm:ss')" }
    }

    & $loadContent $textBox $Path $lblStatus

    # Refresh button click
    $btnRefresh.Add_Click({ & $loadContent $textBox $Path $lblStatus })

    # Scroll-to-end button
    $btnScrollEnd.Add_Click({
        $textBox.SelectionStart = $textBox.TextLength
        $textBox.ScrollToCaret()
    })

    # F5 key handler
    $form.KeyPreview = $true
    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'F5') {
            & $loadContent $textBox $Path $lblStatus
            $_.Handled = $true
        }
    })

    # Auto-refresh timer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({
        if ($chkAutoRefresh.Checked) {
            & $loadContent $textBox $Path $lblStatus
        }
    })
    $timer.Start()

    $form.Controls.Add($textBox)
    $form.Controls.Add($toolbar)

    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

    if ($NonBlocking) {
        $form.Show()
    } else {
        [void]$form.ShowDialog()
    }
}

Export-ModuleMember -Function @(
    'Set-NovaLogPrefix'
    'Write-Step'
    'Write-Success'
    'Write-Warn'
    'Write-Fail'
    'Write-Info'
    'Write-Detail'
    'Write-Section'
    'Write-Data'
    'Start-NovaLog'
    'Stop-NovaLog'
    'Get-NovaLogPath'
    'Show-NovaLogViewer'
)

# SIG # Begin signature block
# MII9dQYJKoZIhvcNAQcCoII9ZjCCPWICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDhkFW2NjA5gp6V
# vRTB9ycelLgbYDReAkDwMLcKxGTvs6CCIjgwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAAALJYmh
# eTfl9V9mAAAAAAslMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNDEwMTQzMzI1WhcNMjYwNDEz
# MTQzMzI1WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCoRt7KuvVHrwTk
# RDxoLt3Hu8hKXs8FpKttF7I7rMUvoYB6Y8iYaGvLFDQ1XudogJ2G/5xLA4IUT3rF
# ZDdCX/bIAjAIa+7Iv12SrHm/mUWBb9JWn20ds6oPmi1lVVd2Dk3mLHJ3qWaRR7I0
# qAfT/xJ0JsSBNW6RnhKw1U+TFyrevOJHa870enc+hsCT+OOHIeq4EsOchVNFqRNw
# 7AAIj7Iq7mcOXxhYVVdLiyGGjAO7EMJDzZHJ+2DKwZKH1HdONN9NqRZ5xV9E5IU4
# 7r+iqpYwSseLtx+dzcFAFfomAWcZEmceAOTvFjTQBFe4VX+wkM8P70cfZRyE746F
# AuScjqIPo/Zny1YYmfJM/E4LPNLnROUr24nBQkhMQhBD8zWLzh5AmmzerkSnLEma
# 63OATiMxIY/aWc505QcYC/UmZK3uC2rLm7PWY5Vmaze9vuIwJjn1aNLe6lwSw8Qr
# pBOToDPpzuOySz5s0G0XowEDlsBlPov3nm5FgT3Z1zI933hy1PMCAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUyhxTM5EWAZIW8X59xk6mx808hZkwHwYDVR0jBBgwFoAUayVB3vtr
# fP0YgAotf492XapzPbgwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwQU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAMRVo79ZYMctxbTncnYSUA+xTwTu2ZXwBOtnPsIzY746k/oBWm+ShFPX
# OE8RnWYCVr2vMWGzdgIfC3aS08P/D9kjxPYJpahD0kPKvlHVGiSNk87I+j5ljG7j
# 0a8IEi9vaMNrR0aJKKhjSqqkUpVyGYH8AZJ/TUYoGgkGbtMvqjXLHu5MS/CBvqlb
# CeQ0f3xmqzpa74NkQ06dE48j5UWaqOHfd8+v8BBkxwkdZbujVtA8EZq6SGZEo8Uz
# IYJhfzxiiYqpTTmr5JjfA/A4WryMPdY1ErcLEIvtADLp2RYZ5aPDT3DXbuLcdMvt
# L1mAsFm1tTL6F9h9EPMmUcZX+dbKiNkBkL/ghV4cC7t91t/n8mFm4L/46yqmH0uj
# fAYZRAwn7Z26mWxYe/cHrskWS6nvh8atFM7kqiD63NUJiq3LjQAp+1rmJBvVi4JE
# u8LqC88D8mxN+6Ru8zcFIj7chzlKEpwD3NAKGo0I0F4o6IisMJne5dpzSm1KXpH2
# 3Ul1nSK/P92dMA+3AnFyA/BAv+jxf9YTkV1VlMFYEZ9ROsxI/y1hYGWqv6qcsOIP
# yw9cWOfiT/0Bqwdk+pIPFrW2k0pI3Zmi8zozD0FMfLpuT924KRwqSmSM3qk4VSep
# kXUtC2b/Ar71yJUTBX/63+kyCSMciAsQe/u4NPkwcljbJ6jmeB50MIIGyTCCBLGg
# AwIBAgITMwAACyWJoXk35fVfZgAAAAALJTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MB4XDTI2MDQxMDE0
# MzMyNVoXDTI2MDQxMzE0MzMyNVowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAqEbeyrr1R68E5EQ8aC7dx7vISl7PBaSrbReyO6zFL6GAemPImGhryxQ0NV7n
# aICdhv+cSwOCFE96xWQ3Ql/2yAIwCGvuyL9dkqx5v5lFgW/SVp9tHbOqD5otZVVX
# dg5N5ixyd6lmkUeyNKgH0/8SdCbEgTVukZ4SsNVPkxcq3rziR2vO9Hp3PobAk/jj
# hyHquBLDnIVTRakTcOwACI+yKu5nDl8YWFVXS4shhowDuxDCQ82RyftgysGSh9R3
# TjTfTakWecVfROSFOO6/oqqWMErHi7cfnc3BQBX6JgFnGRJnHgDk7xY00ARXuFV/
# sJDPD+9HH2UchO+OhQLknI6iD6P2Z8tWGJnyTPxOCzzS50TlK9uJwUJITEIQQ/M1
# i84eQJps3q5EpyxJmutzgE4jMSGP2lnOdOUHGAv1JmSt7gtqy5uz1mOVZms3vb7i
# MCY59WjS3upcEsPEK6QTk6Az6c7jsks+bNBtF6MBA5bAZT6L955uRYE92dcyPd94
# ctTzAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFMocUzORFgGSFvF+fcZOpsfNPIWZMB8GA1Ud
# IwQYMBaAFGslQd77a3z9GIAKLX+Pdl2qcz24MGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEFPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBD
# QSUyMDA0LmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQDEVaO/WWDHLcW053J2ElAPsU8E7tmV8ATrZz7C
# M2O+OpP6AVpvkoRT1zhPEZ1mAla9rzFhs3YCHwt2ktPD/w/ZI8T2CaWoQ9JDyr5R
# 1RokjZPOyPo+ZYxu49GvCBIvb2jDa0dGiSioY0qqpFKVchmB/AGSf01GKBoJBm7T
# L6o1yx7uTEvwgb6pWwnkNH98Zqs6Wu+DZENOnROPI+VFmqjh33fPr/AQZMcJHWW7
# o1bQPBGaukhmRKPFMyGCYX88YomKqU05q+SY3wPwOFq8jD3WNRK3CxCL7QAy6dkW
# GeWjw09w127i3HTL7S9ZgLBZtbUy+hfYfRDzJlHGV/nWyojZAZC/4IVeHAu7fdbf
# 5/JhZuC/+Osqph9Lo3wGGUQMJ+2duplsWHv3B67JFkup74fGrRTO5Kog+tzVCYqt
# y40AKfta5iQb1YuCRLvC6gvPA/JsTfukbvM3BSI+3Ic5ShKcA9zQChqNCNBeKOiI
# rDCZ3uXac0ptSl6R9t1JdZ0ivz/dnTAPtwJxcgPwQL/o8X/WE5FdVZTBWBGfUTrM
# SP8tYWBlqr+qnLDiD8sPXFjn4k/9AasHZPqSDxa1tpNKSN2ZovM6Mw9BTHy6bk/d
# uCkcKkpkjN6pOFUnqZF1LQtm/wK+9ciVEwV/+t/pMgkjHIgLEHv7uDT5MHJY2yeo
# 5ngedDCCBygwggUQoAMCAQICEzMAAAAWMZKNkgJle5oAAAAAABYwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjlaFw0zMTAzMjYxODExMjlaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDKVfrI2+gJMM/0bQ5OVKNdvOASzLbUUMvX
# uf+Vl7YGuofPaZHVo3gMHF5inT+GMSpIcfIZ9qtXU1UG68ry8vNbQtOL4Nm30ifX
# pqI1+ByiAWLO1YT0WnzG7XPOuoTeeWsNZv5FmjxCsReBZvyzyzCyXZbu1EQfJxWT
# H4ebUwtAiW9rqMf9eDj/wYhiEfNteJV3ZFeibD2ztCHr9JhFdd97XbnCHgQoTIqc
# 02X5xlRKtUGBa++OtHBBjiJ/uwBnzTkqu4FjpZjQeJtrmda+ur1CT2jflWIB/ypn
# 7u7V9tvW9wJbJYt/H2EtJ0GONWxJZ7TEu8jWPindOO3lzPP7UtzS/mVDV94HucWa
# ltmsra6zSG8BoEJ87IM8QSb7vfm/O41FhYkUv89WIj5ES2O4kxyiMSfe95CMivCu
# YrRP2hKvx7egPMrWgDDBkxMLgrKZO9hRNUMm8vk3w5b9SogHOyJVhxyFm8aFXfIx
# gqDF4S0g4bhbhnzljmSlCLlumMZcXFGDjpF2tNoAu3VGFGYtHtTSNVKvZpgB3b4y
# naoDkbPf+Wg4523jt4VneasBgZhC1srZI2NCnCBBfgjLq04pqEKAWEohyW2K29KS
# kkHvt5VaE1ac3Yt+oyiOzMS57tXwQDJLGvLg/OXFO0VNvczDndfIfXYExB/ab2Pu
# MSwd5VIBOwIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQAG1VBeVHTVRBljlcZD3IiM
# xwPyMjQyLNaEnVu5mODm2hRBJfH8GsBLATmrHAc8F47jmk5CnpUPiIguCbw6Z/KV
# j4Dsoiq228NSLMLewFfGMri7uwNGLISC5ccp8vUdADDEIsS2dE+QI9OwkDpv3XuU
# D7d+hAgcLVcMOl1AsfEZtsZenhGvSYUrm/FuLq0BqEGL9GXM5c+Ho9q8o+Vn/S+G
# WQN2y+gkRO15s0kI05nUpq/dOD4ri9rgVs6tipEd0YZqGgD+CZNiaZWrDTOQbNPn
# cd2F9qOsUa20miYruoT5PwJAaI+QQiTE2ZJeMJOkOpzhTUgqVMZwZidEUZKCquda
# eQA08WwnkQMfKyHzaU8j48ULcU4hUwvMsv7fSurOe9GAdRQCPvF8WcSK5oDHe8VV
# JM4tv6KKCm91HqLx9JamBgRI6R2SfY3nu26EGznu0rCg/769z8xWm4PVcC2ZaL6V
# lKVqFp1NsN8YqMyf5t+bbGVb09noFKcJG/UwyGlxRmQBlfeBUQx5/ytlzZzsEnhr
# JF9fTAfje8j3OdX5lEnePTFQLRlvzZFBqUXnIeQKv3fHQjC9m2fo/Z01DII/qp3d
# 8LhGVUW0BCG04fRwHJNH8iqqCG/qofMv+kym2AxBDnHzNgRjL60JOFiBgiurvLhY
# QNhB95KWojFA6shQnggkMTCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
# AAcwDQYJKoZIhvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZl
# cmlmaWNhdGlvbiBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIx
# MDQwMTIwMDUyMFoXDTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElE
# IFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3
# KU3rlfL3qrZilYKJNqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlf
# IaTE/xrweLoQ71lzCHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQ
# hNUwgrx9rGQ//h890Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae
# 2nPIPc8sZU6ZE7iRrRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkx
# h+YeHgfWo5tTgkoSMoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAW
# rbyfNrC69oKpRQXY9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky
# 6Uh/cgjkVd6CGUAf0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4
# crCzTTHgYYjHs1NbOc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR
# 461uckFu0t+gCwLdN0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQc
# VTgRnzeLzdpt32cdYKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3
# AgMBAAGjggI1MIICMTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAw
# HQYDVR0OBBYEFNlBKbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0g
# ADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYB
# BQUHAQEEgbYwgbMwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDAN
# BgkqhkiG9w0BAQwFAAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIb
# zi+OwVdPQ4H55v7VOInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/
# Xv2pfpVIE1CRFfNF4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9
# E5StNp5T8FG7/VEURIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1R
# ft6XG7b4e0ejRA7mB2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNe
# p7SquKaBjhWmirYyANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS
# /NWShg/tuLjAsKP6SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0
# DErVLjQwK8VtsBdekBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2
# UfMwxCCX3mccFgx6UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZn
# rUAx4XQLUz6ZTl65yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB
# 1dVLlz4i3IpaDcR+iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFI
# rmcxghqTMIIajwIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBBT0MgQ0EgMDQCEzMAAAsliaF5N+X1X2YAAAAACyUwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQg34k2quRj1nNhj0/J9rc7XsNKB3PZnkXC/NeT6+yeg2gw
# DQYJKoZIhvcNAQEBBQAEggGAfntgOBiw3lnZSWXpLr4iIvrYFrhh+u1MKBoGerRD
# nWRcPCtHrThthsGaXjxLBpQvM/pcPFH1sRXrAYBfYCWuW9sTCRRw8ZgHTADrHkqH
# MV7GTTpYcNBZfDnJTETmAam8SegycP7Mvg5oFU3Un0yNbJCxoJO8nY96RXjvXwke
# sMyCrqcMGvoXTXYxOsH2h6NCpvxb84LDqetyShGRU8qxlJnwlZLf8FpsbAHuBelE
# eyN/B5DSYGywymYbfpSX286zJP1WRiKHBP3i9OM5uLNhXoVhoPIsd364bP2ncyKn
# BxtoMaQH51F1hQgwwVIZv/OX/RdWK+fr1Cioy4vqhdKDEMwftRJfpmIPBoRxj0vX
# YebSKVJ7HSZK+sVVjdvyNcSkyTTNECLMqEfFRFr2cO9wuEQ+kcpF+k2aM3zzE4Vh
# Avs7WcVGcTs/BcyQPvXRUBHjJ1AFwD5VfYx16M5fK5JWXM/9+HkSQStRB3NsUuky
# BoOxFfoM3AXS0RvziyqpCMbCoYIYEzCCGA8GCisGAQQBgjcDAwExghf/MIIX+wYJ
# KoZIhvcNAQcCoIIX7DCCF+gCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3
# DQEJEAEEoIIBUASCAUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEICtbORys6IVhdaaVWkn7cDrKcbRrb+2ouzSRShZit7MlAgZp1AaEOmgYEjIw
# MjYwNDExMDk1ODQ2LjU3WjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaCCDyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAF
# MA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJp
# ZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDEx
# MTkyMDMyMzFaFw0zNTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/
# sqtDlwxKoVIcaqDb+omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8
# y4gSq8Zg49REAf5huXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFP
# u6rfDHeZeG1Wa1wISvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR
# 4fkquUWfGmMopNq/B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi
# +dR8A2MiAz0kN0nh7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+Mk
# euaVDQQheangOEMGJ4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xG
# l57Ei95HUw9NV/uC3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eE
# purRduOQ2hTkmG1hSuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTe
# hawOoxfeOO/jR7wo3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxw
# jEugpIPMIIE67SFZ2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEA
# AaOCAhswggIXMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQUa2koOjUvSGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+
# 0mqFKhvKGZgEByfPUBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3JsMIGUBggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRl
# bnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRo
# b3JpdHklMjAyMDIwLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedM
# eGj6TuHYRJklFaW4sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LY
# haa0ozJLU5Yi+LCmcrdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nP
# ISHz0Xva71QjD4h+8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2c
# Io1k+aHOhrw9xw6JCWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3
# xL7D5FR2J7x9cLWMq7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag
# 1H91KlELGWi3SLv10o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK
# +KObAnDFHEsukxD+7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88
# o0w35JkNbJxTk4MhF/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bq
# jN49D9NZ81coE6aQWm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8A
# DHD1J2Cr/6tjuOOCztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6J
# QivRepyvWcl+JYbYbBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVyTTleCi6ckx
# AAAAAABXMA0GCSqGSIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1M1oXDTI2MTAy
# MjIwNDY1M1owgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9z
# b2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCxbKUKkwh9uLMktjWQ9c7ZyZfYdFa9FsCZ
# 4pJnl7Hv+MLKZ1XsRqn4hzaKpG1YOQop7mAvolXzTC2fkLaocks/FRgUo0bdSQeQ
# AjbUygI35haeFPwr9i4+Jvr7r3vSN1t4UoiJkxbB3mGelf0neN6164R1dun8N8UE
# rXkm4Pck7Na4Xay5AI+CpiNA+T+Cmr7coIq1clFtdIJIn1i0hNTYgfCZ90TuXY99
# nXnjDTjWmj58N5OPSAk7NxX8m/npDQz7DX2MAqj8jk8TOstXUg9CeY/iivVfhFsl
# eTw41fI459c7ErZUuk3GCSUrXIB7NsU/a7OqKFpeRbWH0ZAsYQ0oRKd7PCB1Fos0
# 1pi2bwBP+lkdgnfmZlWqRl0whySlAcmT8XV9IvIMp4q0fhMLhxzcRIpQyAi2rTtl
# mbvgkKx+GatDWKNU0OLVKWf5AFqaALta+JluRCdx5BGr0Nj7qEA3A6tqwBlSJWva
# Q+6PWMcM5fNQbg71BMrvQ/+hdKpkA3WhO/dR8XwlMaYDGD6XVk87PnQxj3ocEPD/
# dsj/AEY28uTp8tWevEY3kHm6cX+Vi+ONZshR3IE9VCc84pe7TxJEdtjX0zUehZfo
# 81m/6/NJ6pV5ZYcp0qMLcaNWNtsamL4ktuLJopFLASqjj20ku+7r1xDt1axuSxqL
# hNRGdWPaYwIDAQABo4IByzCCAccwHQYDVR0OBBYEFI6DyV4tNQ4CCUhn5uNemIPt
# EpKnMB8GA1UdIwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMw
# YaBfoF2GW2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jv
# c29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5j
# cmwweQYIKwYBBQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUy
# MFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNV
# HSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBR
# BgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkq
# hkiG9w0BAQwFAAOCAgEAcnXAdjzpmTlJQEM9jbl3+71glVpo1rvW7GNfhzI79cni
# 48Q0JI7CRFOc2iA8vFMPQWDfPhMV//ZP/QgVLF21ZW1OOHOuf5YsifN5FrBSFMIV
# Ws8EkoRZWyGb4iDv+cHslsk3zz6W0iYFsvmRPVK0Et8bpSSwBwNs1JDDD3QJReEa
# 54HGWdK+OQBfWiGI3XrLVsHazSu9DHwKx6mXYK4F59N8OswbNb+3M3HlhorYPw5b
# B6pNZlwaUk7hiNk0jzdxOtCCF8eX/wBc4ePxxYvfAQWW1BCzbF5FgBvcp2eXughY
# opdZoFgljk/dA+yIL4NMynt6N1gpOtvf3p/eCv7Av8yzn9ne8hZk8km/Xyo3DjR9
# Q295GfDMxCfHx0zZsa5ddBnnLs/xpdPgckyjfj2pm2fhdDCJQT8MOn74xQvSSCO9
# 38N6jtevfvU8U89hvhNuhmGNXXH37AIcOg6k0IG35W5dTvzK0l0rNDUm/ZwQ/UX0
# f3/BIuwwNS9YwTu72YYSU48Nk8xWvwC4ES4t1tNIR1ovCxkGmXPEsFyDGFn8KzfT
# IGG4TdCGpPVgNnalrnpF7E8DZJqw9xOhPqAmAnoTToGZnbNBM29Y6OzldCodti5d
# yh4NzB7ZRoLsQM4YPwaYsT0uKq1Cy5AIzu/sjbFH6w9lPYDH/zkeMiQz7czNMrUx
# ggdGMIIHQgIBATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCWCGSAFlAwQC
# AQUAoIIEnzARBgsqhkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjA0MTEwOTU4NDZaMC8GCSqGSIb3DQEJ
# BDEiBCDlLP00eTCt7D+4Dbgq6u9W6sdaDh6togsF2xQ7/X+1SjCBuQYLKoZIhvcN
# AQkQAi8xgakwgaYwgaMwgaAEIPU8n2S1BW5MZYhsos7h/VVQ6VRTb0BEISkNmYVM
# eNtSMHwwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMIIDYQYLKoZIhvcNAQkQ
# AhIxggNQMIIDTKGCA0gwggNEMIICLAIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBB
# bWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAw
# LTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBT
# dGFtcGluZyBBdXRob3JpdHmiIwoBATAHBgUrDgMCGgMVAP0vMTmcQlEBQTZKzfFo
# oo9cecvDoGcwZaRjMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMA0GCSqGSIb3DQEBCwUAAgUA7YRzvDAiGA8yMDI2MDQx
# MTA3MTYxMloYDzIwMjYwNDEyMDcxNjEyWjB3MD0GCisGAQQBhFkKBAExLzAtMAoC
# BQDthHO8AgEAMAoCAQACAhJpAgH/MAcCAQACAhJpMAoCBQDthcU8AgEAMDYGCisG
# AQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMB
# hqAwDQYJKoZIhvcNAQELBQADggEBAJSLtVnpmbdvtew7vvEtW1fW+ZRHkVq9/DCH
# jNdswWlOOfY9ZQ/Dgv2Sy/8081saEbEJbJohC7tM9rabERjFwSSv6t8r+XsjezzP
# wwHOaNCTHmisWiTZrvCFimvle9oYT4MKnrfDFLUkjps0IC+wzlqNvr05hQ0cCG+P
# vPBjJs6NMzYZlEsn+LV0TJx0qNqMHjSrrfWfc0lmTDzVI2MeorPomalUSEc4XRJv
# 2Cl+IiRd1R0F+kDsEea+H1Sqqo05Iv+19iqsMKrO4mAYAX5X5NYNtwHMgeMpZvqz
# mQjSAO0D1uQOwj7pVhIylcqy8LKxCf7zWmo9q4Yyi1tAGDhW/F8wDQYJKoZIhvcN
# AQEBBQAEggIATKg/ziq3SctVaXB0XK8JDlZYmEuWRC/JEi+soai3YO36kTbdOzl2
# akfAT7rhtp2WA/8G8PdKZytO1VZBJ8RrZrq7oX+VrBRqSL2Sy8D1X+P4S2/ttyjG
# RGQyFEr2RDfx+GY76e5HFZSGCkHpThBxoaCP43U/CLHfXHPaxe+EzG6oM48vky4X
# QoSgt7TinCDbb+/qc0jyjLX6k2JmUT8XSyQNsjPqLbWhkXtF+/2hNdES75FL5usZ
# QZ67eaKmmHX3gUH7zVl5HNfA2sAuUwOFiX1YKeiU0fwkNJ4INgwNG5K2SxGdxRUf
# 0m4ZfYwvVse1vIfwxWoyLkYC0Bv0nm/9hQYCyTnXJSmF8mNCIZF5mqmuvfl7TG+V
# ULdngjHFBuMZVS3AZqPqBZFAKxKWCO4SejlWkjz+UjYmZGXklKct3/psaDXzwnTE
# dLmkoWDi5m2mzM2oddDdz0zLWG3Cgg6d9vY9ylvwNOZXyDP8s12eoco8JCkL6zrv
# 0sR7NEuTd44MKHfPJV2Vv/0hjbvCD583xobWaC7w2VVefZ7cYuGaaodz4ezHe+lm
# 1cksGOtbRkwRfWKHlyoZP5C7JJJsKxF2TzsITsIwjVwfWrk8Ryi1u4bpp+v4yj+B
# p7M3zgbo5KlMFAjXezX33GGDrraMu/2B/glYD4OGMZFHuln0/i6DCjk=
# SIG # End signature block
