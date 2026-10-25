# make-icon.ps1
#
# Generates the 1024x1024 AppIcon.png for the Ferry iOS app.
#
# Run on Windows PowerShell (uses System.Drawing):
#   powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
#
# Input : C:\temp\ferry-icons\plane3-R3-256.png  (source glyph, any size)
# Output: Ferry\Assets.xcassets\AppIcon.appiconset\AppIcon.png
#         (1024x1024, opaque, glyph centered at ~70% on #0F172A)
#
# No other side effects: it only creates the output directory if needed and
# writes the single PNG.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$sourcePath = 'C:\temp\ferry-icons\plane3-R3-256.png'
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Source icon not found: $sourcePath"
}

# Resolve the repo root from this script's location so the output path is
# correct regardless of the caller's working directory.
# tools\make-icon.ps1 -> tools\ -> repo root (ios-repo).
$repoRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $repoRoot 'Ferry\Ferry\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$size          = 1024
$glyphFraction = 0.70   # glyph occupies ~70% of the canvas

# Opaque dark background #0F172A.
$background = [System.Drawing.Color]::FromArgb(255, 0x0F, 0x17, 0x2A)

$bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.Clear($background)
    $graphics.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

    $source = [System.Drawing.Image]::FromFile($sourcePath)
    try {
        $glyphSize = [int][Math]::Round($size * $glyphFraction)
        $x = [int][Math]::Round(($size - $glyphSize) / 2.0)
        $y = $x

        $destRect = New-Object System.Drawing.Rectangle($x, $y, $glyphSize, $glyphSize)
        $graphics.DrawImage($source, $destRect, 0, 0, $source.Width, $source.Height, [System.Drawing.GraphicsUnit]::Pixel)
    }
    finally {
        $source.Dispose()
    }

    $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

Write-Output "Wrote $outputPath"
