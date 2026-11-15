# The WiX dialog bitmaps for installer/windows/stowlark.wxs, to the design in the
# Stowlark Installer Windows canvas: the dialog bitmap is a 164 px green panel
# (the stacked lockup, the version under it) beside a white field the WixUI
# text sits on; the banner is a chalk strip with the horizontal lockup at
# its right (Windows Installer draws the banner text black, so it stays
# light). 24-bit BMP, the only format MSI takes.
#   WixUIDialogBmp 493x312, WixUIBannerBmp 493x58
#
# Two jobs:
#   make-bitmaps.ps1
#     Draws both from brand/logo with Edge (headless) at 2x, downsampled,
#     into this folder, without a version: the committed art. Run it when
#     the logos or the design change.
#   make-bitmaps.ps1 -Stamp -Version 0.1.0 -Out <dir>
#     Copies the committed art to <dir> and writes the version under the
#     lockup with System.Drawing: no browser, so a CI runner does it from
#     the checkout. `cargo xtask msi` runs this.
param(
    [switch]$Stamp,
    [string]$Version = '0.1.0',
    [string]$Out = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Where the version goes, in the 493x312 dialog: centred in the panel, under
# the lockup (the render below reserves this line, so the two agree).
$PanelWidth = 164
$VersionTop = 225
$VersionHeight = 11
$VersionColor = [System.Drawing.Color]::FromArgb(0x9A, 0xA3, 0xAE)

function Save-Bmp([System.Drawing.Bitmap]$Bitmap, [string]$Path) {
    # Through a 24-bit copy: Bitmap.Save writes the pixel format it holds.
    $flat = New-Object System.Drawing.Bitmap $Bitmap.Width, $Bitmap.Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($flat)
    $g.DrawImageUnscaled($Bitmap, 0, 0); $g.Dispose()
    $flat.Save($Path, [System.Drawing.Imaging.ImageFormat]::Bmp); $flat.Dispose()
}

if ($Stamp) {
    New-Item -ItemType Directory -Force $Out | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'wix-banner.bmp') (Join-Path $Out 'wix-banner.bmp') -Force
    $src = [System.Drawing.Bitmap]::FromFile((Join-Path $PSScriptRoot 'wix-dialog.bmp'))
    $bmp = New-Object System.Drawing.Bitmap $src; $src.Dispose()
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
    $face = @('JetBrains Mono', 'Cascadia Mono', 'Consolas', 'Lucida Console') | Where-Object { $installed -contains $_ } | Select-Object -First 1
    $font = New-Object System.Drawing.Font $face, 7.5, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Point)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'; $fmt.FormatFlags = 'NoWrap'
    $brush = New-Object System.Drawing.SolidBrush $VersionColor
    $rect = [System.Drawing.RectangleF]::new(0, $VersionTop - 2, $PanelWidth, $VersionHeight + 4)
    $g.DrawString("$Version $([char]0xB7) x64", $font, $brush, $rect, $fmt)
    $g.Dispose(); $font.Dispose(); $brush.Dispose()
    Save-Bmp $bmp (Join-Path $Out 'wix-dialog.bmp'); $bmp.Dispose()
    Write-Host "stamped $Version ($face) onto $(Join-Path $Out 'wix-dialog.bmp'); copied wix-banner.bmp"
    return
}

$logo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\logo')).Path
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge is needed to render the installer bitmaps" }
New-Item -ItemType Directory -Force $Out | Out-Null
$work = Join-Path $env:TEMP 'stowlark-wix-bitmaps'
New-Item -ItemType Directory -Force $work | Out-Null

function FileUrl([string]$p) { 'file:///' + ($p -replace '\\', '/') }

# Renders $Html (a page sized $W x $H CSS px) at 2x, downsamples, writes BMP (and a PNG to look at).
function Render([string]$Name, [int]$W, [int]$H, [string]$Html) {
    $page = Join-Path $work "$Name.html"
    $shot = Join-Path $work "$Name@2x.png"
    [System.IO.File]::WriteAllText($page, $Html, (New-Object System.Text.UTF8Encoding $false))
    Remove-Item $shot -ErrorAction SilentlyContinue
    # Edge reports on stderr; Start-Process keeps that out of PowerShell's error stream.
    Start-Process -FilePath $edge -Wait -WindowStyle Hidden -ArgumentList @(
        '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
        "--user-data-dir=`"$(Join-Path $work 'edge')`"", "--window-size=$W,$H", "--screenshot=`"$shot`"", (FileUrl $page)) | Out-Null
    for ($i = 0; $i -lt 50 -and -not (Test-Path $shot); $i++) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $shot)) { throw "Edge did not render $page" }

    $src = [System.Drawing.Bitmap]::FromFile($shot)
    $bmp = New-Object System.Drawing.Bitmap $W, $H, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
    $g.DrawImage($src, [System.Drawing.Rectangle]::new(0, 0, $W, $H), [System.Drawing.Rectangle]::new(0, 0, $src.Width, $src.Height), 'Pixel')
    $g.Dispose(); $src.Dispose()
    $bmp.Save((Join-Path $Out "$Name.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Save((Join-Path $work "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "wrote $(Join-Path $Out "$Name.bmp") ($W x $H)"
}

$stacked = FileUrl (Join-Path $logo 'stowlark-stacked-dark.svg')
$horizontal = FileUrl (Join-Path $logo 'stowlark-horizontal-light.svg')

# Dialog: the dark panel ends before WixUI's text starts. The lockup leaves
# room for the version at y = 225, where -Stamp writes.
Render 'wix-dialog' 493 312 @"
<!doctype html><meta charset="utf-8">
<body style="margin:0;width:493px;height:312px;overflow:hidden;background:#FFFFFF">
<div style="position:absolute;left:0;top:0;width:${PanelWidth}px;height:312px;
            background:linear-gradient(180deg,#22483F 0%,#102D28 100%)">
  <img src="$stacked" alt="" style="position:absolute;left:23px;top:76px;width:118px;display:block">
</div>
"@

# Banner: chalk, the horizontal lockup at the right; WixUI draws the title at the left.
Render 'wix-banner' 493 58 @"
<!doctype html><meta charset="utf-8">
<body style="margin:0;width:493px;height:58px;overflow:hidden;background:#EFF7F3">
<img src="$horizontal" alt="" style="position:absolute;right:14px;top:16px;height:26px;display:block">
"@
