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
# MII9cwYJKoZIhvcNAQcCoII9ZDCCPWACAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbJMIIEsaADAgECAhMzAABSQY7l
# 84XZvuWtAAAAAFJBMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNDE0MTQyMDU2WhcNMjYwNDE3
# MTQyMDU2WjCBizEPMA0GA1UEERMGNDMyIDY3MQswCQYDVQQGEwJTRTEQMA4GA1UE
# CBMHSGFsbGFuZDEQMA4GA1UEBxMHVmVkZGlnZTEXMBUGA1UECRMOSm9oYW5uZXMg
# dmFnIDMxFjAUBgNVBAoTDUFtcGxpb3NvZnQgQUIxFjAUBgNVBAMTDUFtcGxpb3Nv
# ZnQgQUIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDiaaDsBkHK33PY
# y2N3c9H0WYuaS6zfCnNxJyAXwLl5/5IT5aCUSfXRZlopdexI3LGzdGlKPNTVpHMZ
# QES4+lybTKWuS1TBovX1yNXcFZL69YENBSPI+KtqIsPVevodOeWfzezWUYFlD6B0
# fP4mhQT4XUtF7V1+ULJ5O4f1vlHugoXtpYs2t2Gv2hU4kRtA4MGh3fsJcyifb751
# 4Q96Vo4ADMWsr1DNNIkdO/+3F/Gn2Q+Iq3UknXFT8PD4yl25OaEsMQe1tk9sPupo
# Z8RIkXWdqbfTWvIJvw/EREIqAQ8jTCMTZpb352JoH9f9DeOAUDb8PTIgGUyekZxK
# ZazRrgF3Uj/Ffb29viRKTCBgVaw1/ouPVsJ3ZMZgVaQoQiEYHfu+jRP0Jk3ve+Y4
# O5FMzBVh1qPh48akw41SNpZiZNNhg3cQ/SUHbkFaoRQ2IRbLSZnryEXjZloC2RO5
# mj1Do2BN4ib1qsiIUWVoa70Fy/sdNW2HswU2RNB82Gxk73sfft8CAwEAAaOCAdQw
# ggHQMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDsGA1UdJQQ0MDIGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhorBgEEAYI3YZG6312ljZ9ig8DT92CCpauxWDAd
# BgNVHQ4EFgQUuIt05EZ/8gwAGTL+u0c6lJfmskQwHwYDVR0jBBgwFoAUa16lNMMF
# xWJKIVqOq3NgYtSsY4UwZwYDVR0fBGAwXjBcoFqgWIZWaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUy
# MENTJTIwRU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYBBQUHAQEEaDBmMGQGCCsGAQUF
# BzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jv
# c29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3J0MFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wDQYJKoZIhvcNAQEM
# BQADggIBAGhA2xIUuTvm6OOZjzD9zV83DdPaQDYV3on1pi4Dho+ne+Rd6huJVA+X
# h+uWEyglV1cZ4scWfl+2JerD6SyFQSpBR8NKcCFjsDh4qlQjegPPq1iYPubmCGsd
# xXV1k+8nF6RCRhQNsD0EN2yWosjFkKV4ksB1za9yKTpo4MY+RyD4PVUxBKkDr/FT
# e+MDK1oB6OwQwYD+DC1ApwBdAbfY4A5XY6NLpQLjo5bz6L5vXanejrwxKjzQXob5
# aXnjCz27AGCNddicZmJ+3pyocUUB3DnVo6xeG5iPnPb/3oT77AghHJ+EmNxJWjc8
# MKjZskbZiC47pt/HXGEilWZ7RH/8WBiydlY4sQIOIBmZy53G+Ed53l7kyO6iTx0n
# fR5r66/iyeXNmU7jfcn0eMHtNR5X1ZOYENsF/v1xyRwyjJcRyJgQdmzfUNJQhKqJ
# J5QIN1d5aprYLvjmsQRU9Maz9K1afjGu+Y4T/tJM9mO4KdNwC0VM81pwO6l4gGw3
# o7xRNcud74cZRYyt7X0W9z1Mf/ZDobF1IchSiKfpTZ2p2vHwxZ10GIYLjUAQPPIw
# Df+6EQFXYoASJJjcmwlg5GOHFmEM6YQ2bPle9X7ilNDRtPclWV4N59CS3ovAokYn
# W1CgY3T34Y2V96NMn/Qk1Ov+zL/4AnO2ds+9KjXiRn0se5mm6JevMIIGyTCCBLGg
# AwIBAgITMwAAUkGO5fOF2b7lrQAAAABSQTANBgkqhkiG9w0BAQwFADBaMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQD
# EyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMB4XDTI2MDQxNDE0
# MjA1NloXDTI2MDQxNzE0MjA1NlowgYsxDzANBgNVBBETBjQzMiA2NzELMAkGA1UE
# BhMCU0UxEDAOBgNVBAgTB0hhbGxhbmQxEDAOBgNVBAcTB1ZlZGRpZ2UxFzAVBgNV
# BAkTDkpvaGFubmVzIHZhZyAzMRYwFAYDVQQKEw1BbXBsaW9zb2Z0IEFCMRYwFAYD
# VQQDEw1BbXBsaW9zb2Z0IEFCMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEA4mmg7AZByt9z2Mtjd3PR9FmLmkus3wpzcScgF8C5ef+SE+WglEn10WZaKXXs
# SNyxs3RpSjzU1aRzGUBEuPpcm0ylrktUwaL19cjV3BWS+vWBDQUjyPiraiLD1Xr6
# HTnln83s1lGBZQ+gdHz+JoUE+F1LRe1dflCyeTuH9b5R7oKF7aWLNrdhr9oVOJEb
# QODBod37CXMon2++deEPelaOAAzFrK9QzTSJHTv/txfxp9kPiKt1JJ1xU/Dw+Mpd
# uTmhLDEHtbZPbD7qaGfESJF1nam301ryCb8PxERCKgEPI0wjE2aW9+diaB/X/Q3j
# gFA2/D0yIBlMnpGcSmWs0a4Bd1I/xX29vb4kSkwgYFWsNf6Lj1bCd2TGYFWkKEIh
# GB37vo0T9CZN73vmODuRTMwVYdaj4ePGpMONUjaWYmTTYYN3EP0lB25BWqEUNiEW
# y0mZ68hF42ZaAtkTuZo9Q6NgTeIm9arIiFFlaGu9Bcv7HTVth7MFNkTQfNhsZO97
# H37fAgMBAAGjggHUMIIB0DAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA7
# BgNVHSUENDAyBgorBgEEAYI3YQEABggrBgEFBQcDAwYaKwYBBAGCN2GRut9dpY2f
# YoPA0/dggqWrsVgwHQYDVR0OBBYEFLiLdORGf/IMABky/rtHOpSX5rJEMB8GA1Ud
# IwQYMBaAFGtepTTDBcViSiFajqtzYGLUrGOFMGcGA1UdHwRgMF4wXKBaoFiGVmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElE
# JTIwVmVyaWZpZWQlMjBDUyUyMEVPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEB
# BGgwZjBkBggrBgEFBQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBD
# QSUyMDAzLmNydDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MA0GCSqGSIb3DQEBDAUAA4ICAQBoQNsSFLk75ujjmY8w/c1fNw3T2kA2Fd6J9aYu
# A4aPp3vkXeobiVQPl4frlhMoJVdXGeLHFn5ftiXqw+kshUEqQUfDSnAhY7A4eKpU
# I3oDz6tYmD7m5ghrHcV1dZPvJxekQkYUDbA9BDdslqLIxZCleJLAdc2vcik6aODG
# Pkcg+D1VMQSpA6/xU3vjAytaAejsEMGA/gwtQKcAXQG32OAOV2OjS6UC46OW8+i+
# b12p3o68MSo80F6G+Wl54ws9uwBgjXXYnGZift6cqHFFAdw51aOsXhuYj5z2/96E
# ++wIIRyfhJjcSVo3PDCo2bJG2YguO6bfx1xhIpVme0R//FgYsnZWOLECDiAZmcud
# xvhHed5e5Mjuok8dJ30ea+uv4snlzZlO433J9HjB7TUeV9WTmBDbBf79cckcMoyX
# EciYEHZs31DSUISqiSeUCDdXeWqa2C745rEEVPTGs/StWn4xrvmOE/7STPZjuCnT
# cAtFTPNacDupeIBsN6O8UTXLne+HGUWMre19Fvc9TH/2Q6GxdSHIUoin6U2dqdrx
# 8MWddBiGC41AEDzyMA3/uhEBV2KAEiSY3JsJYORjhxZhDOmENmz5XvV+4pTQ0bT3
# JVleDefQkt6LwKJGJ1tQoGN09+GNlfejTJ/0JNTr/sy/+AJztnbPvSo14kZ9LHuZ
# puiXrzCCBygwggUQoAMCAQICEzMAAAAVBT5uGY6TKdkAAAAAABUwDQYJKoZIhvcN
# AQEMBQAwYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmlu
# ZyBQQ0EgMjAyMTAeFw0yNjAzMjYxODExMjhaFw0zMTAzMjYxODExMjhaMFoxCzAJ
# BgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNV
# BAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDg9Ms9AqovDnMePvMOe+KybhCd8+lokzYO
# RlS3kBVXseecbyGwBcsenlm5bLtMGPjiIFLzBQF+ghlVV/U29q5GcdeEEBCHTTGh
# L2koIrLc4UrliMRcbv9mOMtR/l7/xAmv0Fx4BJHn1dHt37fvrBqXmKjKfGf5DpyO
# /+hnV7TEreMtS19iO+bjZ/9Hnpg3PCk0e7YSbRTFkx97FZwRWpC4s3NepRfRXQh/
# WMAj7JmsYeVZohi4TF5yW2JMrJZqwHcyzJZYtD2Hlno5ZEJkdiZcEaxHOobmwO06
# Z1J9c23ps9PGIhGaq1sKLEAz9Doc5rLkYWGteDrscKhAp2kIc/oYlH9Ij6BkOqqg
# WINEkEtC8ZNG1Mak+h3o65aj0iQKmdxW7IZaHO5cuyoMi+KtYfXeIIg3sVIbS2EL
# 8kUtsDGdEqNqAq/isqTi1jXqLe6iKp1ni1SPdvPW9G03CTsYF68b/yuIQRwbdoBC
# XemMNJCS0dorCRY4b2WAAy4ng7SANcEgrBgZf535+QfLU5hGzrKjIpbMabauWb5F
# KWUKkMsPcXFkXRWO4noKPm4KWlFypqOpbJ/KONVReIlxHQRegAOBzIhRB7gr9IDQ
# 1sc2MgOgQ+xVGW4oq4HD0mfAiwiyLskZrkaQ7JoanYjBNcR9RS26YxAVbcBtLitF
# TzCIEg5ZdQIDAQABo4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcV
# AQQDAgEAMB0GA1UdDgQWBBRrXqU0wwXFYkohWo6rc2Bi1KxjhTBUBgNVHSAETTBL
# MEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1
# AGIAQwBBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zv
# adf1zSmepEhqMOYwcAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENv
# ZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0G
# CCsGAQUFBzAChmFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBdbiI8zwXLX8glJEh/8Q22
# UMCUhWBO46Z9FPhwOR3mdlqRVLkYOon/MczUwrjDhx3X99SPH5PSflkGoTvnO9ZW
# HM5YFVYpO7NYuB+mfVSGAGZwiGOASWk0i2B7vn9nElJJmoiXxugfH5YdBsrUgTt0
# AFNXkzmqTgk+S1Hxb1u/0HCqEHVZPk2A/6eJXYbtpRM5Fcz00jisUl9BRZgSebOD
# V85bBzOveqyC3f0PnHCxRJNhMb8xP/sB/VI7pf2rheSV7zqUSv8vn/fIMblXeaVI
# lpqoq8SP9BJMjE/CoVXJxnkZQRM1Fa7kN9yztvReOhxSgPgpZx/Xl/jkwyEFVJTB
# fBp3sTgfIc/pmqv2ehtakL2AEj78EmOPQohxJT3wyX+P78GA25tLpAvzj3RMMHd8
# z18ZuuVi+60MAzGpOASH1L8Nlr3fZRZnQO+pyye2DCvYmHaIfdUgYJqn7noxxGVv
# 89+RaETh1tgCDvwNpFCSG7vl5A4ako+2fx409r9TWjXC7Oif1IQ5ZJzB4Rf8GvBi
# HYjvMmHpledp1FGRLdSRFVpC3/OKpZY6avIqZp7+8pP/WQP903DdgrvAT6W4xPOB
# xXPa4tGksN3SuqJaiFYHSNyeBufn8iseujW4IbBSbHD4BPqbF3qZ+7nG9d/d/G2/
# Lx4kH9cCmBfmsZdSkHmukDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAA
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
# rmcxghqRMIIajQIBATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# UyBFT0MgQ0EgMDMCEzMAAFJBjuXzhdm+5a0AAAAAUkEwDQYJYIZIAWUDBAIBBQCg
# XjAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAv
# BgkqhkiG9w0BCQQxIgQg34k2quRj1nNhj0/J9rc7XsNKB3PZnkXC/NeT6+yeg2gw
# DQYJKoZIhvcNAQEBBQAEggGAjJmrQyV62W2KNpiiWKn3hOCPqaidpGuMRfQ8SBdQ
# GNlsWdtamwoyqlCY5EGR+Zq/z3SVUW9d13wAyoXDElmJlwTEIbeyY6JfbSpbo+5u
# onxZq43mS9iGvE6rNd5b9UeVGmpbM5ZHF/Kt6crh6K/VaYSWK/Q/wu9db/u1yPBc
# QIPDq9wT8TdLMmAHc+vPE4dsESuLXLXNZOYSPhQbjqyEVLVGzCU5rMec97hVNeMM
# ADjUMBEuSgep7AFn1BvKQs426nZ8QHhC7zkz94aae85b77g2b3TPeGOVUUFSoKFf
# 9cXGvMR4DVQAf8S52jY3o8FWptpiAEJHzYy92xQZD7l6x9iL+RSN3RjMywc0++Wc
# oFK650ysurVLSUOTP0VkTqNhL5pd/6TWDfcQYZgNtVHWaHWniTJz0R9p3EyFIoqQ
# eYoMyX6gunItaG5jaxx6jhFFGSxMj/yNym8u/Y2EjLOE3v6G5YT/On3Wvp9ceHEO
# 5M0m0DlaDxwt3aOsLDjCAA0koYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJ
# KoZIhvcNAQcCoIIX6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3
# DQEJEAEEoIIBUQSCAU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIB
# BQAEIN9kOKb5/UzGEyFziAA2Z0qpENioqa4CHgTRKY+v+BEOAgZp1AaM8lcYEzIw
# MjYwNDE1MDgxMjEyLjUzMVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAt
# RDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGlu
# ZyBBdXRob3JpdHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAA
# BTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVy
# aWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAx
# MTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBv
# f7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDs
# fMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbB
# T7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5
# EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6
# ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fj
# JHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOs
# RpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiun
# hKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE
# 3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8
# cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMB
# AAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYD
# VR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTI
# ftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHkl
# MjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHkl
# MjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElk
# ZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0
# aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXn
# THho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC
# 2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5
# zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbN
# nCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqs
# t8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVm
# oNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRS
# SvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7v
# PKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/2
# 6ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/
# AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSO
# iUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJ
# MQAAAAAAVzANBgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGlj
# IFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEw
# MjIyMDQ2NTNaMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQL
# Ex5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jv
# c29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbA
# meKSZ5ex7/jCymdV7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkH
# kAI21MoCN+YWnhT8K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfF
# BK15JuD3JOzWuF2suQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2P
# fZ154w041po+fDeTj0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4Rb
# JXk8ONXyOOfXOxK2VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaL
# NNaYtm8AT/pZHYJ35mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07
# ZZm74JCsfhmrQ1ijVNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr
# 2kPuj1jHDOXzUG4O9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw
# /3bI/wBGNvLk6fLVnrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX
# 6PNZv+vzSeqVeWWHKdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksa
# i4TURnVj2mMCAwEAAaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD
# 7RKSpzAfBgNVHSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBj
# MGGgX6BdhltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAu
# Y3JsMHkGCCsGAQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0El
# MjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0w
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJ
# KoZIhvcNAQEMBQADggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ
# 4uPENCSOwkRTnNogPLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTC
# FVrPBJKEWVshm+Ig7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXh
# GueBxlnSvjkAX1ohiN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8O
# WweqTWZcGlJO4YjZNI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oI
# WKKXWaBYJY5P3QPsiC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40
# fUNveRnwzMQnx8dM2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgj
# vd/Deo7Xr371PFPPYb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F
# 9H9/wSLsMDUvWME7u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs3
# 0yBhuE3QhqT1YDZ2pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYu
# XcoeDcwe2UaC7EDOGD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1
# MYIHQzCCBz8CAQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQME
# AgEFAKCCBJwwEQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYwNDE1MDgxMjEyWjAvBgkqhkiG9w0B
# CQQxIgQgqD35hfdKMRMfHUzdGyXmn5ZqNJBPi0ijMXgMSg7se0AwgbkGCyqGSIb3
# DQEJEAIvMYGpMIGmMIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmF
# THjbUjB8MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzCCA14GCyqGSIb3DQEJ
# EAISMYIDTTCCA0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQg
# QW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046Nzgw
# MC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUg
# U3RhbXBpbmcgQXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3x
# aKKPXHnLw6BnMGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2JubswIhgPMjAyNjA0
# MTUwNzE2MTFaGA8yMDI2MDQxNjA3MTYxMVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7Ym5uwIBADAHAgEAAgIpsjAHAgEAAgISwDAKAgUA7YsLOwIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQBstvS3+/NPqAhizZgIbxmhqvas6pl+ZMuWSAqM
# sYq1GzZUuJbqmLYfYMBhML4TsauX7Y9h861mLH1LemHAxoVHmgIYHxYSIzKAbs8n
# dTGjZXBD7mgzNHejhzzWXNkv4tXA0k0yFK39T3DsPeUXrer16l+Brk6ll3FUElVt
# +wLj8LS952fz+4ydMf2OKnSoj5WLOkX07mbw34J0rJgqqpI/s4/FA1/+EJSOPCkt
# fUbYCef8xplQcrUOKU8LDUGaUr+vuFBjUlcGbYWfkyjSk4KwNqaJI8wzEvzpprnh
# yYDDZXiW1JJCezfdvr4BOBoFZJvC6CFeKnRzHgPCXfTAqI71MA0GCSqGSIb3DQEB
# AQUABIICAJ0uCMq2WbI/CBmZmEsl3S8FkVgGyN4wvbT4/oVYg7mkKNnw9I5iw8Vd
# u3cceJOqhOMqZxyYzZJ8FjN/dc+EhNww7KmNX1HldOEGD7YM//qwlc8FlP8vvx2m
# LD4QHnJObSI6MllrGiPe4ucNE8+BPf8S8hwwPJKAblPgYWVwtXWMb7PCT/yiibx8
# 5d6Ntjx9VeC38CGuKCfRtXVBUPUS0uElsXIPLk2zxkdaimRE4Ppt5ZJgKq3tmO7u
# uUsrHEx9mGlGqj3qJEM3WljkHuTYE+PIr7TKdRu4GLjOZARH7rIA4hpOn1ibMxLv
# ajtgKj2jX0S+VhUN5h+UeTWmtW2+kSHg/xdUC1H8UaDmlkRJ6Iszr3mAkqB9y+nW
# i4twuKOCEQuP2LHpvtuMRPUaEeZYA/FMB8sdetOHBn7/qP9EkbAtmCw0MMyuF7Z6
# Ske9QNlc36AFvbAHFZk7IfkBiyGKD9Lvq/0hb8c+VdkZkcM2qB6mzPJKJ0xQgHXb
# fuyo9sUXB26hiZbRD62Y92NjPn/Fti4MU3cctNM1iDDAOZr1KKUabUgUnon4R7I2
# KjgEu0UQWmeRsHi8MbvUCTuFTTVb7KVBEDF7RMXQzdhm3txPVdUz5M7NQoZa2xVp
# OgaUgTY++poI+idomxgGHsH8zZIPbNR74JdrLvO68zA+Fp2wxv40
# SIG # End signature block
