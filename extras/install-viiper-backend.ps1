param(
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:ExitCode = 0
$script:RebootRecommended = $false
# Program Files, not LOCALAPPDATA: the logon task below runs viiper.exe
# elevated, so the binary must sit somewhere only administrators can write.
# Using LOCALAPPDATA meant any process running as the user could replace it and
# gain silent administrator execution at the next sign-in.
$script:InstallDir = Join-Path $env:ProgramFiles "VIIPER"
$script:LegacyInstallDir = Join-Path $env:LOCALAPPDATA "VIIPER"
$script:LogPath = Join-Path $script:InstallDir "install.log"
$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) (
    "DS4Windows-VIIPER-Setup-" + [Guid]::NewGuid().ToString("N"))

function Write-SetupLog([string]$message, [ConsoleColor]$color =
        [ConsoleColor]::Gray) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host $message -ForegroundColor $color
    try {
        Add-Content -LiteralPath $script:LogPath -Value (
            "[$timestamp] $message") -Encoding UTF8
    }
    catch { }
}

function Write-Step([string]$message) {
    Write-Host ""
    Write-SetupLog "== $message ==" Cyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UsbipInstalledVersion {
    $driverPath = Join-Path $env:SystemRoot "System32\drivers\usbip2_ude.sys"
    if (Test-Path -LiteralPath $driverPath) {
        try {
            $versionText = (Get-Item -LiteralPath $driverPath).
                VersionInfo.FileVersion
            $version = ConvertTo-VersionFromObject $versionText
            if ($version) { return $version }
        }
        catch { }
    }

    foreach ($root in @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        $entry = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object {
                $displayName = $_.DisplayName
                if ($null -eq $displayName) { return $false }
                $nameText = $displayName -as [string]
                return $nameText -match "USB/IP|USBip"
            } |
            Select-Object -First 1
        if ($entry -and $entry.DisplayVersion) {
            $version = ConvertTo-VersionFromObject $entry.DisplayVersion
            if ($version) { return $version }
        }
    }

    return $null
}

function ConvertTo-VersionFromObject([object]$value) {
    if ($null -eq $value) { return $null }
    if ($value -is [Version]) { return $value }

    try {
        if ($value -is [string]) {
            $text = $value.Trim()
        }
        else {
            $text = [string]$value
            if ($null -eq $text) { return $null }
            $text = $text.Trim()
        }
    }
    catch { return $null }

    if ($text.Length -eq 0) { return $null }

    $parsed = $null
    if ([Version]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

# Pinned artifacts. Nothing is executed unless its SHA-256 matches, so a
# compromised or hijacked release account cannot hand this script a different
# binary. Bumping a version means deliberately updating the hash next to it:
# download the asset, run Get-FileHash -Algorithm SHA256, paste the result.
$script:ViiperVersion = "v0.0.5"
$script:ViiperUrl =
    "https://github.com/hbashton/VIIPER/releases/download/v0.0.5/viiper.exe"
$script:ViiperSha256 =
    "3AD872D006DF2FC282E381A68B5A5B3C51E4DA3614D250AB3FDA1C272EF745D0"
$script:UsbipVersion = "0.9.7.7"
$script:UsbipUrl =
    "https://github.com/vadimgrn/usbip-win2/releases/download/v.0.9.7.7/USBip-0.9.7.7-x64.exe"
$script:UsbipSha256 =
    "51620FA5F9F8BE5932BC9D786DEEE557CE06D5407A99CAB490DCFAC71F185FEA"

# VIIPER defaults both listeners to every interface (":3241" / ":3242"), and its
# USB/IP port has no authentication at all. Keep both on loopback. This must
# stay in sync with ViiperSetupManager.ServerArguments.
$script:ServerArguments =
    "server --usb.addr 127.0.0.1:3241 --api.addr 127.0.0.1:3242"

function Assert-FileHash([string]$path, [string]$expected, [string]$label) {
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw ("$label failed verification and was discarded. Expected SHA-256 " +
               "$expected but got $actual. Nothing was installed. Do not " +
               "bypass this check: either the download was corrupted or the " +
               "published artifact changed.")
    }
    Write-SetupLog "$label verified (SHA-256 $actual)." Green
}

function Invoke-Download([string]$url, [string]$outFile) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-SetupLog "Downloading $url (attempt $attempt of 3)"
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing `
                -TimeoutSec 60 -Headers @{ "User-Agent" =
                    "DS4Windows-VIIPER-Setup" }
            if (-not (Test-Path -LiteralPath $outFile) -or
                (Get-Item -LiteralPath $outFile).Length -le 0) {
                throw "The downloaded file was empty."
            }
            return
        }
        catch {
            $lastError = $_.Exception
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        }
    }

    throw "Download failed after three attempts: $($lastError.Message)"
}

function Get-ViiperAsset([string]$candidatePath) {
    # The old code asked the GitHub API for the newest non-draft release and ran
    # whatever *.exe/*.zip it found first, which also picked up prereleases.
    # Fetch exactly one pinned, hash-verified artifact instead.
    Write-SetupLog "Fetching VIIPER $script:ViiperVersion (pinned)."
    $downloadPath = Join-Path $script:TempDir "viiper-download.exe"
    Invoke-Download $script:ViiperUrl $downloadPath
    Assert-FileHash $downloadPath $script:ViiperSha256 "VIIPER $script:ViiperVersion"
    Copy-Item -LiteralPath $downloadPath -Destination $candidatePath -Force
}

function Install-ViiperAtomically([string]$candidatePath,
        [string]$viiperPath) {
    $newPath = "$viiperPath.new"
    $backupPath = "$viiperPath.previous"
    Copy-Item -LiteralPath $candidatePath -Destination $newPath -Force

    # An explicit repair/update may replace a running backend. Stop only the
    # VIIPER process and leave DS4Windows and every physical Bluetooth device
    # alone.
    $stopped = Stop-ViiperProcesses "backend replacement"
    if (-not $stopped) {
        throw "Unable to stop the currently running VIIPER process automatically during install. " +
              "Please close viiper.exe manually and try again."
    }
    Start-Sleep -Milliseconds 300

    try {
        if (Test-Path -LiteralPath $viiperPath) {
            [IO.File]::Replace($newPath, $viiperPath, $backupPath, $true)
        }
        else {
            Move-Item -LiteralPath $newPath -Destination $viiperPath -Force
        }
    }
    catch {
        if (Test-Path -LiteralPath $backupPath) {
            Copy-Item -LiteralPath $backupPath -Destination $viiperPath -Force
        }
        throw
    }
}

function Get-RunningViiperProcesses {
    try {
        Get-CimInstance Win32_Process -Filter "Name='viiper.exe'" -ErrorAction SilentlyContinue
    }
    catch {
        @()
    }
}

function Stop-ViiperProcesses([string]$operation) {
    $attempts = 12
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $processes = @(Get-RunningViiperProcesses)
        if ($processes.Count -eq 0) { return $true }

        if ($attempt -eq 1) {
            Write-SetupLog "Stopping VIIPER process(es) for $operation..." Yellow
        }

        foreach ($process in $processes) {
            if ($process.ProcessId -eq $PID) { continue }
            try {
                $identifier = if ($process.ExecutablePath) {
                    $process.ExecutablePath
                }
                else {
                    $process.ProcessId
                }
                Write-SetupLog "Stopping viiper PID=$($process.ProcessId) ($identifier)." Yellow
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }

        Start-Sleep -Milliseconds 300

        $remaining = @(Get-RunningViiperProcesses)
        if ($remaining.Count -eq 0) { return $true }

        if ($attempt -ge 3) {
            foreach ($process in $remaining) {
                if ($process.ProcessId -eq $PID) { continue }
                try {
                    & taskkill.exe /PID $process.ProcessId /T /F | Out-Null
                }
                catch { }
            }
            Start-Sleep -Milliseconds 200
        }
    }

    Write-SetupLog (
        "A VIIPER process is still running after stop attempts. " +
        "Please close viiper.exe manually and rerun Install/Repair."
    ) Yellow
    return $false
}

function Test-ViiperApi([int]$timeoutMilliseconds = 1000) {
    $client = $null
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $client.NoDelay = $true
        $client.SendTimeout = $timeoutMilliseconds
        $client.ReceiveTimeout = $timeoutMilliseconds
        $connect = $client.BeginConnect("127.0.0.1", 3242, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($timeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($connect)
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::UTF8.GetBytes("ping`0")
        $stream.Write($bytes, 0, $bytes.Length)
        $buffer = New-Object byte[] 512
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $false }
        $response = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        return $response.IndexOf("VIIPER",
            [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    catch { return $false }
    finally { if ($client) { $client.Dispose() } }
}

function Start-AndVerifyViiper([string]$viiperPath) {
    if (Test-ViiperApi) { return $true }
    Start-Process -FilePath $viiperPath -ArgumentList $script:ServerArguments `
        -WindowStyle Hidden | Out-Null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Milliseconds 500
        if (Test-ViiperApi) { return $true }
    }
    return $false
}

function Register-ViiperRunTask([string]$viiperPath, [string]$taskName) {
    try {
        $taskAction = New-ScheduledTaskAction -Execute $viiperPath `
            -Argument $script:ServerArguments
        $taskTrigger = New-ScheduledTaskTrigger -AtLogOn
        $taskPrincipal = New-ScheduledTaskPrincipal `
            -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -RunLevel Highest -LogonType Interactive
        $taskSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName -Action $taskAction `
            -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings `
            -Force | Out-Null
        return $true
    }
    catch {
        Write-SetupLog "Failed modern scheduled task registration: $($_.Exception.Message)" Yellow
    }

    try {
        $runCommand = '"{0}" {1}' -f $viiperPath, $script:ServerArguments
        $scheduledResult = Start-Process -FilePath "schtasks.exe" `
            -ArgumentList "/Create /F /TN `"$taskName`" /SC ONLOGON /RL HIGHEST /IT /TR `"$runCommand`"" `
            -WindowStyle Hidden -PassThru -Wait
        if ($scheduledResult.ExitCode -eq 0) {
            return $true
        }

        Write-SetupLog "Fallback schtasks command exited with code $($scheduledResult.ExitCode)." Yellow
    }
    catch {
        Write-SetupLog "Failed fallback scheduled task registration: $($_.Exception.Message)" Yellow
    }

    return $false
}

try {
    if (-not (Test-Administrator)) {
        throw "Administrator permission is required. Launch setup from DS4Windows so Windows can request it automatically."
    }

    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
    Write-SetupLog ""
    Write-SetupLog "DS4Windows VIIPER virtual controller setup" Green
    Write-SetupLog "Installing or repairing VIIPER and usbip-win2."

    Write-Step "Checking usbip-win2"
    $requiredUsbipVersion = [Version]$script:UsbipVersion
    try {
        $usbipVersion = Get-UsbipInstalledVersion
    }
    catch {
        Write-SetupLog "usbip-win2 version check failed: $($_.Exception.Message)" Yellow
        $usbipVersion = $null
    }
    if ($usbipVersion -and $usbipVersion -ge $requiredUsbipVersion) {
        Write-SetupLog "usbip-win2 is ready: $usbipVersion" Green
    }
    else {
        $state = if ($usbipVersion) { "old ($usbipVersion)" } else { "missing" }
        Write-SetupLog "usbip-win2 is $state; installing $requiredUsbipVersion." Yellow
        $usbipInstaller = Join-Path $script:TempDir "USBip-$script:UsbipVersion-x64.exe"
        Invoke-Download $script:UsbipUrl $usbipInstaller
        # This installs a kernel-mode driver. Verify before running it.
        Assert-FileHash $usbipInstaller $script:UsbipSha256 `
            "usbip-win2 $script:UsbipVersion installer"
        Write-SetupLog "Windows may briefly restart USB hub devices." Yellow
        $installer = Start-Process -FilePath $usbipInstaller `
            -ArgumentList "/S" -PassThru -Wait
        if ($installer.ExitCode -notin @(0, 1641, 3010)) {
            throw "usbip-win2 setup failed with exit code $($installer.ExitCode)."
        }
        if ($installer.ExitCode -in @(1641, 3010)) {
            $script:RebootRecommended = $true
        }
        $usbipVersion = Get-UsbipInstalledVersion
        if (-not $usbipVersion) {
            $script:RebootRecommended = $true
            Write-SetupLog "The driver will finish registering after a Windows restart." Yellow
        }
    }

    Write-Step "Installing VIIPER"
    $viiperPath = Join-Path $script:InstallDir "viiper.exe"
    $candidatePath = Join-Path $script:TempDir "viiper.exe"
    Get-ViiperAsset $candidatePath
    Install-ViiperAtomically $candidatePath $viiperPath
    Write-SetupLog "VIIPER installed to $viiperPath" Green

    Write-Step "Registering VIIPER"
    $registrationSafeToRun = $true
    if (-not (Stop-ViiperProcesses "install registration")) {
        $registrationSafeToRun = $false
    }

    $registration = Start-Process -FilePath $viiperPath `
        -ArgumentList "install" -WindowStyle Hidden -PassThru -Wait
    if ($registration.ExitCode -ne 0) {
        if (-not $registrationSafeToRun) {
            throw "VIIPER registration could not proceed because a VIIPER process could not be closed automatically. " +
                  "Please close viiper.exe manually, then run Install / Repair again."
        }
        throw "VIIPER registration failed with exit code $($registration.ExitCode)."
    }

    $taskName = "RunVIIPER"
    if (Register-ViiperRunTask $viiperPath $taskName) {
        Write-SetupLog "Registered hidden logon task '$taskName'." Green
    }
    else {
        Write-SetupLog "Could not create hidden logon task. Setup will continue; VIIPER can still be started by DS4Windows when needed." Yellow
    }

    # A leftover copy under LOCALAPPDATA is exactly the writable binary this
    # relocation exists to remove, so clear it out once the new one is in place.
    if (Test-Path -LiteralPath $script:LegacyInstallDir) {
        Write-Step "Removing previous user-writable install"
        try {
            Stop-ViiperProcesses "legacy cleanup" | Out-Null
            Remove-Item -LiteralPath $script:LegacyInstallDir -Recurse -Force `
                -ErrorAction Stop
            Write-SetupLog "Removed $script:LegacyInstallDir" Green
        }
        catch {
            Write-SetupLog (
                "Could not remove $script:LegacyInstallDir " +
                "($($_.Exception.Message)). Delete it manually." ) Yellow
        }
    }

    Write-Step "Verification"
    if (Start-AndVerifyViiper $viiperPath) {
        Write-SetupLog "VIIPER API is ready." Green
        $backupPath = "$viiperPath.previous"
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    elseif ($script:RebootRecommended) {
        Write-SetupLog "VIIPER is installed; restart Windows to finish driver setup." Yellow
    }
    else {
        throw "VIIPER installed, but its local API did not start. See $script:LogPath"
    }

    Write-Host ""
    $finish = if ($script:RebootRecommended) {
        "Setup complete. Restart Windows once before using a virtual controller."
    } else {
        "Setup complete. VIIPER is ready for DS4Windows."
    }
    Write-SetupLog $finish Green
}
catch {
    $script:ExitCode = 1
    Write-Host ""
    Write-SetupLog "Setup could not finish: $($_.Exception.Message)" Red
    Write-SetupLog "Details were saved to $script:LogPath" Yellow
}
finally {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close"
    }
}

exit $script:ExitCode
