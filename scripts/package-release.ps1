[CmdletBinding()]
param(
    [string] $Version = "",
    [ValidateSet("ReleaseSafe", "ReleaseFast")]
    [string] $Optimize = "ReleaseFast",
    [switch] $SkipBuild,
    [string] $BinaryDir = "",
    [string] $CertificateThumbprint = "",
    [string] $TimestampServer = "http://timestamp.digicert.com",
    [string] $InnoCompiler = "",
    [switch] $AllowUnsigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot "VERSION") -Raw).Trim()
}
if ($Version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Version"
}
$versionMajor = $Matches.major
$versionMinor = $Matches.minor
$versionPatch = $Matches.patch
$versionRevision = 0
$prereleaseSeparator = $Version.IndexOf('-')
if ($prereleaseSeparator -ge 0) {
    $prerelease = $Version.Substring($prereleaseSeparator + 1)
    if ($prerelease -match '(?:^|\.)(?<revision>\d+)$') {
        $versionRevision = [int] $Matches.revision
    }
}
$numericVersion = "{0}.{1}.{2}.{3}" -f $versionMajor, $versionMinor, $versionPatch, $versionRevision
$distRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "dist"))
$binaryRoot = if ([string]::IsNullOrWhiteSpace($BinaryDir)) {
    [IO.Path]::GetFullPath((Join-Path $repoRoot "zig-out\bin"))
} elseif ([IO.Path]::IsPathRooted($BinaryDir)) {
    [IO.Path]::GetFullPath($BinaryDir)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $BinaryDir))
}
$stageName = "PS5PCEM-$Version-windows-x64-portable"
$stageRoot = [IO.Path]::GetFullPath((Join-Path $distRoot $stageName))

function Assert-ChildPath([string] $Parent, [string] $Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside $parentFull`: $childFull"
    }
}

function Invoke-Checked([scriptblock] $Command, [string] $Description) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Find-InnoCompiler {
    if (-not [string]::IsNullOrWhiteSpace($InnoCompiler)) {
        if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
            throw "Inno Setup compiler not found: $InnoCompiler"
        }
        return [IO.Path]::GetFullPath($InnoCompiler)
    }
    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    $candidates = @(
        $(if ($command) { $command.Source }),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "Inno Setup 6 was not found. Install JRSoftware.InnoSetup or pass -InnoCompiler."
}

$certificate = $null
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $normalizedThumbprint = $CertificateThumbprint.Replace(" ", "")
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$normalizedThumbprint" -ErrorAction Stop
    if (-not $certificate.HasPrivateKey) {
        throw "The selected code-signing certificate has no private key."
    }
} elseif (-not $AllowUnsigned) {
    throw "No Authenticode certificate was supplied. Pass -CertificateThumbprint or use -AllowUnsigned only for a local test package."
}

function Sign-ReleaseFile([string] $Path) {
    if (-not $certificate) {
        Write-Warning "Unsigned test artifact: $Path"
        return
    }
    $signature = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer -IncludeChain All
    if ($signature.Status -ne "Valid") {
        throw "Authenticode signing failed for $Path`: $($signature.StatusMessage)"
    }
}

Push-Location $repoRoot
try {
    if (-not $SkipBuild) {
        Invoke-Checked { zig build build-game-run "-Doptimize=$Optimize" } "game-run build"
        Invoke-Checked { zig build build-launcher "-Doptimize=$Optimize" } "launcher build"
    }

    New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
    Assert-ChildPath $distRoot $stageRoot
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageRoot | Out-Null

    $releaseFiles = @(
        @{ Source = (Join-Path $binaryRoot "ps5pcem.exe"); Destination = "ps5pcem.exe" },
        @{ Source = (Join-Path $binaryRoot "game-run.exe"); Destination = "game-run.exe" },
        @{ Source = "README.md"; Destination = "README.md" },
        @{ Source = "LICENSE"; Destination = "LICENSE" },
        @{ Source = "VERSION"; Destination = "VERSION" },
        @{ Source = "assets\branding\ps5pcem-icon-256.png"; Destination = "ps5pcem-icon.png" }
    )
    foreach ($entry in $releaseFiles) {
        $source = if ([IO.Path]::IsPathRooted($entry.Source)) { $entry.Source } else { Join-Path $repoRoot $entry.Source }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required release file is missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stageRoot $entry.Destination)
    }

    $stageDocs = Join-Path $stageRoot "docs"
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs") -Destination $stageDocs -Recurse
    $stageBranding = Join-Path $stageRoot "assets\branding"
    New-Item -ItemType Directory -Path $stageBranding -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\branding\ps5pcem-icon-256.png") -Destination $stageBranding

    $portableReadme = @"
PS5PCEM $Version - Windows x64 prototype

1. Install a current Vulkan 1.2-capable graphics driver.
2. Run ps5pcem.exe.
3. Choose a directory containing a decrypted game you are legally allowed to use.

Keep ps5pcem.exe and game-run.exe together. The portable build stores ps5pcem.ini,
savedata, logs and caches beside the application. Games, firmware and system files
are not included. This prototype is incomplete and many titles will not work yet.
"@
    Set-Content -LiteralPath (Join-Path $stageRoot "README-PORTABLE.txt") -Value $portableReadme -Encoding utf8NoBOM

    Sign-ReleaseFile (Join-Path $stageRoot "ps5pcem.exe")
    Sign-ReleaseFile (Join-Path $stageRoot "game-run.exe")

    $portableZip = Join-Path $distRoot "$stageName.zip"
    Assert-ChildPath $distRoot $portableZip
    if (Test-Path -LiteralPath $portableZip) {
        Remove-Item -LiteralPath $portableZip -Force
    }
    Compress-Archive -LiteralPath $stageRoot -DestinationPath $portableZip -CompressionLevel Optimal

    $compiler = Find-InnoCompiler
    $installerScript = Join-Path $repoRoot "packaging\installer\ps5pcem.iss"
    Invoke-Checked {
        & $compiler "/DMyAppVersion=$Version" "/DMyNumericVersion=$numericVersion" "/DSourceDir=$stageRoot" "/DOutputDir=$distRoot" $installerScript
    } "installer build"

    $installer = Join-Path $distRoot "PS5PCEM-$Version-windows-x64-setup.exe"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Installer output was not created: $installer"
    }
    Sign-ReleaseFile $installer

    $checksums = Join-Path $distRoot "SHA256SUMS.txt"
    $hashLines = foreach ($artifact in @($portableZip, $installer)) {
        $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
        "{0} *{1}" -f $hash.Hash.ToLowerInvariant(), (Split-Path $artifact -Leaf)
    }
    Set-Content -LiteralPath $checksums -Value $hashLines -Encoding ascii

    [pscustomobject]@{
        Version = $Version
        Portable = $portableZip
        Installer = $installer
        Checksums = $checksums
        Signed = [bool]$certificate
    } | Format-List
} finally {
    Pop-Location
}
