[CmdletBinding()]
param(
    [string]$Version = '6.5.0',
    [ValidateRange(1, 65535)]
    [int]$BuildNumber = 1,
    [string]$BundlePath = 'build\windows\x64\runner\Release',
    [string]$OutputPath = 'dist'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Packaging requires PowerShell 7 on Windows x64.'
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid installer version.' }
$versionParts = $Version.Split('.') | ForEach-Object { [int]$_ }
if (@($versionParts | Where-Object { $_ -gt 65535 }).Count -ne 0) {
    throw 'Windows version components must not exceed 65535.'
}

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not [IO.Path]::IsPathRooted($BundlePath)) { $BundlePath = Join-Path $root $BundlePath }
if (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $root $OutputPath }
$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$output = [IO.Path]::GetFullPath($OutputPath)
if ($output.Equals($bundle, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($bundle.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer output must be outside the application bundle.'
}

$requiredFiles = @(
    'CakeWallet.exe', 'flutter_windows.dll',
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'libmonero_wallet2_api_c.dll',
    'libwinpthread-1.dll', 'mweb.dll',
    'data\icudtl.dat', 'data\app.so', 'data\flutter_assets\AssetManifest.bin',
    'LICENSE.md', 'build-info.json', 'build-pubspec.lock', 'dependency-manifest.json'
)
foreach ($relative in $requiredFiles) {
    $file = Join-Path $bundle $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        throw "Cannot package an incomplete bundle: $relative"
    }
}
$buildInfo = Get-Content -LiteralPath (Join-Path $bundle 'build-info.json') -Raw | ConvertFrom-Json
if ($buildInfo.version -ne "$Version+$BuildNumber") {
    throw "Installer version $Version+$BuildNumber does not match the compiled bundle."
}
Copy-Item -LiteralPath (Join-Path $root 'docs/builds/WINDOWS_FORK.md') `
    -Destination (Join-Path $bundle 'README-WINDOWS.md') -Force

$compiler = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) {
    $command = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'Inno Setup 6 is required to create the Windows installer.' }
    $compiler = $command.Source
}
Write-Output "Using Inno Setup $((Get-Item -LiteralPath $compiler).VersionInfo.FileVersion)"
New-Item -ItemType Directory -Path $output -Force | Out-Null
$installer = Join-Path $output "CakeWallet-Windows-x64-$Version-$BuildNumber-Setup.exe"
if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }

& $compiler '/Qp' "/DMyAppVersion=$Version" "/DMyBuildNumber=$BuildNumber" `
    "/DBundlePath=$bundle" "/DOutputPath=$output" (Join-Path $PSScriptRoot 'build_exe_installer.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or (Get-Item -LiteralPath $installer).Length -eq 0) {
    throw 'Inno Setup did not produce the expected installer.'
}
Write-Output "Created $installer"
