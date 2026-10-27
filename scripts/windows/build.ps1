[CmdletBinding()]
param(
    [string]$Version = '6.5.0',
    [int]$BuildNumber = 1,
    [switch]$SkipPrepare,
    [ValidateSet('All', 'Configure', 'Generate', 'Build')]
    [string]$Stage = 'All'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Resolve-CachedFlutterDependencies {
    # The root resolution has already fetched the pinned dependency set.
    # Avoid fetching hundreds of Git refs again for every cw_* package.
    try {
        flutter pub get --offline
    } catch {
        Write-Warning 'The package needs an additional dependency; resolving it online.'
        flutter pub get
    }
}

function Get-VisualCppRuntimeDirectory {
    param([Parameter(Mandatory)][string]$RedistRoot)

    # New Visual Studio images also use a "v143" directory. Folder names are
    # not versions; inspect the runtime DLL itself and keep only complete x64 sets.
    $candidates = Get-ChildItem -LiteralPath $RedistRoot -Directory |
        ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_ 'vcruntime140.dll') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $_ 'vcruntime140_1.dll') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $_ 'msvcp140.dll') -PathType Leaf)
        }
    $selected = $candidates |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_ 'vcruntime140.dll')).VersionInfo.FileVersionRaw } -Descending |
        Select-Object -First 1
    if (-not $selected) { throw 'A complete Visual C++ x64 redistributable directory was not found.' }
    return $selected
}

Push-Location $root
try {
    if (-not $IsWindows) { throw 'This script requires PowerShell 7 on Windows x64.' }
    if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $BuildNumber -lt 1) { throw 'Invalid build version.' }
    if ($Stage -in @('All', 'Configure')) {
        if (-not $SkipPrepare) {
            python scripts/windows/prepare_dependencies.py
            if ($LASTEXITCODE) { throw 'Dependency preparation failed.' }
        }

        flutter config --enable-windows-desktop --no-analytics
        flutter doctor -v
        Copy-Item assets/images/cakewallet_logo.png assets/images/app_logo.png -Force
        # These entry points only use dart:io and do not need a resolved pubspec.
        dart tool/generate_pubspec.dart
        dart tool/configure.dart --monero --bitcoin --ethereum --polygon --nano --bitcoinCash --solana --tron --dogecoin --base --arbitrum --bsc --robinhood
        $pubspec = (Get-Content pubspec.yaml -Raw) -replace '(?m)^version: 0\.0\.0\r?$', "version: $Version+$BuildNumber"
        [IO.File]::WriteAllText((Join-Path $root 'pubspec.yaml'), $pubspec)
        flutter pub get
        dart run tool/configure_windows_secrets.dart

        # Generate the MWEB ABI from the same header that produced mweb.dll.
        Push-Location cw_mweb
        try {
            Resolve-CachedFlutterDependencies
            dart run ffigen --config ffigen_config.windows.yaml
            $env:MWEB_NATIVE_TEST_LIBRARY = Join-Path $root 'build/windows-native/mweb/mweb.dll'
            flutter test test/native/mweb_ffi_native_test.dart --reporter expanded
            Remove-Item Env:MWEB_NATIVE_TEST_LIBRARY
        } finally { Pop-Location }
    }

    if ($Stage -in @('All', 'Generate')) {
        $packages = @('cw_core', 'cw_monero', 'cw_bitcoin', 'cw_evm', 'cw_nano', 'cw_bitcoin_cash', 'cw_solana', 'cw_tron', 'cw_dogecoin')
        foreach ($package in $packages) {
            Push-Location $package
            try {
                Resolve-CachedFlutterDependencies
                dart run build_runner build --delete-conflicting-outputs
            } finally { Pop-Location }
        }
        Resolve-CachedFlutterDependencies
        dart run build_runner build --delete-conflicting-outputs
        dart run tool/generate_localization.dart

        # Run compilers synchronously, checking every exit status. The old shell
        # helper's bare `wait` can silently discard a failed background compiler.
        $graphicsRoot = (Resolve-Path res/pictures).Path
        $graphicDirs = @((Get-Item $graphicsRoot)) + @(Get-ChildItem $graphicsRoot -Directory -Recurse)
        foreach ($directory in $graphicDirs) {
            if (@(Get-ChildItem $directory.FullName -File -Filter '*.svg').Count -eq 0) { continue }
            $relative = [IO.Path]::GetRelativePath($graphicsRoot, $directory.FullName)
            $destination = Join-Path (Join-Path $root 'assets/new-ui') $relative
            New-Item -ItemType Directory -Force $destination | Out-Null
            dart run vector_graphics_compiler --input-dir $directory.FullName --out-dir $destination
        }
        flutter test test/tool/windows_secrets_test.dart `
            test/reactions/on_current_node_change_test.dart `
            test/reactions/check_connection_test.dart `
            test/core/monero_node_probe_test.dart --reporter expanded
    }

    if ($Stage -in @('All', 'Build')) {
        # Source preparation may run in parallel with the native build in CI.
        # Never compile/package until its exact pin and every DLL hash match.
        python scripts/windows/prepare_dependencies.py --verify-monero
        if ($LASTEXITCODE) { throw 'Native Monero artifact verification failed.' }
        # The Windows PackageInfo implementation reads Dart defines, independent
        # of the executable version resource written by --build-name/--build-number.
        # Keep both sources consistent and give the fork its own application ID.
        $buildEnvironment = Get-Content env.json -Raw | ConvertFrom-Json -AsHashtable
        $buildEnvironment['CW_WIN_APP_NAME'] = 'Cake Wallet Windows'
        $buildEnvironment['CW_WIN_APP_PACKAGE_NAME'] = 'vitorhubdev.cake_wallet_win'
        $buildEnvironment['CW_WIN_APP_VERSION'] = $Version
        $buildEnvironment['CW_WIN_APP_BUILD_NUMBER'] = [string]$BuildNumber
        New-Item -ItemType Directory -Force build | Out-Null
        $buildEnvironment | ConvertTo-Json | Set-Content build/windows-build-env.json -Encoding utf8
        flutter build windows --release --build-name $Version --build-number $BuildNumber --dart-define-from-file=build/windows-build-env.json
        if ($LASTEXITCODE) { throw 'Flutter Windows build failed.' }

        $release = Join-Path $root 'build/windows/x64/runner/Release'
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vs) { throw 'Visual Studio C++ tools were not found.' }
        $redist = Get-VisualCppRuntimeDirectory -RedistRoot (Join-Path $vs 'VC/Redist/MSVC')
        Copy-Item (Join-Path $redist '*.dll') $release -Force
        Copy-Item LICENSE.md $release
        Copy-Item build/windows-native/dependency-manifest.json $release
        Copy-Item pubspec.lock (Join-Path $release 'build-pubspec.lock')
        $buildInfo = @{
            repository = 'vitorhubdev/cake_wallet_win'
            commit = (& git rev-parse HEAD)
            version = "$Version+$BuildNumber"
            flutter = (& flutter --version --machine | ConvertFrom-Json)
            configuration = 'Windows x64 community build; no Cake production API keys'
        }
        $buildInfo | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $release 'build-info.json') -Encoding utf8
    }

} finally {
    Pop-Location
}
