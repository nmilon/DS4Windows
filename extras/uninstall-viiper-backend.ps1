param(
    [switch]$NoPause,
    [switch]$RemoveUsbip
)

# Removes what install-viiper-backend.ps1 leaves behind. Upstream ships no
# uninstall path, so removing DS4Windows used to leave the RunVIIPER logon task
# still starting an elevated backend at every sign-in.
#
# usbip-win2 is left alone unless -RemoveUsbip is passed: it is a shared
# kernel-mode driver that other software may also depend on.

$ErrorActionPreference = "Stop"
$script:ExitCode = 0
$script:TaskName = "RunVIIPER"
$script:InstallDirs = @(
    (Join-Path $env:ProgramFiles "VIIPER"),
    (Join-Path $env:LOCALAPPDATA "VIIPER")
)

function Write-Line([string]$message, [ConsoleColor]$color = [ConsoleColor]::Gray) {
    Write-Host $message -ForegroundColor $color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-ViiperProcesses {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $processes = @(Get-CimInstance Win32_Process `
            -Filter "Name='viiper.exe'" -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) { return $true }

        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }
        Start-Sleep -Milliseconds 300
    }

    return $false
}

try {
    if (-not (Test-Administrator)) {
        throw "Administrator permission is required to remove the scheduled task and Program Files install."
    }

    Write-Line ""
    Write-Line "Removing the VIIPER backend" Green

    Write-Line "Removing scheduled task '$script:TaskName'..."
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-Line "Removed." Green
    }
    else {
        Write-Line "Not present." Yellow
    }

    Write-Line "Stopping viiper.exe..."
    if (-not (Stop-ViiperProcesses)) {
        Write-Line "A viiper.exe process is still running; close it and rerun." Yellow
    }

    foreach ($dir in $script:InstallDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }

        Write-Line "Removing $dir..."
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            Write-Line "Removed." Green
        }
        catch {
            $script:ExitCode = 1
            Write-Line "Could not remove: $($_.Exception.Message)" Red
        }
    }

    if ($RemoveUsbip) {
        Write-Line ""
        Write-Line "Looking for the usbip-win2 uninstaller..."
        $entry = foreach ($root in @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )) {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { ($_.DisplayName -as [string]) -match "USB/IP|USBip" } |
                Select-Object -First 1
        }

        $entry = @($entry) | Select-Object -First 1
        if ($entry -and $entry.UninstallString) {
            $uninstallPath = $entry.UninstallString.Trim('"')
            Write-Line "Running $uninstallPath /S"
            $proc = Start-Process -FilePath $uninstallPath -ArgumentList "/S" `
                -PassThru -Wait
            Write-Line "Uninstaller exited with code $($proc.ExitCode)." Green
            Write-Line "Restart Windows to finish removing the driver." Yellow
        }
        else {
            Write-Line "No usbip-win2 uninstall entry found." Yellow
        }
    }
    else {
        Write-Line ""
        Write-Line ("usbip-win2 was left installed. It is a shared kernel " +
            "driver; rerun with -RemoveUsbip to remove it too.") Yellow
    }

    Write-Line ""
    Write-Line "Done." Green
}
catch {
    $script:ExitCode = 1
    Write-Line ""
    Write-Line "Uninstall could not finish: $($_.Exception.Message)" Red
}
finally {
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
}

exit $script:ExitCode
