[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,
    [string]$PreviousInstallerPath,
    [string]$BundlePath = 'build\windows\x64\runner\Release',
    [string]$DiagnosticsPath = 'build\windows-install-smoke'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or
    $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Installer validation requires a disposable GitHub-hosted Windows x64 runner.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is required.' }
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\vitorhubdev.cake_wallet_win_is1'
if (Test-Path -LiteralPath $uninstallKey) {
    throw 'Refusing to replace an existing installation during a smoke test.'
}

$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$diagnostics = [IO.Path]::GetFullPath($DiagnosticsPath)
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
$testRoot = Join-Path $env:RUNNER_TEMP ('cake-installer-' + [Guid]::NewGuid().ToString('N'))
$installation = Join-Path $testRoot 'Cake Wallet Windows'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$uninstaller = Join-Path $installation 'unins000.exe'
$failure = $null
$profileData = Join-Path $env:APPDATA 'vitorhubdev/Cake Wallet Windows'
New-Item -ItemType Directory -Path $profileData -Force | Out-Null
$sentinel = Join-Path $profileData ('installer-test-' + [Guid]::NewGuid().ToString('N') + '.txt')
$sentinelValue = [Guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($sentinel, $sentinelValue)
$report = [ordered]@{
    status = 'running'
    installer = $installer
    installation = $installation
    startedAt = [DateTime]::UtcNow.ToString('o')
    installedExeMatches = $false
    upgradedFromPrevious = $false
    userDataPreserved = $false
    applicationSmokePassed = $false
    uninstalled = $false
}

function Invoke-OwnedSetupProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 180)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Installer process exceeded its $TimeoutSeconds-second deadline."
            }
        }
        if ($process.ExitCode -ne 0) { throw "Installer process exited with code $($process.ExitCode)." }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
        }
        $process.Dispose()
    }
}

try {
    if ($PreviousInstallerPath) {
        $previous = (Resolve-Path -LiteralPath $PreviousInstallerPath).Path
        Invoke-OwnedSetupProcess -FilePath $previous -Arguments @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
            '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/TASKS=',
            "/DIR=$installation", "/LOG=$(Join-Path $diagnostics 'previous-install.log')"
        )
        if (-not (Test-Path -LiteralPath (Join-Path $installation 'CakeWallet.exe'))) {
            throw 'The previous installer did not create its application.'
        }
    }
    Invoke-OwnedSetupProcess -FilePath $installer -Arguments @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/TASKS=',
        "/DIR=$installation", "/LOG=$(Join-Path $diagnostics 'install.log')"
    )
    $installedExe = Join-Path $installation 'CakeWallet.exe'
    if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        throw 'The installer did not create CakeWallet.exe at the requested location.'
    }
    $expected = (Get-FileHash -LiteralPath (Join-Path $bundle 'CakeWallet.exe') -Algorithm SHA256).Hash
    $actual = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
    if ($expected -ne $actual) { throw 'The installed executable differs from the validated bundle.' }
    $report.installedExeMatches = $true
    $report.upgradedFromPrevious = [bool]$PreviousInstallerPath
    if ([IO.File]::ReadAllText($sentinel) -ne $sentinelValue) {
        throw 'The upgrade changed the data preservation sentinel.'
    }
    & (Join-Path $PSScriptRoot 'smoke_test.ps1') -BundlePath $installation `
        -DiagnosticsPath (Join-Path $diagnostics 'application')
    $report.applicationSmokePassed = $true
} catch {
    $failure = $_
} finally {
    try {
        if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
            Invoke-OwnedSetupProcess -FilePath $uninstaller -Arguments @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
                "/LOG=$(Join-Path $diagnostics 'uninstall.log')"
            )
            if (Test-Path -LiteralPath (Join-Path $installation 'CakeWallet.exe')) {
                throw 'The installer smoke test left its installed application behind.'
            }
            if (Test-Path -LiteralPath $uninstallKey) { throw 'The uninstall registry entry was not removed.' }
            $report.uninstalled = $true
            if ([IO.File]::ReadAllText($sentinel) -ne $sentinelValue) {
                throw 'Uninstallation changed the data preservation sentinel.'
            }
            $report.userDataPreserved = $true
        } elseif ($null -eq $failure) {
            throw 'The installed application has no uninstaller.'
        }
    } catch {
        if ($null -eq $failure) { $failure = $_ }
        else { Write-Warning "Installer cleanup also failed: $_" }
    }
    # Only this test's own sentinel is removed. Never remove the data directory.
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    $report.status = if ($null -eq $failure) { 'passed' } else { 'failed' }
    if ($null -ne $failure) { $report.error = $failure.ToString() }
    $report.finishedAt = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $diagnostics 'installer-report.json') -Encoding utf8
    # Only this test's unique temporary directory is eligible for cleanup.
    # No AppData directory or user wallet is deleted by the installer or test.
    if ($report.uninstalled) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($null -ne $failure) { throw $failure }
Write-Output 'Installer creation, exact executable installation, DLL/application smoke, and uninstall passed.'
