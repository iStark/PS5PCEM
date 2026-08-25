[CmdletBinding()]
param(
    [string] $Version = "",
    [switch] $Draft,
    [switch] $AllowUnsigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot "VERSION") -Raw).Trim()
}
$tag = "v$Version"
$distRoot = Join-Path $repoRoot "dist"
$portable = Join-Path $distRoot "PS5PCEM-$Version-windows-x64-portable.zip"
$installer = Join-Path $distRoot "PS5PCEM-$Version-windows-x64-setup.exe"
$checksums = Join-Path $distRoot "SHA256SUMS.txt"
$notes = Join-Path $repoRoot "docs\release-notes\$tag.md"

foreach ($path in @($portable, $installer, $checksums, $notes)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release input is missing: $path"
    }
}

$stageRoot = Join-Path $distRoot "PS5PCEM-$Version-windows-x64-portable"
if (-not $AllowUnsigned) {
    foreach ($path in @(
        (Join-Path $stageRoot "ps5pcem.exe"),
        (Join-Path $stageRoot "game-run.exe"),
        $installer
    )) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne "Valid") {
            throw "Refusing to publish an unsigned artifact: $path"
        }
    }
}

Push-Location $repoRoot
try {
    & gh auth status
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run: gh auth login"
    }
    if ((git status --porcelain).Length -ne 0) {
        throw "The working tree must be clean before publishing."
    }
    if ((git branch --show-current).Trim() -ne "main") {
        throw "Publish the first release from main."
    }
    git rev-parse --verify --quiet "refs/tags/$tag" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git tag -a $tag -m "PS5PCEM $Version"
        if ($LASTEXITCODE -ne 0) { throw "Could not create tag $tag" }
    }
    git push origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not push main" }
    git push origin $tag
    if ($LASTEXITCODE -ne 0) { throw "Could not push $tag" }

    $arguments = @(
        "release", "create", $tag,
        $portable, $installer, $checksums,
        "--verify-tag",
        "--title", "PS5PCEM $Version",
        "--notes-file", $notes,
        "--prerelease"
    )
    if ($Draft) { $arguments += "--draft" }
    & gh @arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub release creation failed" }
} finally {
    Pop-Location
}
