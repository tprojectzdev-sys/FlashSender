# Regenerates iPhone AppIcon sizes from Assets source or Icon-1024.png
param(
    [string]$Source = "$PSScriptRoot\..\FileDrop\Assets.xcassets\AppIcon.appiconset\Icon-1024.png",
    [string]$Dest = "$PSScriptRoot\..\FileDrop\Assets.xcassets\AppIcon.appiconset"
)

Add-Type -AssemblyName System.Drawing
$master = [System.Drawing.Image]::FromFile((Resolve-Path $Source))
$sizes = @{
    "Icon-40.png" = 40
    "Icon-60.png" = 60
    "Icon-58.png" = 58
    "Icon-87.png" = 87
    "Icon-80.png" = 80
    "Icon-120.png" = 120
    "Icon-120-60.png" = 120
    "Icon-180.png" = 180
    "Icon-1024.png" = 1024
}
foreach ($entry in $sizes.GetEnumerator()) {
    $bmp = New-Object System.Drawing.Bitmap $entry.Value, $entry.Value
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($master, 0, 0, $entry.Value, $entry.Value)
    $g.Dispose()
    $bmp.Save((Join-Path $Dest $entry.Key), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
$master.Dispose()
Write-Host "Icons updated in $Dest"
