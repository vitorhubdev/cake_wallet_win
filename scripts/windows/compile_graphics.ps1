[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
# CakeImageWidget requests <asset>.svg.vec for both the new UI and the older
# assets, including the welcome logos and changelog icons.
$trees = @(
    @{ Source = 'res/pictures'; Destination = 'assets/new-ui' },
    @{ Source = 'assets'; Destination = 'assets' }
)

Push-Location $root
try {
    foreach ($tree in $trees) {
        $source = (Resolve-Path -LiteralPath (Join-Path $root $tree.Source)).Path
        $destination = Join-Path $root $tree.Destination
        $images = @(Get-ChildItem -LiteralPath $source -Filter '*.svg' -File -Recurse)
        if ($images.Count -eq 0) { continue }
        $staging = Join-Path ([IO.Path]::GetTempPath()) ('cake-vector-assets-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging | Out-Null
        try {
            foreach ($image in $images) {
                $relative = [IO.Path]::GetRelativePath($source, $image.FullName)
                $inputPath = Join-Path $staging $relative
                New-Item -ItemType Directory -Path (Split-Path $inputPath -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $image.FullName -Destination $inputPath
            }

            # This pinned compiler recurses into --input-dir. Supplying --out-dir
            # flattens descendants and overwrites equal basenames. Compile beside
            # the staged inputs, then copy only the expected relative paths.
            dart run vector_graphics_compiler --input-dir $staging
            if ($LASTEXITCODE -ne 0) { throw "Vector compilation failed for $($tree.Source)." }

            foreach ($image in $images) {
                $relative = [IO.Path]::GetRelativePath($source, $image.FullName) + '.vec'
                $compiled = Join-Path $staging $relative
                if (-not (Test-Path -LiteralPath $compiled -PathType Leaf) -or
                    (Get-Item -LiteralPath $compiled).Length -eq 0) {
                    throw "Vector compiler did not produce a nonempty asset: $relative"
                }
                $outputPath = Join-Path $destination $relative
                New-Item -ItemType Directory -Path (Split-Path $outputPath -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $compiled -Destination $outputPath -Force
            }
            Write-Output "Compiled $($images.Count) vector assets: $($tree.Source) -> $($tree.Destination)"
        } finally {
            # Remove only this invocation's unique temporary input/output tree.
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
} finally {
    Pop-Location
}
