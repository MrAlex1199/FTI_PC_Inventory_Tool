# ==============================================================================
# FTI PC Inventory Tool - GUI (Ultra-Premium Windows 11 Fluent Light Design)
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# Helper function for safe Unicode / Thai strings without codepage corruption
function T([string]$b64) {
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
}

function New-RoundedPath([System.Drawing.Rectangle]$rect, [int]$radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [math]::Max(2, $radius * 2)
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
    $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# --- Fonts ---
$fontFamily = 'Segoe UI'
try { $testFont = New-Object System.Drawing.Font('Segoe UI', 9) } catch { $fontFamily = 'Leelawadee UI' }

$fontTitle      = New-Object System.Drawing.Font($fontFamily, 13,   [System.Drawing.FontStyle]::Bold)
$fontSubtitle   = New-Object System.Drawing.Font($fontFamily, 8.5,  [System.Drawing.FontStyle]::Regular)
$fontCardHeader = New-Object System.Drawing.Font($fontFamily, 10.5, [System.Drawing.FontStyle]::Bold)
$fontRegular    = New-Object System.Drawing.Font($fontFamily, 9,    [System.Drawing.FontStyle]::Regular)
$fontBold       = New-Object System.Drawing.Font($fontFamily, 9,    [System.Drawing.FontStyle]::Bold)
$fontMuted      = New-Object System.Drawing.Font($fontFamily, 8.5,  [System.Drawing.FontStyle]::Regular)
$fontStatNum    = New-Object System.Drawing.Font($fontFamily, 16,   [System.Drawing.FontStyle]::Bold)
$fontStatLbl    = New-Object System.Drawing.Font($fontFamily, 8,    [System.Drawing.FontStyle]::Regular)
$fontLog        = New-Object System.Drawing.Font('Consolas', 9,     [System.Drawing.FontStyle]::Regular)

# --- Colors ---
$colorBg        = [System.Drawing.Color]::FromArgb(245, 247, 251)
$colorText      = [System.Drawing.Color]::FromArgb(15, 23, 42)
$colorMuted     = [System.Drawing.Color]::FromArgb(100, 116, 139)
$colorAccent    = [System.Drawing.Color]::FromArgb(0, 103, 192)
$colorSuccess   = [System.Drawing.Color]::FromArgb(16, 185, 129)
$colorWarning   = [System.Drawing.Color]::FromArgb(245, 158, 11)
$colorDanger    = [System.Drawing.Color]::FromArgb(220, 38, 38)
$colorTerminal  = [System.Drawing.Color]::FromArgb(11, 18, 32)
$colorBorderVal = [System.Drawing.Color]::FromArgb(226, 232, 240)
$colorWhite     = [System.Drawing.Color]::White
$colorInfo      = [System.Drawing.Color]::FromArgb(56, 189, 248)

# --- Pre-allocated GDI+ Brushes & Pens ---
$brWhite        = [System.Drawing.Brushes]::White
$brShadowCard   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(14, 0, 0, 0))
$brShadowStat   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(10, 0, 0, 0))
$brSubPanel     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(248, 250, 252))
$brProgTrack    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(226, 232, 240))
$brFolderBg     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(254, 243, 199))
$brFolderTab    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(251, 191, 36))
$brGreenBadge   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(16, 185, 129))
$brText         = New-Object System.Drawing.SolidBrush $colorText

$penBorder      = New-Object System.Drawing.Pen $colorBorderVal, 1
$penWhite2      = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
$penWhite3      = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 3
$penAdminPill   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(167, 243, 208)), 1
$penTermBorder  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(30, 41, 59)), 1
$penFolder      = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(217, 119, 6)), 1.5

# --- Resolve Core Script ---
if (-not $CoreScript) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $corePath = Join-Path $scriptDir 'src\Get-PCInventory.Core.ps1'
    if (-not (Test-Path $corePath)) {
        $corePath = Join-Path $scriptDir 'Get-PCInventory.Core.ps1'
    }
    if (Test-Path $corePath) {
        $CoreScript = [System.IO.File]::ReadAllText($corePath, [System.Text.Encoding]::UTF8)
    } else {
        $CoreScript = ''
    }
}

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'FTI PC Inventory Tool'
$form.Size = New-Object System.Drawing.Size(1200, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 760)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $colorBg
$form.ForeColor = $colorText
$form.Font = $fontRegular

# Check Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ==============================================================================
# 1. HEADER (Gradient Blue Banner)
# ==============================================================================
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 72
$headerPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $rect = New-Object System.Drawing.Rectangle 0, 0, $s.Width, $s.Height
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(0, 85, 160),
        [System.Drawing.Color]::FromArgb(0, 115, 210),
        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
    )
    $g.FillRectangle($br, $rect)

    # Monitor Icon (Vector in white)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.DrawRectangle($penWhite2, 24, 18, 28, 20)
    $g.FillRectangle($brWhite, 28, 22, 10, 3)
    $g.FillRectangle($brWhite, 28, 28, 20, 2)
    $g.FillRectangle($brWhite, 28, 32, 16, 2)
    $g.DrawLine($penWhite2, 38, 38, 38, 46)
    $g.DrawLine($penWhite2, 32, 46, 44, 46)
    
    # Audit badge (green check)
    $g.FillEllipse($brGreenBadge, 42, 32, 16, 16)
    $g.DrawEllipse($penWhite2, 42, 32, 16, 16)
    $g.DrawLines($penWhite2, @((New-Object System.Drawing.Point 45, 40), (New-Object System.Drawing.Point 48, 44), (New-Object System.Drawing.Point 54, 37)))
})
$form.Controls.Add($headerPanel)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'FTI PC Inventory Tool'
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(68, 14)
$lblTitle.AutoSize = $true
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = T '4Liq4LmB4LiB4LiZ4LiC4LmJ4Lit4Lih4Li54LilIEhhcmR3YXJlIOC5geC4peC4sCBJbnN0YWxsZWQgU29mdHdhcmUg4LiC4Lit4LiH4LmA4LiE4Lij4Li34LmI4Lit4LiH4LmD4LiZ4LmC4LiU4LmA4Lih4LiZICh+MjAwIOC5gOC4hOC4o+C4t+C5iOC4reC4hykg4Lit4Lit4LiB4LmA4Lib4LmH4LiZ4LmE4Lif4Lil4LmMIENTViAvIEhUTUw='
$lblSubtitle.Font = $fontSubtitle
$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(224, 242, 254)
$lblSubtitle.Location = New-Object System.Drawing.Point(70, 40)
$lblSubtitle.AutoSize = $true
$lblSubtitle.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($lblSubtitle)

# Admin Status Pill
$badgeAdmin = New-Object System.Windows.Forms.Label
$badgeAdmin.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$badgeAdmin.Location = New-Object System.Drawing.Point(940, 20)
$badgeAdmin.Size = New-Object System.Drawing.Size(220, 32)
$badgeAdmin.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$badgeAdmin.Font = $fontBold
if ($isAdmin) {
    $badgeAdmin.Text = T '4pyTIEFkbWluaXN0cmF0b3IgLyBEb21haW4gQWRtaW4='
    $badgeAdmin.BackColor = [System.Drawing.Color]::FromArgb(236, 253, 245)
    $badgeAdmin.ForeColor = [System.Drawing.Color]::FromArgb(5, 150, 105)
} else {
    $badgeAdmin.Text = T '4pqgIOC5hOC4oeC5iOC5g+C4iuC5iCBBZG1pbiAo4Lit4Liy4LiI4Liq4LmB4LiB4LiZ4LmE4Lih4LmI4LmE4LiU4LmJKQ=='
    $badgeAdmin.BackColor = [System.Drawing.Color]::FromArgb(254, 242, 242)
    $badgeAdmin.ForeColor = $colorDanger
}
$badgeAdmin.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $p = New-RoundedPath (New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)) 14
    $g.DrawPath($penAdminPill, $p)
})
$headerPanel.Controls.Add($badgeAdmin)

# Helper to create Card Panel
function New-StyledCard([int]$x, [int]$y, [int]$w, [int]$h, [string]$title) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($x, $y)
    $card.Size = New-Object System.Drawing.Size($w, $h)
    $card.BackColor = [System.Drawing.Color]::Transparent

    $card.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        # Soft shadow
        $sRect = New-Object System.Drawing.Rectangle 2, 3, ($s.Width - 5), ($s.Height - 5)
        $g.FillPath($brShadowCard, (New-RoundedPath $sRect 10))

        # Main white card
        $mRect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 4), ($s.Height - 4)
        $mPath = New-RoundedPath $mRect 10
        $g.FillPath($brWhite, $mPath)
        $g.DrawPath($penBorder, $mPath)
    })

    if ($title) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $title
        $lbl.Font = $fontCardHeader
        $lbl.ForeColor = $colorText
        $lbl.Location = New-Object System.Drawing.Point(18, 14)
        $lbl.AutoSize = $true
        $lbl.BackColor = [System.Drawing.Color]::White
        $lbl.UseMnemonic = $false
        $card.Controls.Add($lbl)
    }

    return $card
}

# ==============================================================================
# 2. LEFT SETTINGS COLUMN
# ==============================================================================
$leftContainer = New-Object System.Windows.Forms.Panel
$leftContainer.Location = New-Object System.Drawing.Point(20, 86)
$leftContainer.Size = New-Object System.Drawing.Size(480, 644)
$leftContainer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($leftContainer)

# --- CARD 1: แหล่งรายชื่อเครื่อง ---
$card1 = New-StyledCard 0 0 480 172 (T 'MS4g4LmB4Lir4Lil4LmI4LiH4Lij4Liy4Lii4LiK4Li34LmI4Lit4LmA4LiE4Lij4Li34LmI4Lit4LiH4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4Liq4LmB4LiB4LiZ')
$leftContainer.Controls.Add($card1)

$rbAD = New-Object System.Windows.Forms.RadioButton
$rbAD.Text = '  ' + (T '4LiU4Li24LiH4Lit4Lix4LiV4LmC4LiZ4Lih4Lix4LiV4Li04LiI4Liy4LiBIEFjdGl2ZSBEaXJlY3RvcnkgKEFEKQ==')
$rbAD.Font = $fontBold
$rbAD.Location = New-Object System.Drawing.Point(20, 44)
$rbAD.AutoSize = $true
$rbAD.Checked = $true
$rbAD.BackColor = [System.Drawing.Color]::White
$card1.Controls.Add($rbAD)

$pnlAdDays = New-Object System.Windows.Forms.Panel
$pnlAdDays.Location = New-Object System.Drawing.Point(40, 70)
$pnlAdDays.Size = New-Object System.Drawing.Size(420, 26)
$pnlAdDays.BackColor = [System.Drawing.Color]::White
$card1.Controls.Add($pnlAdDays)

$lblAdSub = New-Object System.Windows.Forms.Label
$lblAdSub.Text = T '4LmA4LiJ4Lie4Liy4Liw4LmA4LiE4Lij4Li34LmI4Lit4LiH4LiX4Li14LmIIExvZ2luIOC5gOC4guC5ieC4suC4o+C4sOC4muC4muC4oOC4suC4ouC5g+C4mQ=='
$lblAdSub.Font = $fontRegular
$lblAdSub.Location = New-Object System.Drawing.Point(0, 3)
$lblAdSub.AutoSize = $true
$pnlAdDays.Controls.Add($lblAdSub)

$numDays = New-Object System.Windows.Forms.NumericUpDown
$numDays.Location = New-Object System.Drawing.Point(215, 0)
$numDays.Size = New-Object System.Drawing.Size(52, 24)
$numDays.Minimum = 1
$numDays.Maximum = 365
$numDays.Value = 30
$pnlAdDays.Controls.Add($numDays)

$lblDaysUnit = New-Object System.Windows.Forms.Label
$lblDaysUnit.Text = T '4Lin4Lix4LiZ4Lil4LmI4Liy4Liq4Li44LiU'
$lblDaysUnit.Font = $fontRegular
$lblDaysUnit.Location = New-Object System.Drawing.Point(272, 3)
$lblDaysUnit.AutoSize = $true
$pnlAdDays.Controls.Add($lblDaysUnit)

$rbFile = New-Object System.Windows.Forms.RadioButton
$rbFile.Text = '  ' + (T '4Lij4Liw4Lia4Li44LmE4Lif4Lil4LmM4Lij4Liy4Lii4LiK4Li34LmI4LitICgudHh0IOC5gOC4hOC4o+C4t+C5iOC4reC4h+C4peC4sOC4muC4o+C4o+C4l+C4seC4lCDguYDguIrguYjguJkgcGNzLnR4dCk6')
$rbFile.Font = $fontBold
$rbFile.Location = New-Object System.Drawing.Point(20, 102)
$rbFile.AutoSize = $true
$rbFile.BackColor = [System.Drawing.Color]::White
$card1.Controls.Add($rbFile)

$txtListFile = New-Object System.Windows.Forms.TextBox
$txtListFile.Location = New-Object System.Drawing.Point(40, 128)
$txtListFile.Size = New-Object System.Drawing.Size(325, 24)
$txtListFile.Enabled = $false
$card1.Controls.Add($txtListFile)

$btnBrowseList = New-Object System.Windows.Forms.Button
$btnBrowseList.Text = T '4LmA4Lil4Li34Lit4LiB4LmE4Lif4Lil4LmMLi4u'
$btnBrowseList.Location = New-Object System.Drawing.Point(372, 127)
$btnBrowseList.Size = New-Object System.Drawing.Size(88, 26)
$btnBrowseList.Enabled = $false
$btnBrowseList.BackColor = $colorBg
$btnBrowseList.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnBrowseList.FlatAppearance.BorderColor = $colorBorderVal
$card1.Controls.Add($btnBrowseList)

$rbAD.Add_CheckedChanged({
    $pnlAdDays.Enabled = $rbAD.Checked
    $txtListFile.Enabled = $rbFile.Checked
    $btnBrowseList.Enabled = $rbFile.Checked
})

# --- CARD 2: สิ่งที่จะสแกน ---
$card2 = New-StyledCard 0 186 480 295 (T 'Mi4g4Liq4Li04LmI4LiH4LiX4Li14LmI4LiI4Liw4Liq4LmB4LiB4LiZIChIYXJkd2FyZSAmIFNvZnR3YXJlKQ==')
$leftContainer.Controls.Add($card2)

$chkHw = New-Object System.Windows.Forms.CheckBox
$chkHw.Text = '  ' + (T '4Liq4LmB4LiB4LiZ4LiC4LmJ4Lit4Lih4Li54LilIEhhcmR3YXJl')
$chkHw.Font = $fontBold
$chkHw.Location = New-Object System.Drawing.Point(20, 40)
$chkHw.AutoSize = $true
$chkHw.Checked = $true
$chkHw.BackColor = [System.Drawing.Color]::White
$chkHw.UseMnemonic = $false
$card2.Controls.Add($chkHw)

$lblHwDesc = New-Object System.Windows.Forms.Label
$lblHwDesc.Text = 'CIM/DCOM: CPU, Cores, RAM, Disk, GPU, Serial, OS, IP, MAC'
$lblHwDesc.Font = $fontMuted
$lblHwDesc.ForeColor = $colorMuted
$lblHwDesc.Location = New-Object System.Drawing.Point(38, 62)
$lblHwDesc.AutoSize = $true
$lblHwDesc.BackColor = [System.Drawing.Color]::White
$card2.Controls.Add($lblHwDesc)

$chkSw = New-Object System.Windows.Forms.CheckBox
$chkSw.Text = '  ' + (T '4Liq4LmB4LiB4LiZ4Lij4Liy4Lii4LiB4Liy4LijIFNvZnR3YXJlIOC4l+C4teC5iOC4leC4tOC4lOC4leC4seC5ieC4hw==')
$chkSw.Font = $fontBold
$chkSw.Location = New-Object System.Drawing.Point(20, 88)
$chkSw.AutoSize = $true
$chkSw.Checked = $true
$chkSw.BackColor = [System.Drawing.Color]::White
$chkSw.UseMnemonic = $false
$card2.Controls.Add($chkSw)

$lblSwDesc = New-Object System.Windows.Forms.Label
$lblSwDesc.Text = T 'V2luUk0g4LiC4LiZ4Liy4LiZ4LiE4Lin4Liy4Lih4LmA4Lij4LmH4Lin4Liq4Li54LiHICsgRENPTSBGYWxsYmFjayDguK3guLHguJXguYLguJnguKHguLHguJXguLQ='
$lblSwDesc.Font = $fontMuted
$lblSwDesc.ForeColor = $colorMuted
$lblSwDesc.Location = New-Object System.Drawing.Point(38, 110)
$lblSwDesc.AutoSize = $true
$lblSwDesc.BackColor = [System.Drawing.Color]::White
$card2.Controls.Add($lblSwDesc)

# Software Sub-Settings Box
$pnlSwSub = New-Object System.Windows.Forms.Panel
$pnlSwSub.Location = New-Object System.Drawing.Point(20, 134)
$pnlSwSub.Size = New-Object System.Drawing.Size(440, 145)
$pnlSwSub.BackColor = [System.Drawing.Color]::Transparent
$pnlSwSub.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
    $p = New-RoundedPath $rect 6
    $g.FillPath($brSubPanel, $p)
    $g.DrawPath($penBorder, $p)
})
$card2.Controls.Add($pnlSwSub)

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = T '4LiB4Lij4Lit4LiH4LiK4Li34LmI4Lit4LmC4Lib4Lij4LmB4LiB4Lij4LihICjguYPguKrguYggKiDguYTguJTguYkg4LmA4LiK4LmI4LiZICpPZmZpY2UqIOC4q+C4o+C4t+C4rSAqKTo='
$lblFilter.Font = $fontRegular
$lblFilter.Location = New-Object System.Drawing.Point(14, 10)
$lblFilter.AutoSize = $true
$pnlSwSub.Controls.Add($lblFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Text = '*'
$txtFilter.Location = New-Object System.Drawing.Point(14, 30)
$txtFilter.Size = New-Object System.Drawing.Size(412, 24)
$pnlSwSub.Controls.Add($txtFilter)

$chkUser = New-Object System.Windows.Forms.CheckBox
$chkUser.Text = '  ' + (T '4Lij4Lin4Lih4LmC4Lib4Lij4LmB4LiB4Lij4Lih4LiX4Li14LmI4Lil4LiH4LmA4LiJ4Lie4Liy4LiwIFVzZXIgKOC4quC5geC4geC4meC5guC4m+C4o+C5hOC4n+C4peC5jOC4l+C4teC5iCBMb2dpbiDguK3guKLguLnguYgp')
$chkUser.Font = $fontRegular
$chkUser.Location = New-Object System.Drawing.Point(14, 58)
$chkUser.AutoSize = $true
$pnlSwSub.Controls.Add($chkUser)

$chkHidden = New-Object System.Windows.Forms.CheckBox
$chkHidden.Text = '  ' + (T '4Lij4Lin4LihIFN5c3RlbSBjb21wb25lbnQg4LmB4Lil4LiwIFdpbmRvd3MgVXBkYXRl')
$chkHidden.Font = $fontRegular
$chkHidden.Location = New-Object System.Drawing.Point(14, 84)
$chkHidden.AutoSize = $true
$pnlSwSub.Controls.Add($chkHidden)

$lblThrottle = New-Object System.Windows.Forms.Label
$lblThrottle.Text = T 'VGhyb3R0bGUgKOC4iOC4s+C4meC4p+C4meC5gOC4hOC4o+C4t+C5iOC4reC4h+C4quC5geC4geC4mSBXaW5STSDguJ7guKPguYnguK3guKHguIHguLHguJkpOg=='
$lblThrottle.Font = $fontRegular
$lblThrottle.Location = New-Object System.Drawing.Point(14, 114)
$lblThrottle.AutoSize = $true
$pnlSwSub.Controls.Add($lblThrottle)

$numThrottle = New-Object System.Windows.Forms.NumericUpDown
$numThrottle.Location = New-Object System.Drawing.Point(366, 112)
$numThrottle.Size = New-Object System.Drawing.Size(60, 24)
$numThrottle.Minimum = 1
$numThrottle.Maximum = 100
$numThrottle.Value = 20
$pnlSwSub.Controls.Add($numThrottle)

$chkSw.Add_CheckedChanged({
    $pnlSwSub.Enabled = $chkSw.Checked
})

# --- CARD 3: ผลลัพธ์ ---
$card3 = New-StyledCard 0 495 480 148 (T 'My4g4LmC4Lif4Lil4LmA4LiU4Lit4Lij4LmM4Lic4Lil4Lil4Lix4Lie4LiY4LmMIChPdXRwdXQp')
$leftContainer.Controls.Add($card3)

$lblOutDir = New-Object System.Windows.Forms.Label
$lblOutDir.Text = T '4LmC4Lif4Lil4LmA4LiU4Lit4Lij4LmM4Liq4Liz4Lir4Lij4Lix4Lia4Lia4Lix4LiZ4LiX4Li24LiB4LmE4Lif4Lil4LmMIENTViDguYHguKXguLAgSFRNTDo='
$lblOutDir.Location = New-Object System.Drawing.Point(20, 40)
$lblOutDir.AutoSize = $true
$lblOutDir.BackColor = [System.Drawing.Color]::White
$card3.Controls.Add($lblOutDir)

$txtOutDir = New-Object System.Windows.Forms.TextBox
$txtOutDir.Text = 'C:\Inventory'
$txtOutDir.Location = New-Object System.Drawing.Point(20, 64)
$txtOutDir.Size = New-Object System.Drawing.Size(345, 24)
$card3.Controls.Add($txtOutDir)

$btnBrowseOut = New-Object System.Windows.Forms.Button
$btnBrowseOut.Text = T '4LmA4Lil4Li34Lit4LiB4LmC4Lif4Lil4LmA4LiU4Lit4Lij4LmMLi4u'
$btnBrowseOut.Location = New-Object System.Drawing.Point(372, 63)
$btnBrowseOut.Size = New-Object System.Drawing.Size(88, 26)
$btnBrowseOut.BackColor = $colorBg
$btnBrowseOut.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnBrowseOut.FlatAppearance.BorderColor = $colorBorderVal
$card3.Controls.Add($btnBrowseOut)

$chkAutoHtml = New-Object System.Windows.Forms.CheckBox
$chkAutoHtml.Text = '  ' + (T '4LmA4Lib4Li04LiU4LmE4Lif4Lil4LmMIEhUTUwgKFNvZnR3YXJlX0J5UEMpIOC4reC4seC4leC5guC4meC4oeC4seC4leC4tOC5gOC4oeC4t+C5iOC4reC5gOC4quC4o+C5h+C4iA==')
$chkAutoHtml.Location = New-Object System.Drawing.Point(20, 102)
$chkAutoHtml.AutoSize = $true
$chkAutoHtml.Checked = $true
$chkAutoHtml.BackColor = [System.Drawing.Color]::White
$card3.Controls.Add($chkAutoHtml)

# ==============================================================================
# 3. RIGHT COLUMN: STAT CARDS + TERMINAL LOG
# ==============================================================================
$rightContainer = New-Object System.Windows.Forms.Panel
$rightContainer.Location = New-Object System.Drawing.Point(515, 86)
$rightContainer.Size = New-Object System.Drawing.Size(650, 644)
$rightContainer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($rightContainer)

# Stat Cards Row (4 cards)
$pnlStats = New-Object System.Windows.Forms.Panel
$pnlStats.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlStats.Height = 78
$rightContainer.Controls.Add($pnlStats)

function New-StatCard([int]$x, [int]$w, [string]$label, [string]$initialVal, [System.Drawing.Color]$accentColor) {
    $c = New-Object System.Windows.Forms.Panel
    $c.Location = New-Object System.Drawing.Point($x, 0)
    $c.Size = New-Object System.Drawing.Size($w, 75)
    $c.BackColor = [System.Drawing.Color]::Transparent
    $c.Tag = (New-Object System.Drawing.SolidBrush $accentColor)

    $c.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $topBr = [System.Drawing.Brush]$s.Tag

        # Shadow
        $sRect = New-Object System.Drawing.Rectangle 1, 2, ($s.Width - 3), ($s.Height - 3)
        $g.FillPath($brShadowStat, (New-RoundedPath $sRect 8))

        # Main Body
        $mRect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 2), ($s.Height - 2)
        $mPath = New-RoundedPath $mRect 8
        $g.FillPath($brWhite, $mPath)
        $g.DrawPath($penBorder, $mPath)

        # Top Accent Stripe
        $topRect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 2), 4
        $topPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $topPath.AddArc(0, 0, 8, 8, 180, 90)
        $topPath.AddArc(($s.Width - 10), 0, 8, 8, 270, 90)
        $topPath.AddLine(($s.Width - 2), 4, 0, 4)
        $topPath.CloseFigure()
        $g.FillPath($topBr, $topPath)
    })

    $lblVal = New-Object System.Windows.Forms.Label
    $lblVal.Text = $initialVal
    $lblVal.Font = $fontStatNum
    $lblVal.ForeColor = $accentColor
    $lblVal.Location = New-Object System.Drawing.Point(14, 10)
    $lblVal.AutoSize = $true
    $lblVal.BackColor = [System.Drawing.Color]::White
    $c.Controls.Add($lblVal)

    $lblText = New-Object System.Windows.Forms.Label
    $lblText.Text = $label
    $lblText.Font = $fontStatLbl
    $lblText.ForeColor = $colorMuted
    $lblText.Location = New-Object System.Drawing.Point(16, 46)
    $lblText.AutoSize = $true
    $lblText.BackColor = [System.Drawing.Color]::White
    $c.Controls.Add($lblText)

    return @{ Panel = $c; ValueLabel = $lblVal }
}

$scW = 155
$scGap = 10
$cardTotal   = New-StatCard 0 ($scW) (T '4LmA4LiE4Lij4Li34LmI4Lit4LiH4LiX4Lix4LmJ4LiH4Lir4Lih4LiU') '0' $colorAccent
$cardOk      = New-StatCard (($scW + $scGap) * 1) ($scW) (T '4Liq4LmB4LiB4LiZ4Liq4Liz4LmA4Lij4LmH4LiIIChPSyk=') '0' $colorSuccess
$cardOffline = New-StatCard (($scW + $scGap) * 2) ($scW) (T '4Lit4Lit4Lif4LmE4Lil4LiZ4LmMIChPZmZsaW5lKQ==') '0' $colorWarning
$cardError   = New-StatCard (($scW + $scGap) * 3) ($scW) (T '4LiC4LmJ4Lit4Lic4Li04LiU4Lie4Lil4Liy4LiUIChFcnJvcik=') '0' $colorDanger

$pnlStats.Controls.Add($cardTotal.Panel)
$pnlStats.Controls.Add($cardOk.Panel)
$pnlStats.Controls.Add($cardOffline.Panel)
$pnlStats.Controls.Add($cardError.Panel)

# Terminal Card
$terminalCard = New-Object System.Windows.Forms.Panel
$terminalCard.Location = New-Object System.Drawing.Point(0, 88)
$terminalCard.Size = New-Object System.Drawing.Size(650, 550)
$terminalCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$terminalCard.BackColor = [System.Drawing.Color]::Transparent
$terminalCard.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $sRect = New-Object System.Drawing.Rectangle 2, 3, ($s.Width - 5), ($s.Height - 5)
    $g.FillPath($brShadowCard, (New-RoundedPath $sRect 10))
    $mRect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 4), ($s.Height - 4)
    $mPath = New-RoundedPath $mRect 10
    $g.FillPath($brWhite, $mPath)
    $g.DrawPath($penBorder, $mPath)
})
$rightContainer.Controls.Add($terminalCard)

$lblTermTitle = New-Object System.Windows.Forms.Label
$lblTermTitle.Text = 'บันทึกการทำงานสด (Live Scan Log)'
$lblTermTitle.Font = $fontCardHeader
$lblTermTitle.ForeColor = $colorText
$lblTermTitle.Location = New-Object System.Drawing.Point(18, 14)
$lblTermTitle.AutoSize = $true
$lblTermTitle.BackColor = [System.Drawing.Color]::White
$terminalCard.Controls.Add($lblTermTitle)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = T '4Lil4LmJ4Liy4LiH4Lia4Lix4LiZ4LiX4Li24LiB'
$btnClearLog.Font = $fontStatLbl
$btnClearLog.Location = New-Object System.Drawing.Point(545, 10)
$btnClearLog.Size = New-Object System.Drawing.Size(85, 26)
$btnClearLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnClearLog.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClearLog.FlatAppearance.BorderColor = $colorBorderVal
$btnClearLog.BackColor = $colorBg
$terminalCard.Controls.Add($btnClearLog)

$pnlTerminalBox = New-Object System.Windows.Forms.Panel
$pnlTerminalBox.Location = New-Object System.Drawing.Point(15, 45)
$pnlTerminalBox.Size = New-Object System.Drawing.Size(616, 490)
$pnlTerminalBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$pnlTerminalBox.BackColor = $colorTerminal
$pnlTerminalBox.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $p = New-RoundedPath (New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)) 8
    $g.DrawPath($penTermBorder, $p)
})
$terminalCard.Controls.Add($pnlTerminalBox)

$txtTerminal = New-Object System.Windows.Forms.RichTextBox
$txtTerminal.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtTerminal.BackColor = $colorTerminal
$txtTerminal.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$txtTerminal.Font = $fontLog
$txtTerminal.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtTerminal.ReadOnly = $true
$txtTerminal.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$txtTerminal.WordWrap = $false
$pnlTerminalBox.Controls.Add($txtTerminal)

# ==============================================================================
# 4. BOTTOM ACTION & PROGRESS PANEL
# ==============================================================================
$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$bottomPanel.Height = 78
$bottomPanel.BackColor = [System.Drawing.Color]::White
$bottomPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.DrawLine($penBorder, 0, 0, $s.Width, 0)
})
$form.Controls.Add($bottomPanel)

# Custom Progress Bar Panel
$pnlProgBar = New-Object System.Windows.Forms.Panel
$pnlProgBar.Location = New-Object System.Drawing.Point(24, 12)
$pnlProgBar.Size = New-Object System.Drawing.Size(650, 14)
$pnlProgBar.Tag = @{ Value = 0; Max = 100 }
$pnlProgBar.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
    $path = New-RoundedPath $rect 7
    $g.FillPath($brProgTrack, $path)

    $pct = [math]::Max(0, [math]::Min(1, ($s.Tag.Value / $s.Tag.Max)))
    $fillW = [int]($rect.Width * $pct)
    if ($fillW -gt 4) {
        $fillR = New-Object System.Drawing.Rectangle 0, 0, $fillW, ($s.Height - 1)
        $fillP = New-RoundedPath $fillR 7
        $fillBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $fillR,
            [System.Drawing.Color]::FromArgb(0, 103, 192),
            [System.Drawing.Color]::FromArgb(16, 185, 129),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
        )
        $g.FillPath($fillBr, $fillP)
        $fillBr.Dispose()
        $fillP.Dispose()
    }
    $path.Dispose()
})
$bottomPanel.Controls.Add($pnlProgBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = T '4Lie4Lij4LmJ4Lit4Lih4Liq4LmB4LiB4LiZ'
$lblStatus.Font = $fontSubtitle
$lblStatus.ForeColor = $colorMuted
$lblStatus.Location = New-Object System.Drawing.Point(24, 30)
$lblStatus.Size = New-Object System.Drawing.Size(500, 22)
$bottomPanel.Controls.Add($lblStatus)

$lblElapsed = New-Object System.Windows.Forms.Label
$lblElapsed.Text = (T '4LmA4Lin4Lil4Liy4LiX4Li14LmI4LmD4LiK4LmJOiA=') + '00:00'
$lblElapsed.Font = $fontSubtitle
$lblElapsed.ForeColor = $colorMuted
$lblElapsed.Location = New-Object System.Drawing.Point(530, 30)
$lblElapsed.Size = New-Object System.Drawing.Size(140, 22)
$bottomPanel.Controls.Add($lblElapsed)

# Action Buttons
$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Location = New-Object System.Drawing.Point(1015, 18)
$btnScan.Size = New-Object System.Drawing.Size(145, 46)
$btnScan.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnScan.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnScan.FlatAppearance.BorderSize = 0
$btnScan.BackColor = [System.Drawing.Color]::Transparent
$btnScan.Cursor = [System.Windows.Forms.Cursors]::Hand

$btnScan.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
    $path = New-RoundedPath $rect 8
    
    $cTop = if ($s.Enabled) { [System.Drawing.Color]::FromArgb(0, 103, 192) } else { [System.Drawing.Color]::FromArgb(148, 163, 184) }
    $cBot = if ($s.Enabled) { [System.Drawing.Color]::FromArgb(15, 76, 151) } else { [System.Drawing.Color]::FromArgb(100, 116, 139) }
    
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $cTop, $cBot, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($br, $path)

    # Play Icon
    $poly = @(
        (New-Object System.Drawing.Point 24, 16),
        (New-Object System.Drawing.Point 24, 30),
        (New-Object System.Drawing.Point 38, 23)
    )
    $g.FillPolygon($brWhite, $poly)

    # Text
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $tRect = New-Object System.Drawing.RectangleF 44, 0, ($s.Width - 44), $s.Height
    $txt = if ($s.Enabled) { (T '4pa2IOC5gOC4o+C4tOC5iOC4oeC4quC5geC4geC4mQ==') } else { (T '4LiB4Liz4Lil4Lix4LiH4Liq4LmB4LiB4LiZLi4u') }
    $g.DrawString($txt, $fontBold, $brWhite, $tRect, $sf)
})
$bottomPanel.Controls.Add($btnScan)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = T '4Lii4LiB4LmA4Lil4Li04LiB'
$btnCancel.Location = New-Object System.Drawing.Point(915, 18)
$btnCancel.Size = New-Object System.Drawing.Size(90, 46)
$btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCancel.FlatAppearance.BorderColor = $colorBorderVal
$btnCancel.BackColor = $colorBg
$btnCancel.Font = $fontRegular
$btnCancel.Enabled = $false
$bottomPanel.Controls.Add($btnCancel)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Location = New-Object System.Drawing.Point(705, 18)
$btnOpenFolder.Size = New-Object System.Drawing.Size(200, 46)
$btnOpenFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnOpenFolder.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpenFolder.FlatAppearance.BorderColor = $colorBorderVal
$btnOpenFolder.BackColor = $colorBg
$btnOpenFolder.Cursor = [System.Windows.Forms.Cursors]::Hand

$btnOpenFolder.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
    $path = New-RoundedPath $rect 8
    $g.FillPath($brWhite, $path)
    $g.DrawPath($penBorder, $path)

    # Vector Folder Icon
    $g.FillRectangle($brFolderBg, 18, 18, 22, 15)
    $g.DrawRectangle($penFolder, 18, 18, 22, 15)
    $g.FillRectangle($brFolderTab, 18, 15, 10, 4)
    $g.DrawRectangle($penFolder, 18, 15, 10, 4)

    # Text
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $tRect = New-Object System.Drawing.RectangleF 46, 0, ($s.Width - 46), $s.Height
    $g.DrawString((T '4LmA4Lib4Li04LiU4LmC4Lif4Lil4LmA4LiU4Lit4Lij4LmM4Lic4Lil4Lil4Lix4Lie4LiY4LmM'), $fontRegular, $brText, $tRect, $sf)
})
$bottomPanel.Controls.Add($btnOpenFolder)

# ==============================================================================
# 5. ASYNC RUNSPACE & EVENT HANDLERS
# ==============================================================================
$script:psInstance    = $null
$script:asyncResult   = $null
$script:scanStartTime = [System.DateTime]::MinValue
$script:timerPoll     = New-Object System.Windows.Forms.Timer
$script:timerPoll.Interval = 150

$script:lastInfoIndex = 0
$script:lastWarnIndex = 0
$script:lastErrIndex  = 0
$script:lastProgIndex = 0
$script:lastHtmlFile  = $null

$script:countTotal   = 0
$script:countOk      = 0
$script:countOffline = 0
$script:countError   = 0

function Append-Log([string]$text, $color = $null) {
    if ($form.IsDisposed) { return }
    $actualColor = $colorWhite
    if ($color -is [System.Drawing.Color]) {
        $actualColor = $color
    } elseif ($color -is [string] -and $color) {
        try { $actualColor = [System.Drawing.Color]::FromName($color) } catch { }
    }
    $ts = (Get-Date).ToString('HH:mm:ss')
    $txtTerminal.SelectionStart = $txtTerminal.TextLength
    $txtTerminal.SelectionLength = 0
    $txtTerminal.SelectionColor = [System.Drawing.Color]::FromArgb(100, 116, 139) # timestamp color
    $txtTerminal.AppendText("[$ts] ")
    $txtTerminal.SelectionColor = $actualColor
    $txtTerminal.AppendText("$text`r`n")
    $txtTerminal.ScrollToCaret()
}

function Set-UIState([bool]$scanning) {
    $btnScan.Enabled       = -not $scanning
    $btnScan.Invalidate()
    $btnCancel.Enabled     = $scanning
    $card1.Enabled         = -not $scanning
    $card2.Enabled         = -not $scanning
    $txtOutDir.Enabled     = -not $scanning
    $btnBrowseOut.Enabled  = -not $scanning
}

$btnClearLog.Add_Click({
    $txtTerminal.Clear()
})

$btnOpenFolder.Add_Click({
    try {
        if (-not (Test-Path $txtOutDir.Text)) {
            New-Item -ItemType Directory -Path $txtOutDir.Text -Force | Out-Null
        }
        [System.Diagnostics.Process]::Start('explorer.exe', $txtOutDir.Text) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$btnBrowseList.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.Title = 'Select PC List File'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtListFile.Text = $dlg.FileName
    }
})

$btnBrowseOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select Output Folder'
    $dlg.SelectedPath = $txtOutDir.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutDir.Text = $dlg.SelectedPath
    }
})

$btnScan.Add_Click({
    if (-not $chkHw.Checked -and -not $chkSw.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            (T '4LiB4Lij4Li44LiT4Liy4LmA4Lil4Li34Lit4LiB4Lit4Lii4LmI4Liy4LiH4LiZ4LmJ4Lit4LiiIDEg4Lij4Liy4Lii4LiB4Liy4LijOiDguKrguYHguIHguJkgSGFyZHdhcmUg4Lir4Lij4Li34LitIFNvZnR3YXJl'),
            'Warning',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $compFile = $null
    $fallbackToAD = $false

    if ($rbFile.Checked) {
        if ([string]::IsNullOrWhiteSpace($txtListFile.Text)) {
            [System.Windows.Forms.MessageBox]::Show(
                (T '4LiB4Lij4Li44LiT4Liy4Lij4Liw4Lia4Li44LmE4Lif4Lil4LmM4Lij4Liy4Lii4LiK4Li34LmI4Lit4LmA4LiE4Lij4Li34LmI4Lit4LiHICgudHh0KQ=='),
                'Warning',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }
        if (-not (Test-Path $txtListFile.Text)) {
            [System.Windows.Forms.MessageBox]::Show(
                ((T '4LmE4Lih4LmI4Lie4Lia4LmE4Lif4Lil4LmMOiA=') + $txtListFile.Text),
                'Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        $lines = @(Get-Content $txtListFile.Text | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' })
        if ($lines.Count -eq 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                (T '4LmE4Lif4Lil4LmM4Lij4Liy4Lii4LiK4Li34LmI4Lit4LmE4Lih4LmI4Lih4Li14LiK4Li34LmI4Lit4LmA4LiE4Lij4Li34LmI4Lit4LiH4Lit4Lii4Li54LmI4LmA4Lil4LiiDQoNCuC4leC5ieC4reC4h+C4geC4suC4o+C4quC5geC4geC4meC5gOC4hOC4o+C4t+C5iOC4reC4h+C4l+C4seC5ieC4h+C4q+C4oeC4lOC4iOC4suC4gSBBY3RpdmUgRGlyZWN0b3J5IOC5geC4l+C4meC4q+C4o+C4t+C4reC5hOC4oeC5iD8='),
                'Empty File',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                $fallbackToAD = $true
                $compFile = $txtListFile.Text
            } else {
                Append-Log '[Cancelled] File is empty' $colorWarning
                return
            }
        } else {
            $compFile = $txtListFile.Text
        }
    }

    try {
        if (-not (Test-Path $txtOutDir.Text)) {
            New-Item -ItemType Directory -Path $txtOutDir.Text -Force | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Cannot create output folder: $($_.Exception.Message)", 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    # Reset UI and Stats
    Set-UIState $true
    $script:countTotal   = 0
    $script:countOk      = 0
    $script:countOffline = 0
    $script:countError   = 0

    $cardTotal.ValueLabel.Text   = '0'
    $cardOk.ValueLabel.Text      = '0'
    $cardOffline.ValueLabel.Text = '0'
    $cardError.ValueLabel.Text   = '0'

    $pnlProgBar.Tag.Value = 0
    $pnlProgBar.Invalidate()
    $lblStatus.Text = 'Connecting...'
    $lblElapsed.Text = (T '4LmA4Lin4Lil4Liy4LiX4Li14LmI4LmD4LiK4LmJOiA=') + '00:00'

    Append-Log '========================================' $colorAccent
    Append-Log "Starting PC Inventory scan ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))" $colorWhite
    Append-Log '========================================' $colorAccent

    $script:lastInfoIndex = 0
    $script:lastWarnIndex = 0
    $script:lastErrIndex  = 0
    $script:lastProgIndex = 0
    $script:lastHtmlFile  = $null
    $script:scanStartTime = [System.DateTime]::Now

    # Setup Runspace
    $script:psInstance = [powershell]::Create()
    [void]$script:psInstance.AddScript($CoreScript)

    $isHw = $chkHw.Checked
    $isSw = $chkSw.Checked
    [void]$script:psInstance.AddParameter('NoSoftware', (-not $isSw))
    [void]$script:psInstance.AddParameter('SkipHardware', (-not $isHw))
    [void]$script:psInstance.AddParameter('NameFilter', $txtFilter.Text)
    [void]$script:psInstance.AddParameter('IncludeUserInstalls', $chkUser.Checked)
    [void]$script:psInstance.AddParameter('IncludeHidden', $chkHidden.Checked)
    [void]$script:psInstance.AddParameter('DaysActive', [int]$numDays.Value)
    [void]$script:psInstance.AddParameter('Throttle', [int]$numThrottle.Value)
    [void]$script:psInstance.AddParameter('OutDir', $txtOutDir.Text)

    if ($compFile)     { [void]$script:psInstance.AddParameter('ComputerListFile', $compFile) }
    if ($fallbackToAD) { [void]$script:psInstance.AddParameter('FallbackToAD', $true) }

    $script:asyncResult = $script:psInstance.BeginInvoke()
    $script:timerPoll.Start()
})

$btnCancel.Add_Click({
    if ($script:psInstance) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            (T '4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4Lii4LiB4LmA4Lil4Li04LiB4LiB4Liy4Lij4Liq4LmB4LiB4LiZ4LmD4LiK4LmI4Lir4Lij4Li34Lit4LmE4Lih4LmIPw=='),
            'Cancel Confirmation',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            Append-Log '[Cancelling...] Stopping scan...' $colorWarning
            try { $script:psInstance.Stop() } catch { }
        }
    }
})

$script:timerPoll.Add_Tick({
    if (-not $script:psInstance) { return }

    # Update elapsed timer
    if ($script:scanStartTime -ne [System.DateTime]::MinValue) {
        $el = [System.DateTime]::Now - $script:scanStartTime
        $lblElapsed.Text = (T '4LmA4Lin4Lil4Liy4LiX4Li14LmI4LmD4LiK4LmJOiA=') + $el.ToString('mm\:ss')
    }

    $streams = $script:psInstance.Streams

    # Read Information Stream
    if ($streams.Information.Count -gt $script:lastInfoIndex) {
        for ($i = $script:lastInfoIndex; $i -lt $streams.Information.Count; $i++) {
            $msg = $streams.Information[$i].MessageData.ToString()
            $color = $colorWhite

            if ($msg -match 'Computers to scan:\s+(\d+)') {
                $script:countTotal = [int]$Matches[1]
                $cardTotal.ValueLabel.Text = "$($script:countTotal)"
                $color = $colorInfo
            }
            elseif ($msg -match 'Software done\.\s+OK:\s+(\d+)') {
                $script:countOk = [int]$Matches[1]
                $cardOk.ValueLabel.Text = "$($script:countOk)"
                $color = $colorSuccess
            }
            elseif ($msg -match '---') {
                $color = $colorInfo
            }
            elseif ($msg -match 'done|OK:') {
                $color = $colorSuccess
            }
            elseif ($msg -match 'fallback|Method') {
                $color = $colorWarning
            }
            Append-Log $msg $color
        }
        $script:lastInfoIndex = $streams.Information.Count
    }

    # Read Warning Stream
    if ($streams.Warning.Count -gt $script:lastWarnIndex) {
        for ($i = $script:lastWarnIndex; $i -lt $streams.Warning.Count; $i++) {
            $w = $streams.Warning[$i].Message
            Append-Log ("[WARNING] " + $w) $colorWarning
            if ($w -match 'Offline|not reachable') {
                $script:countOffline++
                $cardOffline.ValueLabel.Text = "$($script:countOffline)"
            }
        }
        $script:lastWarnIndex = $streams.Warning.Count
    }

    # Read Error Stream
    if ($streams.Error.Count -gt $script:lastErrIndex) {
        for ($i = $script:lastErrIndex; $i -lt $streams.Error.Count; $i++) {
            $err = $streams.Error[$i].ToString()
            Append-Log ("[ERROR] " + $err) $colorDanger
            $script:countError++
            $cardError.ValueLabel.Text = "$($script:countError)"
        }
        $script:lastErrIndex = $streams.Error.Count
    }

    # Read Progress Stream
    if ($streams.Progress.Count -gt $script:lastProgIndex) {
        for ($i = $script:lastProgIndex; $i -lt $streams.Progress.Count; $i++) {
            $p = $streams.Progress[$i]
            if ($p.PercentComplete -ge 0 -and $p.PercentComplete -le 100) {
                $pnlProgBar.Tag.Value = $p.PercentComplete
                $pnlProgBar.Invalidate()
            }
            $lblStatus.Text = "$($p.Activity): $($p.StatusDescription) - $($p.PercentComplete)%"
        }
        $script:lastProgIndex = $streams.Progress.Count
    }

    # Completion Check
    if ($script:asyncResult -and $script:asyncResult.IsCompleted) {
        $script:timerPoll.Stop()
        $pnlProgBar.Tag.Value = 100
        $pnlProgBar.Invalidate()
        $lblStatus.Text = (T '4Liq4LmB4LiB4LiZ4LmA4Liq4Lij4LmH4LiI4Liq4Li04LmJ4LiZ')

        try {
            $res = $script:psInstance.EndInvoke($script:asyncResult)
            if ($res -and $res.Count -gt 0) {
                $lastObj = $res[$res.Count - 1]
                if ($lastObj -and $lastObj.SoftwareHtml) {
                    $script:lastHtmlFile = $lastObj.SoftwareHtml
                }
            }
        } catch {
            Append-Log "[EXCEPTION] $($_.Exception.Message)" $colorDanger
        } finally {
            $script:psInstance.Dispose()
            $script:psInstance = $null
            $script:asyncResult = $null
        }

        Set-UIState $false
        Append-Log '========================================' $colorSuccess
        Append-Log "Scan completed ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))" $colorSuccess
        Append-Log "Output folder: $($txtOutDir.Text)" $colorInfo
        Append-Log '========================================' $colorSuccess

        # Auto open HTML
        if ($chkAutoHtml.Checked -and $script:lastHtmlFile -and (Test-Path $script:lastHtmlFile)) {
            try {
                [System.Diagnostics.Process]::Start($script:lastHtmlFile) | Out-Null
                Append-Log "Auto-opened report: $script:lastHtmlFile" $colorSuccess
            } catch { }
        }

        [System.Windows.Forms.MessageBox]::Show(
            ((T '4LiB4Liy4Lij4Liq4LmB4LiB4LiZ4LmA4Liq4Lij4LmH4LiI4Liq4Lih4Lia4Li54Lij4LiT4LmMIQ0KDQrguJzguKXguKXguLHguJ7guJjguYzguJbguLnguIHguJrguLHguJnguJfguLbguIHguYTguKfguYnguYPguJk6DQo=') + "`n$($txtOutDir.Text)"),
            'Done',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:psInstance -and $script:asyncResult -and (-not $script:asyncResult.IsCompleted)) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            (T '4LiB4Liy4Lij4Liq4LmB4LiB4LiZ4LiB4Liz4Lil4Lix4LiH4LiX4Liz4LiH4Liy4LiZ4Lit4Lii4Li54LmIDQrguITguLjguJPguJXguYnguK3guIfguIHguLLguKPguKLguIHguYDguKXguLTguIHguYHguKXguLDguJvguLTguJTguYLguJvguKPguYHguIHguKPguKHguKvguKPguLfguK3guYTguKHguYg/'),
            'Confirm Exit',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:timerPoll.Stop()
            try { $script:psInstance.Stop() } catch { }
            try { $script:psInstance.Dispose() } catch { }
        } else {
            $e.Cancel = $true
        }
    }
})

# Launch GUI
[System.Windows.Forms.Application]::Run($form)
