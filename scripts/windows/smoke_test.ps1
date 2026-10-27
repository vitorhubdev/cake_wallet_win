[CmdletBinding()]
param(
    [string]$BundlePath = 'build\windows\x64\runner\Release',
    [string]$DiagnosticsPath = 'build\windows-smoke',
    [string[]]$NativeLibraries = @(
        'libmonero_wallet2_api_c.dll',
        'libwownero_wallet2_api_c.dll',
        'libwinpthread-1.dll',
        'mweb.dll'
    ),
    [ValidateRange(10, 120)]
    [int]$StartupTimeoutSeconds = 45,
    # Internal subprocess mode: isolates native DLL initializers from this process.
    [switch]$ProbeLibrariesOnly,
    [string]$NativeLibraryManifest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This smoke test requires Windows x64.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run the smoke test from a 64-bit PowerShell process.'
}

$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$diagnostics = [IO.Path]::GetFullPath($DiagnosticsPath)
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null

if ($ProbeLibrariesOnly) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CakeNativeLibraryProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
}
'@
    $libraries = @(Get-Content -LiteralPath $NativeLibraryManifest -Raw | ConvertFrom-Json)
    foreach ($library in $libraries) {
        $path = Join-Path $bundle $library
        # Search only the DLL's directory and normal application/system directories.
        # Do not rely on a build-tool directory in PATH to satisfy missing DLLs.
        $handle = [CakeNativeLibraryProbe]::LoadLibraryEx($path, [IntPtr]::Zero, 0x1100)
        if ($handle -eq [IntPtr]::Zero) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $message = [ComponentModel.Win32Exception]::new($code).Message
            throw "Cannot load ${library}: Win32 error $code ($message)"
        }
        Write-Output "Loaded $library"
        # In particular, Go c-shared libraries are not safe to unload with
        # FreeLibrary. This dedicated process owns their entire lifetime.
    }
    exit 0
}

# CAKE_WALLET_DIR isolates wallet files, but native secure storage and shared
# preferences belong to the Windows user. Do not run against a personal profile.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this test only in a disposable GitHub-hosted Windows runner, never in a personal wallet profile.'
}

$requiredFiles = @(
    'CakeWallet.exe',
    'flutter_windows.dll',
    'msvcp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'data\icudtl.dat',
    'data\app.so',
    'data\flutter_assets\AssetManifest.bin'
) + $NativeLibraries

$report = [ordered]@{
    status = 'running'
    startedAt = [DateTime]::UtcNow.ToString('o')
    bundle = $bundle
    requiredFiles = @()
    nativeLibrariesLoaded = $false
    windowObserved = $false
    screenshot = $null
    limitation = 'Bundle/loader/process smoke only. A live window does not prove onboarding, wallet recovery, synchronization or transactions; run windows_startup_test.dart as well.'
}
$appProcess = $null
$probeProcess = $null
$previousWalletDir = $env:CAKE_WALLET_DIR
$profile = Join-Path $env:RUNNER_TEMP ('cake-wallet-smoke-' + [Guid]::NewGuid().ToString('N'))

try {
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $bundle $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing required bundle file: $relativePath"
        }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -eq 0) {
            throw "Empty required bundle file: $relativePath"
        }
        $report.requiredFiles += [ordered]@{
            path = $relativePath
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    # Also resolve the plugin DLLs that the Flutter engine loads at startup.
    $libraries = @($NativeLibraries) + @(
        Get-ChildItem -LiteralPath $bundle -Filter '*_plugin.dll' -File |
            Select-Object -ExpandProperty Name
    ) + @(
        # sqlite3's native-assets hook may choose a version-specific filename.
        Get-ChildItem -LiteralPath $bundle -Filter '*sqlite*.dll' -File |
            Select-Object -ExpandProperty Name
    )
    $libraries = @($libraries | Sort-Object -Unique)
    $manifest = Join-Path $diagnostics 'native-libraries.json'
    ConvertTo-Json -InputObject $libraries | Set-Content -LiteralPath $manifest -Encoding utf8
    $powershell = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $powershell)) {
        $powershell = Join-Path $PSHOME 'powershell.exe'
    }
    $probeArgs = @(
        '-NoProfile', '-NonInteractive', '-File', ('"' + $PSCommandPath + '"'),
        '-ProbeLibrariesOnly', '-BundlePath', ('"' + $bundle + '"'),
        '-DiagnosticsPath', ('"' + $diagnostics + '"'),
        '-NativeLibraryManifest', ('"' + $manifest + '"')
    )
    $probeProcess = Start-Process -FilePath $powershell -ArgumentList $probeArgs -PassThru `
        -RedirectStandardOutput (Join-Path $diagnostics 'native-loader.stdout.log') `
        -RedirectStandardError (Join-Path $diagnostics 'native-loader.stderr.log')
    if (-not $probeProcess.WaitForExit(60000)) {
        throw 'Native DLL loading did not finish within 60 seconds.'
    }
    if ($probeProcess.ExitCode -ne 0) {
        throw "Native DLL loader exited with code $($probeProcess.ExitCode); see native-loader.stderr.log."
    }
    $report.nativeLibrariesLoaded = $true

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CakeWindowProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
'@

    New-Item -ItemType Directory -Path $profile | Out-Null
    $env:CAKE_WALLET_DIR = $profile
    $appProcess = Start-Process -FilePath (Join-Path $bundle 'CakeWallet.exe') `
        -WorkingDirectory $bundle -PassThru `
        -RedirectStandardOutput (Join-Path $diagnostics 'app.stdout.log') `
        -RedirectStandardError (Join-Path $diagnostics 'app.stderr.log')

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $visibleSince = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $appProcess.Refresh()
        if ($appProcess.HasExited) {
            throw "CakeWallet.exe exited during startup with code $($appProcess.ExitCode)."
        }
        $visible = $appProcess.MainWindowHandle -ne [IntPtr]::Zero -and `
            [CakeWindowProbe]::IsWindowVisible($appProcess.MainWindowHandle)
        if ($visible -and $appProcess.Responding) {
            if ($null -eq $visibleSince) { $visibleSince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $visibleSince).TotalSeconds -ge 10) {
                $report.windowObserved = $true
                break
            }
        } else {
            $visibleSince = $null
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $report.windowObserved) {
        throw "No continuously responsive, visible Cake Wallet window within $StartupTimeoutSeconds seconds."
    }

    # Diagnostic image only; an image alone is not an application assertion.
    try {
        Add-Type -AssemblyName System.Drawing
        $rect = [CakeWindowProbe+Rect]::new()
        if ([CakeWindowProbe]::GetWindowRect($appProcess.MainWindowHandle, [ref]$rect)) {
            $bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $dc = $graphics.GetHdc()
                try { $captured = [CakeWindowProbe]::PrintWindow($appProcess.MainWindowHandle, $dc, 2) }
                finally { $graphics.ReleaseHdc($dc) }
                if ($captured) {
                    $screenshot = Join-Path $diagnostics 'startup-window.png'
                    $bitmap.Save($screenshot, [Drawing.Imaging.ImageFormat]::Png)
                    $report.screenshot = 'startup-window.png'
                }
            } finally {
                $graphics.Dispose()
                $bitmap.Dispose()
            }
        }
    } catch {
        Write-Warning "Could not capture the diagnostic window: $_"
    }

    $errorFile = Join-Path $profile 'error.txt'
    if ((Test-Path -LiteralPath $errorFile) -and (Get-Item -LiteralPath $errorFile).Length -gt 0) {
        Copy-Item -LiteralPath $errorFile -Destination (Join-Path $diagnostics 'app-error.txt')
        throw 'The application recorded an unhandled startup error; see app-error.txt.'
    }

    $report.status = 'passed'
    Write-Output 'Bundle files, native DLL loading, and a responsive visible process passed. Check the separate Flutter onboarding test for application startup.'
} catch {
    $report.status = 'failed'
    $report.error = $_.ToString()
    throw
} finally {
    foreach ($ownedProcess in @($appProcess, $probeProcess)) {
        if ($null -eq $ownedProcess) { continue }
        try {
            if (-not $ownedProcess.HasExited) {
                [void]$ownedProcess.CloseMainWindow()
                if (-not $ownedProcess.WaitForExit(5000)) {
                    $ownedProcess.Kill()
                    [void]$ownedProcess.WaitForExit(5000)
                }
            }
        } catch { Write-Warning "Could not stop test-owned process $($ownedProcess.Id): $_" }
        finally { $ownedProcess.Dispose() }
    }
    $env:CAKE_WALLET_DIR = $previousWalletDir
    $report.finishedAt = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $diagnostics 'smoke-report.json') -Encoding utf8
}
