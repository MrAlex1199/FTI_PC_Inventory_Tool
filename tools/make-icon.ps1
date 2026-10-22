Add-Type -AssemblyName System.Drawing

$outputPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\fti_inventory.ico'))
$assetsDir = Split-Path $outputPath
if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null }

$size = 128
$bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# Background rounded rect (Win11 Squircle)
$bgRect = New-Object System.Drawing.RectangleF 4, 4, ($size - 8), ($size - 8)
$radius = 26
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc($bgRect.X, $bgRect.Y, $radius, $radius, 180, 90)
$path.AddArc($bgRect.Right - $radius, $bgRect.Y, $radius, $radius, 270, 90)
$path.AddArc($bgRect.Right - $radius, $bgRect.Bottom - $radius, $radius, $radius, 0, 90)
$path.AddArc($bgRect.X, $bgRect.Bottom - $radius, $radius, $radius, 90, 90)
$path.CloseFigure()

$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $bgRect,
    [System.Drawing.Color]::FromArgb(255, 0, 103, 192),  # Accent Blue
    [System.Drawing.Color]::FromArgb(255, 15, 23, 42),   # Deep Slate
    [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
)
$g.FillPath($brush, $path)

# Monitor
$penWhite = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
$penWhite.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$penWhite.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

$screenRect = New-Object System.Drawing.RectangleF 22, 20, 84, 56
$screenFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 245, 255))
$g.FillRectangle($screenFill, $screenRect)
$g.DrawRectangle($penWhite, 22, 20, 84, 56)

# Stand
$g.DrawLine($penWhite, 64, 76, 64, 92)
$g.DrawLine($penWhite, 48, 92, 80, 92)

# Bars (Inventory list motif)
$b1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 103, 192))
$b2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 148, 163, 184))
$g.FillRectangle($b1, 30, 30, 40, 5)
$g.FillRectangle($b2, 30, 40, 60, 4)
$g.FillRectangle($b2, 30, 48, 50, 4)
$g.FillRectangle($b2, 30, 56, 68, 4)

# Badge (Success green check)
$badgeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 16, 185, 129))
$badgePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
$g.FillEllipse($badgeBrush, 72, 68, 44, 44)
$g.DrawEllipse($badgePen, 72, 68, 44, 44)

# Checkmark
$chkPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4)
$chkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$chkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$p1 = New-Object System.Drawing.PointF 82, 90
$p2 = New-Object System.Drawing.PointF 90, 98
$p3 = New-Object System.Drawing.PointF 104, 80
$g.DrawLines($chkPen, @($p1, $p2, $p3))
$g.Dispose()

$hIcon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)

$ms = New-Object System.IO.MemoryStream
$icon.Save($ms)
$bytes = $ms.ToArray()
$ms.Dispose()

[System.IO.File]::WriteAllBytes($outputPath, $bytes)
$bmp.Dispose()
$icon.Dispose()

Write-Host "Icon created successfully: $outputPath ($($bytes.Length) bytes)"
