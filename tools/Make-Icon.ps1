<#
.SYNOPSIS
    Draws the filament-spool icon and writes assets\icon.ico (16-256 px) plus assets\icon.png.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
New-Item -ItemType Directory -Force -Path $assets | Out-Null

function New-Color([string]$Hex) { [Drawing.ColorTranslator]::FromHtml($Hex) }

# Drawn on a 256 x 256 canvas and scaled for each size.
function New-SpoolBitmap([int]$Size) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.ScaleTransform($Size / 256, $Size / 256)

    $flange   = New-Color '#2F343B'
    $rim      = New-Color '#4A515B'
    $fil      = New-Color '#3CC491'
    $filDark  = New-Color '#27946B'
    $hub      = New-Color '#D5DAE1'
    $hubShade = New-Color '#AEB5BF'

    function Circle($Brush, [float]$Cx, [float]$Cy, [float]$R) { $g.FillEllipse($Brush, $Cx - $R, $Cy - $R, 2 * $R, 2 * $R) }

    $cx = 118; $cy = 118

    # Flange with a lighter rim edge
    Circle (New-Object Drawing.SolidBrush $rim) $cx $cy 112
    Circle (New-Object Drawing.SolidBrush $flange) $cx $cy 104

    # Wound filament with winding rings (skipped when too small to see)
    Circle (New-Object Drawing.SolidBrush $fil) $cx $cy 88
    if ($Size -ge 48) {
        $ringPen = New-Object Drawing.Pen $filDark, 3
        foreach ($r in 78, 68, 58) { $g.DrawEllipse($ringPen, $cx - $r, $cy - $r, 2 * $r, 2 * $r) }
    }

    # Hub and bore
    Circle (New-Object Drawing.SolidBrush $hub) $cx $cy 44
    if ($Size -ge 32) { Circle (New-Object Drawing.SolidBrush $hubShade) $cx $cy 30 }
    Circle (New-Object Drawing.SolidBrush $flange) $cx $cy 17

    # Loose strand leaving the spool toward the bottom right
    $strand = New-Object Drawing.Pen $fil, $(if ($Size -ge 48) { 12 } else { 18 })
    $strand.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $strand.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $g.DrawBezier($strand, 196, 150, 226, 190, 206, 222, 244, 244)

    $g.Dispose()
    return $bmp
}

$sizes = 256, 64, 48, 32, 24, 16
$images = foreach ($s in $sizes) {
    $bmp = New-SpoolBitmap $s
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    if ($s -eq 256) { $bmp.Save((Join-Path $assets 'icon.png'), [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    , $ms.ToArray()
}

# ICO container holding PNG-compressed images (supported since Windows Vista).
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $assets 'icon.ico'), $out.ToArray())
Write-Host "Wrote $(Join-Path $assets 'icon.ico')"
