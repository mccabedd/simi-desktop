<#
SIMI-desktop.ps1
Standalone portable viewer for ComfyUI PNG metadata. v3.6
#>
param(
    [string]$FilePath = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
$assetsDir    = Join-Path $scriptDir 'Assets'
$helperPath   = Join-Path $assetsDir 'ComfyUI-PNG-Meta.ps1'
$iconsDir     = Join-Path $assetsDir 'Icons'
$stateDir     = Join-Path $env:APPDATA 'SIMI-desktop'
if (-not (Test-Path -LiteralPath $stateDir)) { [void][System.IO.Directory]::CreateDirectory($stateDir) }
$panelStateFile = Join-Path $stateDir 'panel-state.json'

# Single instance: later launches update the signal file and exit.
$createdNew = $false
$mutexName = 'SIMI-desktop-SingleInstance'
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Custom Form subclass: adds WS_MINIMIZEBOX to the window style so the taskbar
# button properly minimises/restores the borderless panel.
$WarningPreference = 'SilentlyContinue'
Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System.Windows.Forms;
public class ComfyMetaForm : Form {
    const int WM_SYSCOMMAND = 0x0112;
    const int SC_MINIMIZE   = 0xF020;
    const int SC_RESTORE    = 0xF120;
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.Style |= 0x00020000; // WS_MINIMIZEBOX
            return cp;
        }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_SYSCOMMAND) {
            int cmd = m.WParam.ToInt32() & 0xFFF0;
            if (cmd == SC_MINIMIZE) { WindowState = FormWindowState.Minimized; return; }
            if (cmd == SC_RESTORE)  { WindowState = FormWindowState.Normal;    return; }
        }
        base.WndProc(ref m);
    }
}
'@

# Give this process its own AppUserModelId so Windows treats it as a distinct
# taskbar entry (separate from powershell.exe) and uses our custom icon.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class AppUserModel {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@

# Minimal Win32 shim — only SendMessage needed to drive EM_LINESCROLL on the prompt RichTextBoxes.
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
}
'@
$WarningPreference = 'Continue'
[AppUserModel]::SetCurrentProcessExplicitAppUserModelID('SIMI.desktop') | Out-Null

[System.Windows.Forms.Application]::EnableVisualStyles()

# Load copy icon from the sibling folder; scale to 20x20 for display in the 24px-tall button.
try {
    $iconPath = Join-Path $iconsDir 'copy-icon.png'
    if (Test-Path -LiteralPath $iconPath) {
        $srcBmp = [System.Drawing.Bitmap]::new($iconPath)
        $iconSize = 10
        $iconBmp = New-Object System.Drawing.Bitmap -ArgumentList $iconSize, $iconSize
        $ig = [System.Drawing.Graphics]::FromImage($iconBmp)
        $ig.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $ig.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $ig.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $ig.Clear([System.Drawing.Color]::Transparent)
        $ig.DrawImage($srcBmp, 0, 0, $iconSize, $iconSize)
        $ig.Dispose()
        $srcBmp.Dispose()
        $script:copyIcon = $iconBmp
    }
} catch {}

# One-shot timer: reverts status bar back to the loaded timestamp 3s after a copy action.
$statusRevertTimer = New-Object System.Windows.Forms.Timer
$statusRevertTimer.Interval = 3000
$statusRevertTimer.Add_Tick({
    $statusRevertTimer.Stop()
    $statusLabel.Text = $script:loadedStatusText
})

# Tooltip shown when hovering the copy icon button.
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutomaticDelay = 400
$toolTip.AutoPopDelay  = 3000
$toolTip.InitialDelay  = 400
$toolTip.ReshowDelay   = 200
$toolTip.ShowAlways    = $true

$script:currentFile = ''
$script:restoredFile = ''
$script:lastMetaText = ''
$script:loadedStatusText = ''
$script:rowModels = New-Object System.Collections.Generic.List[object]
$script:scrollOffset = 0
$script:maxScroll = 0
$script:contentHeight = 0
$script:draggingThumb = $false
$script:dragStartY = 0
$script:dragStartOffset = 0
$script:stateDirty = $false
$script:loadingState = $false
$script:draggingWindow = $false
$script:dragMouseStart = [System.Drawing.Point]::Empty
$script:dragFormStart = [System.Drawing.Point]::Empty
$script:resizingWindow = $false
$script:resizeMouseStart = [System.Drawing.Point]::Empty
$script:resizeFormStartSize = [System.Drawing.Size]::Empty
$script:showImage    = $true
$script:currentImage = $null
$script:imageAspect  = 1.0
$script:siblingPngs  = @()
$script:siblingIndex = -1
$script:dopusrt      = $null
$script:prevIcon     = $null
$script:nextIcon     = $null
$script:isCollapsed    = $false
$script:expandedHeight = 0
$script:layoutMode     = 'Vertical'   # 'Vertical' | 'Horizontal'
$script:vertWidth      = 0            # remembered vertical-mode width
$script:vertHeight     = 0            # remembered vertical-mode height
$script:horzIconH      = $null        # toolbar icon: switch to horizontal
$script:horzIconV      = $null        # toolbar icon: switch to vertical
$script:horzImageBox   = $null        # PictureBox in horizontal image column
$script:horzPrevArrow  = $null
$script:horzNextArrow  = $null
$script:horzImgCounter = $null
$script:horzPosRtb     = $null        # positive prompt RichTextBox
$script:horzNegRtb     = $null        # negative prompt RichTextBox
$script:horzPosDragging = $false      # RTB custom scroll drag state — positive column
$script:horzPosDragY    = 0
$script:horzPosDragLine = 0
$script:horzNegDragging = $false      # RTB custom scroll drag state — negative column
$script:horzNegDragY    = 0
$script:horzNegDragLine = 0
$script:horzInfoRows   = New-Object System.Collections.Generic.List[object]  # mini-row models for Info column
$script:horzSampRows   = New-Object System.Collections.Generic.List[object]  # mini-row models for Sampler column
$script:horzInfoScroll = @{ Offset=0; MaxScroll=0; ContentH=0; Dragging=$false; DragY=0; DragOffset=0; Track=$null; Thumb=$null; Viewport=$null; Content=$null }
$script:horzSampScroll = @{ Offset=0; MaxScroll=0; ContentH=0; Dragging=$false; DragY=0; DragOffset=0; Track=$null; Thumb=$null; Viewport=$null; Content=$null }
$script:closeIcon       = $null
$script:collapseIcon    = $null
$script:expandIcon      = $null
$script:imageIconNormal = $null
$script:imageIconDimmed = $null
$script:minimizeIcon    = $null
$script:moveIcon        = $null
$script:openIcon        = $null
$script:pinIconNormal   = $null
$script:pinIconDimmed   = $null

# Locate dopusrt.exe so the image double-click can open DOpus's built-in viewer.
try {
    $prop = Get-ItemProperty 'HKLM:\SOFTWARE\GPSoftware\Directory Opus' -ErrorAction Stop
    $cand = Join-Path $prop.InstallPath 'dopusrt.exe'
    if (Test-Path -LiteralPath $cand) { $script:dopusrt = $cand }
} catch {}

# Load nav icons (previous.png / next.png) at 16x16.
try {
    $navIconSize = 16
    foreach ($pair in @( @('previous.png', 'prevIcon'), @('next.png', 'nextIcon') )) {
        $niPath = Join-Path $iconsDir $pair[0]
        if (Test-Path -LiteralPath $niPath) {
            $nSrc = [System.Drawing.Bitmap]::new($niPath)
            $nBmp = New-Object System.Drawing.Bitmap -ArgumentList $navIconSize, $navIconSize
            $nig  = [System.Drawing.Graphics]::FromImage($nBmp)
            $nig.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $nig.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $nig.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $nig.Clear([System.Drawing.Color]::Transparent)
            $nig.DrawImage($nSrc, 0, 0, $navIconSize, $navIconSize)
            $nig.Dispose(); $nSrc.Dispose()
            if ($pair[1] -eq 'prevIcon') { $script:prevIcon = $nBmp } else { $script:nextIcon = $nBmp }
        }
    }
} catch {}

# Helper: render a bitmap at reduced alpha for dimmed/inactive toggle states.
function New-DimmedBitmap {
    param([System.Drawing.Bitmap]$Source, [float]$Alpha = 0.35)
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $Source.Width, $Source.Height
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $cm  = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix33 = $Alpha
    $ia  = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $Source.Width, $Source.Height
    $g.DrawImage($Source, $rect, 0, 0, $Source.Width, $Source.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $ia.Dispose(); $g.Dispose()
    return $bmp
}

# Load 8 toolbar icons at 14px (between copy-icon 10px and nav arrows 16px).
try {
    $tbSz = 14
    function Load-TbIcon { param([string]$n)
        $p = Join-Path $iconsDir "$n.png"
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $src = [System.Drawing.Bitmap]::new($p)
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $tbSz, $tbSz
        $ig  = [System.Drawing.Graphics]::FromImage($bmp)
        $ig.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $ig.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $ig.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $ig.Clear([System.Drawing.Color]::Transparent)
        $ig.DrawImage($src, 0, 0, $tbSz, $tbSz)
        $ig.Dispose(); $src.Dispose()
        return $bmp
    }
    $script:closeIcon       = Load-TbIcon 'close'
    $script:collapseIcon    = Load-TbIcon 'collapse'
    $script:expandIcon      = Load-TbIcon 'expand'
    $script:imageIconNormal = Load-TbIcon 'image'
    $script:minimizeIcon    = Load-TbIcon 'minimize'
    $script:moveIcon        = Load-TbIcon 'move'
    $script:openIcon        = Load-TbIcon 'open'
    $script:pinIconNormal   = Load-TbIcon 'pin'
    if ($null -ne $script:imageIconNormal) { $script:imageIconDimmed = New-DimmedBitmap $script:imageIconNormal }
    if ($null -ne $script:pinIconNormal)   { $script:pinIconDimmed   = New-DimmedBitmap $script:pinIconNormal   }
} catch {}

# Layout-toggle icons. Drop layout-h.png / layout-v.png into Assets\Icons\ for proper artwork.
# Falls back to generated letter bitmaps (H / V) if the files are absent.
try {
    function New-LayoutIcon { param([string]$Letter)
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList 14, 14
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $br  = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(200, 200, 200))
        $ft  = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 7.5, ([System.Drawing.FontStyle]::Bold)
        $sf  = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $rf  = New-Object System.Drawing.RectangleF -ArgumentList 0, 0, 14, 14
        $g.DrawString($Letter, $ft, $br, $rf, $sf)
        $sf.Dispose(); $ft.Dispose(); $br.Dispose(); $g.Dispose()
        return $bmp
    }
    $hpng = Join-Path $iconsDir 'layout-h.png'
    $vpng = Join-Path $iconsDir 'layout-v.png'
    $script:horzIconH = if (Test-Path -LiteralPath $hpng) { Load-TbIcon 'layout-h' } else { New-LayoutIcon 'H' }
    $script:horzIconV = if (Test-Path -LiteralPath $vpng) { Load-TbIcon 'layout-v' } else { New-LayoutIcon 'V' }
} catch {}

function Display-Value {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'N/A' }
    return $Value
}

function ConvertTo-PlainRows {
    param($Meta)
    $labels = [ordered]@{
        PositivePrompt = 'Positive Prompt'
        NegativePrompt = 'Negative Prompt'
        Seed = 'Seed'
        Resolution = 'Resolution'
        LoRAs = "LoRA's"
        Model = 'Model'
        TextEncoder = 'Text Encoder'
        Sampler = 'Sampler'
        Scheduler = 'Scheduler'
        Steps = 'Steps'
        CFG = 'CFG'
    }
    $optional = @('NegativePrompt', 'LoRAs', 'TextEncoder')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $labels.Keys) {
        $raw = [string]($Meta.$k)
        if ($optional -contains $k -and [string]::IsNullOrWhiteSpace($raw)) { continue }
        $v = Display-Value $raw
        [void]$lines.Add($labels[$k] + ': ' + $v)
    }
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-ComfyMetaJson {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $helperPath)) { throw "Helper script not found: $helperPath" }
    $json = & $helperPath -Path $FilePath -Output Json 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'No JSON returned by metadata helper.' }
    return ($json | ConvertFrom-Json)
}

function Set-PanelImage {
    param([string]$FilePath)

    try {
        if ($null -ne $script:currentImage) {
            try { $script:currentImage.Dispose() } catch {}
        }
        $script:currentImage = $null
        $script:imageAspect = 1.0
        if ($null -ne $imageBox) { $imageBox.Image = $null }
        if (-not (Test-Path -LiteralPath $FilePath)) { return }

        $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $img = [System.Drawing.Image]::FromStream($fs)
            try {
                $bmp = New-Object System.Drawing.Bitmap -ArgumentList $img
                $script:currentImage = $bmp
                if ($bmp.Height -gt 0) { $script:imageAspect = [double]$bmp.Width / [double]$bmp.Height }
            } finally {
                $img.Dispose()
            }
        } finally {
            $fs.Dispose()
        }
        if ($null -ne $imageBox)              { $imageBox.Image = $script:currentImage }
        if ($null -ne $script:horzImageBox)   { $script:horzImageBox.Image = $script:currentImage }
    } catch {
        $script:currentImage = $null
        $script:imageAspect = 1.0
        if ($null -ne $imageBox)              { $imageBox.Image = $null }
        if ($null -ne $script:horzImageBox)   { $script:horzImageBox.Image = $null }
    }
}

function New-DarkColor([int]$r, [int]$g, [int]$b) {
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

$bg = New-DarkColor 18 18 18
$toolbarBg = New-DarkColor 30 30 30
$rowBg = New-DarkColor 14 14 14
$rowBorder = New-DarkColor 72 72 72
$fg = New-DarkColor 238 238 238
$muted = New-DarkColor 170 170 170
$buttonBg = New-DarkColor 35 35 35
$copyButtonBg = [System.Drawing.ColorTranslator]::FromHtml('#002342')
$copyButtonHoverBg = New-DarkColor 0 47 88
$scrollTrackBg = New-DarkColor 25 25 25
$scrollThumbBg = New-DarkColor 92 92 92
$scrollThumbHoverBg = New-DarkColor 125 125 125
$formBorder = New-DarkColor 70 70 70

$form = New-Object ComfyMetaForm
$form.Text = 'SIMI-desktop'
$form.Width = 430
$form.Height = 760
$form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 300, 420
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'None'
$form.BackColor = $bg
$form.ForeColor = $fg
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.KeyPreview = $true

# Blue-tinted SD icon for the taskbar button.
try {
    $sdBluePath = Join-Path $iconsDir 'simi-desktop-blue.ico'
    if (Test-Path -LiteralPath $sdBluePath) {
        $form.Icon = New-Object System.Drawing.Icon -ArgumentList $sdBluePath
    }
} catch {}
$form.Add_Paint({
    param($sender, $eventArgs)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($sender.Width - 1), ($sender.Height - 1)
    $pen = New-Object System.Drawing.Pen -ArgumentList $formBorder
    try { $eventArgs.Graphics.DrawRectangle($pen, $rect) } finally { $pen.Dispose() }
})
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close(); return }
    if ($script:showImage -and $null -ne $script:currentImage) {
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Left) {
            $eventArgs.SuppressKeyPress = $true
            Navigate-Image -1
        } elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Right) {
            $eventArgs.SuppressKeyPress = $true
            Navigate-Image 1
        }
    }
})

function Get-VisibleScreenRect {
    param([int]$Left, [int]$Top, [int]$Width, [int]$Height)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList $Left, $Top, $Width, $Height
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.WorkingArea.IntersectsWith($rect)) { return $true }
    }
    return $false
}

function Load-PanelState {
    if (-not (Test-Path -LiteralPath $panelStateFile)) { return $false }
    try {
        $state = Get-Content -LiteralPath $panelStateFile -Raw | ConvertFrom-Json
        $w = [Math]::Max($form.MinimumSize.Width, [int]$state.Width)
        $h = [Math]::Max($form.MinimumSize.Height, [int]$state.Height)
        $l = [int]$state.Left
        $t = [int]$state.Top
        if (-not (Get-VisibleScreenRect $l $t $w $h)) { return $false }
        $script:loadingState = $true
        $form.Width = $w
        $form.Height = $h
        $form.Left = $l
        $form.Top = $t
        if ($null -ne $state.TopMost)   { $form.TopMost = [bool]$state.TopMost }
        if ($state.LastFile)            { $script:restoredFile = [string]$state.LastFile }
        if ($null -ne $state.LayoutMode -and [string]$state.LayoutMode -ne '') {
            $script:layoutMode = [string]$state.LayoutMode
        }
        if ($null -ne $state.VertWidth -and [int]$state.VertWidth -gt 0) {
            $script:vertWidth  = [int]$state.VertWidth
            $script:vertHeight = [int]$state.VertHeight
        }
        # When restoring into horizontal mode, the saved Width/Height are the horz dimensions — keep them.
        # The vertical dims are in VertWidth/VertHeight above.
        $script:loadingState = $false
        return $true
    } catch {
        $script:loadingState = $false
        return $false
    }
}

function Save-PanelState {
    try {
        $state = [ordered]@{
            Left       = $form.Left
            Top        = $form.Top
            Width      = $form.Width
            Height     = $form.Height
            VertWidth  = if ($script:layoutMode -eq 'Horizontal') { $script:vertWidth  } else { $form.Width  }
            VertHeight = if ($script:layoutMode -eq 'Horizontal') { $script:vertHeight } else { $form.Height }
            LayoutMode = $script:layoutMode
            TopMost    = $form.TopMost
            LastFile   = $script:currentFile
        }
        ($state | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $panelStateFile -Encoding UTF8
        $script:stateDirty = $false
    } catch {}
}

if (-not (Load-PanelState)) {
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Left = [Math]::Max(0, $wa.Right - $form.Width - 20)
        $form.Top = [Math]::Max(0, $wa.Top + 40)
    } catch {}
}

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.ColumnCount = 1
$main.RowCount = 2
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100)))
$main.BackColor = $bg
$form.Controls.Add($main)

$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Fill'
$toolbar.BackColor = $toolbarBg
$main.Controls.Add($toolbar, 0, 0)

function Update-ImageBtnState {
    if ($null -eq $imageBtn) { return }
    $active = $script:showImage -and ($null -ne $script:currentImage)
    if ($active -and $null -ne $script:imageIconDimmed) { $imageBtn.Image = $script:imageIconDimmed } else { $imageBtn.Image = $script:imageIconNormal }
    $tip = if ($script:showImage) { 'Hide Image' } else { 'Show Image' }
    try { $toolTip.SetToolTip($imageBtn, $tip) } catch {}
}

function Update-PinBtnState {
    if ($null -eq $pinBtn) { return }
    if ($form.TopMost -and $null -ne $script:pinIconDimmed) { $pinBtn.Image = $script:pinIconDimmed } else { $pinBtn.Image = $script:pinIconNormal }
    $tip = if ($form.TopMost) { 'Unpin' } else { 'Pin' }
    try { $toolTip.SetToolTip($pinBtn, $tip) } catch {}
}

function Toggle-Collapse {
    if ($script:isCollapsed) {
        $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList $form.MinimumSize.Width, 420
        $form.Height = [Math]::Max(420, $script:expandedHeight)
        $script:isCollapsed = $false
        if ($null -ne $script:collapseIcon) { $collapseBtn.Image = $script:collapseIcon }
        try { $toolTip.SetToolTip($collapseBtn, 'Collapse') } catch {}
    } else {
        $script:expandedHeight = $form.Height
        $script:isCollapsed = $true
        $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList $form.MinimumSize.Width, 1
        $form.Height = 52
        if ($null -ne $script:expandIcon) { $collapseBtn.Image = $script:expandIcon }
        try { $toolTip.SetToolTip($collapseBtn, 'Expand') } catch {}
    }
}

function Open-FolderBrowser {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select a folder to browse PNG images'
    $dlg.ShowNewFolderButton = $false
    if (-not [string]::IsNullOrWhiteSpace($script:currentFile)) {
        $startDir = [System.IO.Path]::GetDirectoryName($script:currentFile)
        if (Test-Path -LiteralPath $startDir) { $dlg.SelectedPath = $startDir }
    }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $pngs = @(Get-ChildItem -LiteralPath $dlg.SelectedPath -Filter '*.png' -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
        if ($pngs.Count -gt 0) {
            $script:siblingPngs  = $pngs
            $script:siblingIndex = 0
            Load-FileIntoPanel $pngs[0]
        } else {
            $statusLabel.Text = 'No PNG files found in selected folder'
        }
    }
    $dlg.Dispose()
}

function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'About'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $bg
    $dlg.ForeColor       = $fg
    $dlg.ClientSize      = New-Object System.Drawing.Size 300, 178
    $dlg.ShowInTaskbar   = $false
    $dlg.TopMost         = $form.TopMost

    $lblAcronym = New-Object System.Windows.Forms.Label
    $lblAcronym.Text      = 'S:I:M:I'
    $lblAcronym.Font      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 22, ([System.Drawing.FontStyle]::Bold)
    $lblAcronym.ForeColor = $fg
    $lblAcronym.BackColor = [System.Drawing.Color]::Transparent
    $lblAcronym.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblAcronym.AutoSize  = $false
    $lblAcronym.SetBounds(0, 12, 300, 46)
    $dlg.Controls.Add($lblAcronym)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text      = 'Simple Image Metadata Inspector'
    $lblName.Font      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
    $lblName.ForeColor = $muted
    $lblName.BackColor = [System.Drawing.Color]::Transparent
    $lblName.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblName.AutoSize  = $false
    $lblName.SetBounds(0, 62, 300, 22)
    $dlg.Controls.Add($lblName)

    $lblAuthor = New-Object System.Windows.Forms.Label
    $lblAuthor.Text      = 'David McCabe (2026)'
    $lblAuthor.Font      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
    $lblAuthor.ForeColor = $muted
    $lblAuthor.BackColor = [System.Drawing.Color]::Transparent
    $lblAuthor.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblAuthor.AutoSize  = $false
    $lblAuthor.SetBounds(0, 86, 300, 22)
    $dlg.Controls.Add($lblAuthor)

    $lblLink = New-Object System.Windows.Forms.LinkLabel
    $lblLink.Text            = 'https://github.com/mccabedd/simi-desktop'
    $lblLink.Font            = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
    $lblLink.LinkColor       = [System.Drawing.Color]::FromArgb(88, 166, 255)
    $lblLink.ActiveLinkColor = [System.Drawing.Color]::White
    $lblLink.BackColor       = [System.Drawing.Color]::Transparent
    $lblLink.TextAlign       = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblLink.AutoSize        = $false
    $lblLink.SetBounds(0, 110, 300, 20)
    $lblLink.Add_LinkClicked({ Start-Process 'https://github.com/mccabedd/simi-desktop' })
    $dlg.Controls.Add($lblLink)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text      = 'OK'
    $okBtn.Width     = 80
    $okBtn.Height    = 26
    $okBtn.Left      = 110
    $okBtn.Top       = 140
    $okBtn.BackColor = $buttonBg
    $okBtn.ForeColor = $fg
    $okBtn.FlatStyle = 'Flat'
    $okBtn.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($okBtn)
    $dlg.AcceptButton = $okBtn

    $dlg.ShowDialog($form) | Out-Null
    $dlg.Dispose()
}

function Add-DropTarget {
    param($Control)
    $Control.AllowDrop = $true
    $Control.Add_DragEnter({
        param($s, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $droppedFiles = [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            $hasPng = $false
            foreach ($df in $droppedFiles) { if ($df -match '\.png$') { $hasPng = $true; break } }
            if ($hasPng) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
        } else {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })
    $Control.Add_DragDrop({
        param($s, $e)
        $droppedFiles = [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        $png = $null
        foreach ($df in $droppedFiles) { if ($df -match '\.png$') { $png = $df; break } }
        if ($null -ne $png) { Load-FileIntoPanel $png }
    })
}

function Make-TbBtn {
    param([System.Drawing.Bitmap]$Icon, [string]$FallbackText, [string]$TipText, [switch]$IsDrag)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.BackColor = $toolbarBg
    $lbl.ForeColor = $muted
    $lbl.Width = 24; $lbl.Height = 24; $lbl.Top = 5
    $lbl.TextAlign = 'MiddleCenter'
    if ($null -ne $Icon) { $lbl.Image = $Icon; $lbl.ImageAlign = 'MiddleCenter'; $lbl.Text = '' }
    else                 { $lbl.Text = $FallbackText }
    if ($IsDrag) {
        $lbl.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    } else {
        $lbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $lbl.Add_MouseEnter({ param($s, $e) $s.BackColor = $buttonBg })
        $lbl.Add_MouseLeave({ param($s, $e) $s.BackColor = $toolbarBg })
        if (-not [string]::IsNullOrEmpty($TipText)) { $toolTip.SetToolTip($lbl, $TipText) }
    }
    return $lbl
}

# Open folder
$openBtn = Make-TbBtn -Icon $script:openIcon -FallbackText 'O' -TipText 'Open Folder'
$openBtn.Left = 8
$openBtn.Add_Click({ Open-FolderBrowser })
$toolbar.Controls.Add($openBtn)

# About
$aboutBtn = Make-TbBtn -Icon $null -FallbackText '?' -TipText 'About'
$aboutBtn.Left = $openBtn.Right + 4
$aboutBtn.Add_Click({ Show-AboutDialog })
$toolbar.Controls.Add($aboutBtn)

# Pin / TopMost toggle  (right group — SizeChanged positions these)
$pinBtn = Make-TbBtn -Icon $script:pinIconNormal -FallbackText 'P' -TipText 'Pin'
$pinBtn.Left = 314
$pinBtn.Add_Click({
    $form.TopMost = -not $form.TopMost
    Update-PinBtnState
    $script:stateDirty = $true
})
$toolbar.Controls.Add($pinBtn)

# Layout toggle — single button, icon/tooltip swaps between H and V mode
$layoutBtn = Make-TbBtn -Icon $script:horzIconH -FallbackText 'H' -TipText 'Switch to Horizontal'
$layoutBtn.Left = 286
$layoutBtn.Add_Click({
    $newMode = if ($script:layoutMode -eq 'Vertical') { 'Horizontal' } else { 'Vertical' }
    Apply-LayoutMode $newMode
})
$toolbar.Controls.Add($layoutBtn)

# Collapse / Expand
$collapseBtn = Make-TbBtn -Icon $script:collapseIcon -FallbackText 'C' -TipText 'Collapse'
$collapseBtn.Left = 342
$collapseBtn.Add_Click({ Toggle-Collapse })
$toolbar.Controls.Add($collapseBtn)

# Minimize
$minimizeButton = Make-TbBtn -Icon $script:minimizeIcon -FallbackText '_' -TipText 'Minimize'
$minimizeButton.Left = 370
$minimizeButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$toolbar.Controls.Add($minimizeButton)

# Close
$closeButton = Make-TbBtn -Icon $script:closeIcon -FallbackText 'X' -TipText 'Close'
$closeButton.Left = 398
$closeButton.Add_Click({ $form.Close() })
$toolbar.Controls.Add($closeButton)

# Apply initial toggle icon states once controls exist
Update-ImageBtnState
Update-PinBtnState

# $contentHost holds both the vertical scroll layout and the horizontal layout.
# Only one is visible at a time — toggling Visible on each triggers WinForms to
# re-run Dock=Fill layout so the active panel fills the available space.
$contentHost = New-Object System.Windows.Forms.Panel
$contentHost.Dock = 'Fill'
$contentHost.BackColor = $bg
$main.Controls.Add($contentHost, 0, 1)

$scrollHost = New-Object System.Windows.Forms.Panel
$scrollHost.Dock = 'Fill'
$scrollHost.BackColor = $bg
$contentHost.Controls.Add($scrollHost)

$horzContainer = New-Object System.Windows.Forms.Panel
$horzContainer.Dock = 'Fill'
$horzContainer.BackColor = $bg
$horzContainer.Visible = $false
$contentHost.Controls.Add($horzContainer)

$scrollTrack = New-Object System.Windows.Forms.Panel
$scrollTrack.Dock = 'Right'
$scrollTrack.Width = 10
$scrollTrack.BackColor = $scrollTrackBg
$scrollTrack.Visible = $false
$scrollHost.Controls.Add($scrollTrack)

$scrollThumb = New-Object System.Windows.Forms.Panel
$scrollThumb.Left = 1
$scrollThumb.Width = 8
$scrollThumb.Height = 40
$scrollThumb.BackColor = $scrollThumbBg
$scrollTrack.Controls.Add($scrollThumb)

$viewport = New-Object System.Windows.Forms.Panel
$viewport.Dock = 'Fill'
$viewport.BackColor = $bg
$viewport.AutoScroll = $false
$scrollHost.Controls.Add($viewport)
$scrollTrack.BringToFront()

$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Left = 0
$contentPanel.Top = 0
$contentPanel.BackColor = $bg
$viewport.Controls.Add($contentPanel)

$imagePanel = New-Object System.Windows.Forms.Panel
$imagePanel.Left = 4
$imagePanel.Top = 4
$imagePanel.BackColor = $rowBg
$imagePanel.Visible = $false
$imagePanel.Add_Paint({
    param($sender, $eventArgs)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($sender.Width - 1), ($sender.Height - 1)
    $pen = New-Object System.Drawing.Pen -ArgumentList $rowBorder
    try { $eventArgs.Graphics.DrawRectangle($pen, $rect) } finally { $pen.Dispose() }
})
$imageBox = New-Object System.Windows.Forms.PictureBox
$imageBox.Left = 8
$imageBox.Top = 8
$imageBox.BackColor = $rowBg
$imageBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$imageBox.Cursor = [System.Windows.Forms.Cursors]::Hand
$toolTip.SetToolTip($imageBox, 'Double-click to open in viewer')
$imageBox.Add_DoubleClick({
    $f = $script:currentFile
    if ([string]::IsNullOrWhiteSpace($f) -or -not (Test-Path -LiteralPath $f)) { return }
    try {
        if ($null -ne $script:dopusrt) {
            $folder = [System.IO.Path]::GetDirectoryName($f)
            $name   = [System.IO.Path]::GetFileName($f)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName       = $script:dopusrt
            $psi.Arguments      = "/cmd Go `"$folder`" & Select FILE=`"$name`" DESELECTALL & Show"
            $psi.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $psi.CreateNoWindow = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        } else {
            Start-Process -FilePath $f
        }
    } catch { try { Start-Process -FilePath $f } catch {} }
})
$imagePanel.Controls.Add($imageBox)

# Previous / Next nav labels shown below the image when multiple PNGs exist in the folder.
$prevArrow = New-Object System.Windows.Forms.Label
$prevArrow.Text = if ($null -eq $script:prevIcon) { '<' } else { '' }
if ($null -ne $script:prevIcon) { $prevArrow.Image = $script:prevIcon; $prevArrow.ImageAlign = 'MiddleCenter' }
$prevArrow.BackColor = $rowBg
$prevArrow.ForeColor = $muted
$prevArrow.Width = 22
$prevArrow.Height = 22
$prevArrow.Cursor = [System.Windows.Forms.Cursors]::Hand
$prevArrow.Visible = $false
$prevArrow.Add_Click({ Navigate-Image -1 })
$imagePanel.Controls.Add($prevArrow)

$nextArrow = New-Object System.Windows.Forms.Label
$nextArrow.Text = if ($null -eq $script:nextIcon) { '>' } else { '' }
if ($null -ne $script:nextIcon) { $nextArrow.Image = $script:nextIcon; $nextArrow.ImageAlign = 'MiddleCenter' }
$nextArrow.BackColor = $rowBg
$nextArrow.ForeColor = $muted
$nextArrow.Width = 22
$nextArrow.Height = 22
$nextArrow.Cursor = [System.Windows.Forms.Cursors]::Hand
$nextArrow.Visible = $false
$nextArrow.Add_Click({ Navigate-Image 1 })
$imagePanel.Controls.Add($nextArrow)

$imageCounter = New-Object System.Windows.Forms.Label
$imageCounter.Text = ''
$imageCounter.Font = New-Object System.Drawing.Font('Segoe UI', 8.2)
$imageCounter.ForeColor = $muted
$imageCounter.BackColor = $rowBg
$imageCounter.TextAlign = 'MiddleCenter'
$imageCounter.Height = 22
$imageCounter.Visible = $false
$imagePanel.Controls.Add($imageCounter)
$contentPanel.Controls.Add($imagePanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = 'Bottom'
$statusLabel.Height = 18
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.ForeColor = $muted
$statusLabel.BackColor = $bg
$statusLabel.Text = ''
$form.Controls.Add($statusLabel)
$statusLabel.BringToFront()

$resizeGrip = New-Object System.Windows.Forms.Panel
$resizeGrip.Width = 16
$resizeGrip.Height = 16
$resizeGrip.BackColor = $bg
$resizeGrip.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE
$resizeGrip.Anchor = 'Bottom,Right'
$resizeGrip.Left = $form.ClientSize.Width - $resizeGrip.Width - 2
$resizeGrip.Top = $form.ClientSize.Height - $resizeGrip.Height - 2
$resizeGrip.Add_Paint({
    param($sender, $eventArgs)
    $pen = New-Object System.Drawing.Pen -ArgumentList $muted
    try {
        $w = $sender.Width
        $h = $sender.Height
        $eventArgs.Graphics.DrawLine($pen, $w - 4, $h - 12, $w - 12, $h - 4)
        $eventArgs.Graphics.DrawLine($pen, $w - 4, $h - 8, $w - 8, $h - 4)
        $eventArgs.Graphics.DrawLine($pen, $w - 4, $h - 4, $w - 4, $h - 4)
    } finally { $pen.Dispose() }
})
$resizeGrip.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:resizingWindow = $true
        $script:resizeMouseStart = [System.Windows.Forms.Cursor]::Position
        $script:resizeFormStartSize = New-Object System.Drawing.Size -ArgumentList $form.Width, $form.Height
        $resizeGrip.Capture = $true
    }
})
$resizeGrip.Add_MouseMove({
    if ($script:resizingWindow) {
        $pos = [System.Windows.Forms.Cursor]::Position
        $newW = [Math]::Max($form.MinimumSize.Width, $script:resizeFormStartSize.Width + ($pos.X - $script:resizeMouseStart.X))
        $newH = [Math]::Max($form.MinimumSize.Height, $script:resizeFormStartSize.Height + ($pos.Y - $script:resizeMouseStart.Y))
        $form.Width = $newW
        $form.Height = $newH
    }
})
$resizeGrip.Add_MouseUp({
    if ($script:resizingWindow) {
        $script:resizingWindow = $false
        $resizeGrip.Capture = $false
        $script:stateDirty = $true
        $stateSaveTimer.Stop(); $stateSaveTimer.Start()
    }
})
$form.Controls.Add($resizeGrip)
$resizeGrip.BringToFront()
$form.Add_SizeChanged({
    try {
        $resizeGrip.Left = $form.ClientSize.Width - $resizeGrip.Width - 2
        $resizeGrip.Top = $form.ClientSize.Height - $resizeGrip.Height - 2
        $resizeGrip.BringToFront()
        $form.Invalidate()
    } catch {}
})

$valueFont = New-Object System.Drawing.Font -ArgumentList 'Consolas', 8.2
$titleFont = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.2, ([System.Drawing.FontStyle]::Bold)

function Measure-TextBlockHeight {
    param(
        [string]$Text,
        [System.Drawing.Font]$Font,
        [int]$Width
    )
    if ($Width -lt 40) { $Width = 40 }
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $size = New-Object System.Drawing.Size -ArgumentList $Width, 20000
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font, $size, $flags)
    return [Math]::Max(18, $measured.Height + 4)
}

function Get-RowHeight {
    param([string]$Value, [bool]$Large, [int]$TextWidth)
    $textHeight = Measure-TextBlockHeight $Value $valueFont $TextWidth
    $base = $textHeight + 35
    if ($Large) { return [Math]::Max(96, $base) }
    return [Math]::Max(52, $base)
}

function Apply-CustomScroll {
    if ($script:scrollOffset -lt 0) { $script:scrollOffset = 0 }
    if ($script:scrollOffset -gt $script:maxScroll) { $script:scrollOffset = $script:maxScroll }
    $contentPanel.Top = -[int]$script:scrollOffset

    if ($scrollTrack.Visible -and $script:maxScroll -gt 0) {
        $trackH = [Math]::Max(1, $scrollTrack.ClientSize.Height)
        $thumbH = [Math]::Max(32, [int]($trackH * ($viewport.ClientSize.Height / [Math]::Max(1, $script:contentHeight))))
        if ($thumbH -gt $trackH) { $thumbH = $trackH }
        $range = [Math]::Max(1, $trackH - $thumbH)
        $thumbTop = [int](($script:scrollOffset / [Math]::Max(1, $script:maxScroll)) * $range)
        $scrollThumb.Height = $thumbH
        $scrollThumb.Top = $thumbTop
    } else {
        $scrollThumb.Top = 0
    }
}

function Set-CustomScrollOffset {
    param([int]$Offset)
    $script:scrollOffset = $Offset
    Apply-CustomScroll
}

function Scroll-By {
    param([int]$Delta)
    Set-CustomScrollOffset ([int]($script:scrollOffset + $Delta))
}


# ── Horizontal layout ─────────────────────────────────────────────────────────
# 5-column TableLayoutPanel inside $horzContainer.
# Columns: Image | Positive Prompt | Negative Prompt | Info | Sampler

$horzTable = New-Object System.Windows.Forms.TableLayoutPanel
$horzTable.Dock            = 'Fill'
$horzTable.ColumnCount     = 5
$horzTable.RowCount        = 1
$horzTable.BackColor       = $bg
$horzTable.Padding         = New-Object System.Windows.Forms.Padding -ArgumentList 4
$horzTable.CellBorderStyle = [System.Windows.Forms.TableLayoutPanelCellBorderStyle]::None
[void]$horzTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 192)))
[void]$horzTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 32)))
[void]$horzTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 22)))
[void]$horzTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 23)))
[void]$horzTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 23)))
[void]$horzTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$horzContainer.Controls.Add($horzTable)

function New-HorzCol {
    param([string]$Title, [int]$ColIndex)
    $cp = New-Object System.Windows.Forms.Panel
    $cp.Dock = 'Fill'
    $cp.BackColor = $rowBg
    $cp.Margin  = New-Object System.Windows.Forms.Padding -ArgumentList 3, 4, 3, 4
    $cp.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 1  # exposes painted border
    $cp.Add_Paint({
        param($s, $e)
        $r = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($s.Width - 1), ($s.Height - 1)
        $p = New-Object System.Drawing.Pen -ArgumentList $rowBorder
        try { $e.Graphics.DrawRectangle($p, $r) } finally { $p.Dispose() }
    })
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text      = $Title
    $hdr.Dock      = 'Top'
    $hdr.Height    = 24
    $hdr.BackColor = $toolbarBg
    $hdr.ForeColor = $fg
    $hdr.Font      = $titleFont
    $hdr.TextAlign = 'MiddleLeft'
    $hdr.Padding   = New-Object System.Windows.Forms.Padding -ArgumentList 6, 0, 0, 0
    $sc = New-Object System.Windows.Forms.Panel
    $sc.Dock       = 'Fill'
    $sc.BackColor  = $rowBg
    $sc.AutoScroll = $false   # RTB handles its own internal scroll
    $cp.Controls.Add($sc)
    $cp.Controls.Add($hdr)
    $horzTable.Controls.Add($cp, $ColIndex, 0)
    return [pscustomobject]@{ Panel = $cp; Header = $hdr; Scroll = $sc }
}

function New-HorzRtb {
    $r = New-Object System.Windows.Forms.RichTextBox
    $r.Dock        = 'Fill'
    $r.BackColor   = $rowBg
    $r.ForeColor   = $fg
    $r.Font        = $valueFont
    $r.ReadOnly    = $true
    $r.BorderStyle = 'None'
    $r.WordWrap    = $true
    $r.ScrollBars  = 'None'    # custom dark track handles scrolling; this hides the system chrome
    $r.Padding     = New-Object System.Windows.Forms.Padding -ArgumentList 6, 4, 4, 4
    return $r
}

# Column 0 — Image (no AutoScroll; PictureBox Zoom handles everything)
$horzCol0 = New-HorzCol 'Image' 0
$horzCol0.Scroll.AutoScroll = $false

$horzImgPb = New-Object System.Windows.Forms.PictureBox
$horzImgPb.Dock      = 'Fill'
$horzImgPb.BackColor = $rowBg
$horzImgPb.SizeMode  = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$toolTip.SetToolTip($horzImgPb, 'Double-click to open in viewer')
$horzImgPb.Add_DoubleClick({
    $f = $script:currentFile
    if ([string]::IsNullOrWhiteSpace($f) -or -not (Test-Path -LiteralPath $f)) { return }
    try {
        if ($null -ne $script:dopusrt) {
            $folder = [System.IO.Path]::GetDirectoryName($f)
            $name   = [System.IO.Path]::GetFileName($f)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:dopusrt
            $psi.Arguments = "/cmd Go `"$folder`" & Select FILE=`"$name`" DESELECTALL & Show"
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $psi.CreateNoWindow = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        } else { Start-Process -FilePath $f }
    } catch { try { Start-Process -FilePath $f } catch {} }
})
$script:horzImageBox = $horzImgPb

$horzNavBar = New-Object System.Windows.Forms.Panel
$horzNavBar.Dock      = 'Bottom'
$horzNavBar.Height    = 24
$horzNavBar.BackColor = $rowBg
$horzNavBar.Visible   = $false

$horzPrevBtn = New-Object System.Windows.Forms.Label
$horzPrevBtn.Text      = if ($null -eq $script:prevIcon) { '<' } else { '' }
if ($null -ne $script:prevIcon) { $horzPrevBtn.Image = $script:prevIcon; $horzPrevBtn.ImageAlign = 'MiddleCenter' }
$horzPrevBtn.BackColor = $rowBg; $horzPrevBtn.ForeColor = $muted
$horzPrevBtn.Width = 22; $horzPrevBtn.Height = 22; $horzPrevBtn.Top = 1; $horzPrevBtn.Left = 4
$horzPrevBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$horzPrevBtn.Add_Click({ Navigate-Image -1 })
$horzNavBar.Controls.Add($horzPrevBtn)
$script:horzPrevArrow = $horzPrevBtn

$horzNextBtn = New-Object System.Windows.Forms.Label
$horzNextBtn.Text      = if ($null -eq $script:nextIcon) { '>' } else { '' }
if ($null -ne $script:nextIcon) { $horzNextBtn.Image = $script:nextIcon; $horzNextBtn.ImageAlign = 'MiddleCenter' }
$horzNextBtn.BackColor = $rowBg; $horzNextBtn.ForeColor = $muted
$horzNextBtn.Width = 22; $horzNextBtn.Height = 22; $horzNextBtn.Top = 1
$horzNextBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$horzNextBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$horzNextBtn.Add_Click({ Navigate-Image 1 })
$horzNavBar.Controls.Add($horzNextBtn)
$script:horzNextArrow = $horzNextBtn

$horzImgCtr = New-Object System.Windows.Forms.Label
$horzImgCtr.Text = ''; $horzImgCtr.ForeColor = $muted; $horzImgCtr.BackColor = $rowBg
$horzImgCtr.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.2
$horzImgCtr.TextAlign = 'MiddleCenter'
$horzImgCtr.Top = 1; $horzImgCtr.Height = 22
$horzImgCtr.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$horzNavBar.Controls.Add($horzImgCtr)
$script:horzImgCounter = $horzImgCtr

$horzNavBar.Add_SizeChanged({
    $script:horzNextArrow.Left = $horzNavBar.Width - $script:horzNextArrow.Width - 4
    $script:horzImgCounter.Left  = $script:horzPrevArrow.Right + 4
    $script:horzImgCounter.Width = $script:horzNextArrow.Left - $script:horzPrevArrow.Right - 8
})

$horzCol0.Scroll.Controls.Add($horzNavBar)
$horzCol0.Scroll.Controls.Add($horzImgPb)

# Copy button for prompt column headers.
# param($s,$e) is required — $sender is NOT auto-bound in PS WinForms without it.
function Add-HorzCopyBtn {
    param($HeaderPanel, $Rtb)
    $cb = New-Object System.Windows.Forms.Button
    $cb.FlatStyle = 'Flat'
    $cb.ForeColor = $fg
    $cb.BackColor = $copyButtonBg
    $cb.FlatAppearance.BorderSize = 0
    $cb.FlatAppearance.MouseOverBackColor = $copyButtonHoverBg
    $cb.FlatAppearance.MouseDownBackColor = $copyButtonBg
    if ($null -ne $script:copyIcon) {
        $cb.Text = ''; $cb.Image = $script:copyIcon
        $cb.ImageAlign = 'MiddleCenter'
        $cb.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 1
        $toolTip.SetToolTip($cb, 'Copy')
        $cb.Width = 14; $cb.Height = 12
    } else {
        $cb.Text = 'Copy'; $cb.Width = 40; $cb.Height = 18
    }
    $cb.Top    = [int](($HeaderPanel.Height - $cb.Height) / 2)
    $cb.Left   = $HeaderPanel.Width - $cb.Width - 8
    $cb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $cb.Tag    = $Rtb
    $cb.Add_Click({
        param($s, $e)
        $t = $s.Tag.Text
        if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne 'N/A') {
            [System.Windows.Forms.Clipboard]::SetText($t)
            $statusLabel.Text = 'Copied'
            $statusRevertTimer.Stop(); $statusRevertTimer.Start()
        }
    })
    $HeaderPanel.Controls.Add($cb)
}

# Per-field mini row for Info/Sampler columns — same style as vertical-mode rows.
# Returns a model object so the caller can update ValueLabel.Text on image load.
function New-HorzMiniRow {
    param([string]$Label, [System.Windows.Forms.Panel]$Container)

    $rowPanel = New-Object System.Windows.Forms.Panel
    $rowPanel.BackColor = $rowBg
    $rowPanel.Add_Paint({
        param($s, $e)
        $r = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($s.Width - 1), ($s.Height - 1)
        $p = New-Object System.Drawing.Pen -ArgumentList $rowBorder
        try { $e.Graphics.DrawRectangle($p, $r) } finally { $p.Dispose() }
    })

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = $Label
    $titleLbl.ForeColor = $fg
    $titleLbl.BackColor = $rowBg
    $titleLbl.Font      = $titleFont
    $titleLbl.AutoEllipsis = $true
    $titleLbl.TextAlign = 'MiddleLeft'

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.FlatStyle = 'Flat'
    $copyBtn.ForeColor = $fg
    $copyBtn.BackColor = $copyButtonBg
    $copyBtn.FlatAppearance.BorderSize = 0
    $copyBtn.FlatAppearance.MouseOverBackColor = $copyButtonHoverBg
    $copyBtn.FlatAppearance.MouseDownBackColor = $copyButtonBg
    if ($null -ne $script:copyIcon) {
        $copyBtn.Text = ''; $copyBtn.Image = $script:copyIcon
        $copyBtn.ImageAlign = 'MiddleCenter'
        $copyBtn.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 1
        $toolTip.SetToolTip($copyBtn, 'Copy')
        $copyBtn.Width = 14; $copyBtn.Height = 12
    } else {
        $copyBtn.Text = 'Copy'; $copyBtn.Width = 54; $copyBtn.Height = 24
    }

    $valueLbl = New-Object System.Windows.Forms.Label
    $valueLbl.Text      = 'N/A'
    $valueLbl.ForeColor = $fg
    $valueLbl.BackColor = $rowBg
    $valueLbl.Font      = $valueFont
    $valueLbl.AutoSize  = $false
    $valueLbl.TextAlign = 'TopLeft'

    # Tag = the value label so the click handler always reads the current displayed value
    $copyBtn.Tag = $valueLbl
    $copyBtn.Add_Click({
        param($s, $e)
        $t = $s.Tag.Text
        if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne 'N/A') {
            [System.Windows.Forms.Clipboard]::SetText($t)
            $statusLabel.Text = 'Copied'
            $statusRevertTimer.Stop(); $statusRevertTimer.Start()
        }
    })

    $rowPanel.Controls.Add($valueLbl)
    $rowPanel.Controls.Add($titleLbl)
    $rowPanel.Controls.Add($copyBtn)
    $Container.Controls.Add($rowPanel)

    return [pscustomobject]@{ Panel = $rowPanel; Title = $titleLbl; ValueLabel = $valueLbl; CopyButton = $copyBtn }
}

# Positions mini-rows within their column scroll panel (same logic as Layout-MetaRows, scoped to one column).
function Update-HorzMiniThumb {
    param([hashtable]$ScrollObj)
    $so = $ScrollObj
    if ($null -eq $so.Content) { return }
    $so.Content.Top = -[int]$so.Offset
    $needsScroll = $so.MaxScroll -gt 0
    $so.Track.Visible = $needsScroll
    if (-not $needsScroll) { return }
    $trackH = [Math]::Max(1, $so.Track.ClientSize.Height)
    $vh     = [Math]::Max(1, $so.Viewport.ClientSize.Height)
    $ch     = [Math]::Max(1, $so.ContentH)
    $thumbH = [Math]::Max(20, [int]($trackH * ([double]$vh / [double]$ch)))
    if ($thumbH -ge $trackH) { $so.Track.Visible = $false; return }
    $range  = [Math]::Max(1, $trackH - $thumbH)
    $pos    = if ($so.MaxScroll -gt 0) { [int](([double]$so.Offset / [double]$so.MaxScroll) * $range) } else { 0 }
    $so.Thumb.Height = $thumbH
    $so.Thumb.Top    = [Math]::Min($range, [Math]::Max(0, $pos))
}

function Scroll-HorzMini {
    param([hashtable]$ScrollObj, [int]$Delta)
    $ScrollObj.Offset = [Math]::Min($ScrollObj.MaxScroll, [Math]::Max(0, $ScrollObj.Offset + $Delta))
    Update-HorzMiniThumb $ScrollObj
}

function Layout-HorzMiniRows {
    param([hashtable]$ScrollObj, [object[]]$Rows)
    $vp     = $ScrollObj.Viewport
    $ct     = $ScrollObj.Content
    $availW = [Math]::Max(60, $vp.ClientSize.Width - 8)
    $ct.Width = $vp.ClientSize.Width
    $y = 4
    $ct.SuspendLayout()
    foreach ($row in $Rows) {
        $row.Panel.Left  = 4
        $row.Panel.Top   = $y
        $row.Panel.Width = $availW

        $cb = $row.CopyButton
        $cbW = if ($null -ne $script:copyIcon) { 14 } else { 54 }
        $cbH = if ($null -ne $script:copyIcon) { 12 } else { 24 }
        $cb.Width  = $cbW; $cb.Height = $cbH
        $cb.Left   = $availW - $cbW - 8
        $cb.Top    = 7 + [int]((18 - $cbH) / 2)

        $row.Title.Left   = 8
        $row.Title.Top    = 7
        $row.Title.Height = 18
        $row.Title.Width  = [Math]::Max(40, $cb.Left - 14)

        $textW  = [Math]::Max(40, $availW - 16)
        # AutoSize trick: let the label measure itself accurately at the given width,
        # then read the real height. This handles path-separator word breaks that
        # TextRenderer.MeasureText underestimates.
        $row.ValueLabel.MinimumSize = New-Object System.Drawing.Size $textW, 0
        $row.ValueLabel.MaximumSize = New-Object System.Drawing.Size $textW, 0
        $row.ValueLabel.AutoSize    = $true
        $row.ValueLabel.PerformLayout()
        $measuredH = [Math]::Max(18, $row.ValueLabel.Height)
        $row.ValueLabel.AutoSize = $false
        $row.ValueLabel.Left   = 8
        $row.ValueLabel.Top    = 30
        $row.ValueLabel.Width  = $textW
        $row.ValueLabel.Height = $measuredH + 4

        $rowH = [Math]::Max(52, 30 + $row.ValueLabel.Height + 12)
        $row.Panel.Height = $rowH
        $y += $rowH + 6
    }
    $totalH = $y + 4
    $ct.Height = $totalH
    $ScrollObj.ContentH  = $totalH
    $ScrollObj.MaxScroll = [Math]::Max(0, $totalH - $vp.ClientSize.Height)
    if ($ScrollObj.Offset -gt $ScrollObj.MaxScroll) { $ScrollObj.Offset = $ScrollObj.MaxScroll }
    Update-HorzMiniThumb $ScrollObj
    $ct.ResumeLayout()
}

# ── Custom scroll helpers for prompt RichTextBoxes ────────────────────────────
# These replace the system scrollbar (ScrollBars='None' on RTB) with the same
# dark custom track used in vertical mode.

function Get-RtbScrollInfo {
    param($Rtb)
    if (-not $Rtb.IsHandleCreated -or $Rtb.ClientSize.Height -le 0 -or $Rtb.TextLength -eq 0) {
        return @{ First=0; Total=1; Visible=1; Scrollable=$false }
    }
    try {
        $firstLine  = $Rtb.GetLineFromCharIndex($Rtb.GetCharIndexFromPosition([System.Drawing.Point]::Empty))
        $totalLines = [Math]::Max(1, $Rtb.GetLineFromCharIndex($Rtb.TextLength) + 1)
        $lineH      = [Math]::Max(1, [System.Windows.Forms.TextRenderer]::MeasureText('Wy', $Rtb.Font).Height)
        $visLines   = [Math]::Max(1, [int]($Rtb.ClientSize.Height / $lineH))
        return @{ First=$firstLine; Total=$totalLines; Visible=$visLines; Scrollable=($totalLines -gt $visLines) }
    } catch {
        return @{ First=0; Total=1; Visible=1; Scrollable=$false }
    }
}

function Update-RtbThumb {
    param($Rtb, $Track, $Thumb)
    $info = Get-RtbScrollInfo $Rtb
    $Track.Visible = $info.Scrollable
    if (-not $info.Scrollable) { return }
    $trackH    = [Math]::Max(1, $Track.ClientSize.Height)
    $scrollable = $info.Total - $info.Visible
    $ratio     = [double]$info.Visible / [double]$info.Total
    $thumbH    = [Math]::Max(20, [int]($trackH * $ratio))
    if ($thumbH -ge $trackH) { $Track.Visible = $false; return }
    $range = [Math]::Max(1, $trackH - $thumbH)
    $pos   = if ($scrollable -gt 0) { [int](([double]$info.First / $scrollable) * $range) } else { 0 }
    $Thumb.Height = $thumbH
    $Thumb.Top    = [Math]::Min($range, [Math]::Max(0, $pos))
}

# EM_LINESCROLL (0x00B6): positive = scroll down N lines, negative = scroll up.
function Scroll-RtbLines {
    param($Rtb, [int]$Lines, $Track, $Thumb)
    [void][Win32]::SendMessage($Rtb.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]$Lines)
    Update-RtbThumb $Rtb $Track $Thumb
}

# ── End custom scroll helpers ─────────────────────────────────────────────────

# Columns 1-2: prompt RichTextBoxes with header copy button
$horzCol1 = New-HorzCol 'Positive Prompt' 1
$horzPosRtb = New-HorzRtb
$script:horzPosRtb = $horzPosRtb

$posTrack = New-Object System.Windows.Forms.Panel
$posTrack.Dock = 'Right'; $posTrack.Width = 10; $posTrack.BackColor = $scrollTrackBg; $posTrack.Visible = $false
$posThumb = New-Object System.Windows.Forms.Panel
$posThumb.Left = 1; $posThumb.Width = 8; $posThumb.Height = 40; $posThumb.BackColor = $scrollThumbBg
$posTrack.Controls.Add($posThumb)
$horzCol1.Scroll.Controls.Add($posTrack)
$horzCol1.Scroll.Controls.Add($horzPosRtb)
$posTrack.BringToFront()
Add-HorzCopyBtn $horzCol1.Header $horzPosRtb

$posThumb.Add_MouseEnter({ $posThumb.BackColor = $scrollThumbHoverBg })
$posThumb.Add_MouseLeave({ if (-not $script:horzPosDragging) { $posThumb.BackColor = $scrollThumbBg } })
$posThumb.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:horzPosDragging = $true
        $script:horzPosDragY    = [System.Windows.Forms.Cursor]::Position.Y
        $script:horzPosDragLine = (Get-RtbScrollInfo $horzPosRtb).First
        $posThumb.Capture = $true; $posThumb.BackColor = $scrollThumbHoverBg
    }
})
$posThumb.Add_MouseMove({
    if (-not $script:horzPosDragging) { return }
    $info = Get-RtbScrollInfo $horzPosRtb
    $scrollable = [Math]::Max(1, $info.Total - $info.Visible)
    $range  = [Math]::Max(1, $posTrack.ClientSize.Height - $posThumb.Height)
    $dy     = [System.Windows.Forms.Cursor]::Position.Y - $script:horzPosDragY
    $target = $script:horzPosDragLine + [int](($dy / $range) * $scrollable)
    $delta  = $target - $info.First
    if ($delta -ne 0) { [void][Win32]::SendMessage($horzPosRtb.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]$delta) }
    Update-RtbThumb $horzPosRtb $posTrack $posThumb
})
$posThumb.Add_MouseUp({
    if ($script:horzPosDragging) { $script:horzPosDragging = $false; $posThumb.Capture = $false; $posThumb.BackColor = $scrollThumbBg }
})
$horzPosRtb.Add_MouseWheel({
    param($s, $e)
    $lines = [Math]::Max(1, [int](3 * [Math]::Abs($e.Delta) / 120))
    $dir = if ($e.Delta -lt 0) { $lines } else { -$lines }
    Scroll-RtbLines $horzPosRtb $dir $posTrack $posThumb
})
$horzPosRtb.Add_KeyUp({ Update-RtbThumb $horzPosRtb $posTrack $posThumb })
$horzCol1.Scroll.Add_SizeChanged({ Update-RtbThumb $horzPosRtb $posTrack $posThumb })

$horzCol2 = New-HorzCol 'Negative Prompt' 2
$horzNegRtb = New-HorzRtb
$script:horzNegRtb = $horzNegRtb

$negTrack = New-Object System.Windows.Forms.Panel
$negTrack.Dock = 'Right'; $negTrack.Width = 10; $negTrack.BackColor = $scrollTrackBg; $negTrack.Visible = $false
$negThumb = New-Object System.Windows.Forms.Panel
$negThumb.Left = 1; $negThumb.Width = 8; $negThumb.Height = 40; $negThumb.BackColor = $scrollThumbBg
$negTrack.Controls.Add($negThumb)
$horzCol2.Scroll.Controls.Add($negTrack)
$horzCol2.Scroll.Controls.Add($horzNegRtb)
$negTrack.BringToFront()
Add-HorzCopyBtn $horzCol2.Header $horzNegRtb

$negThumb.Add_MouseEnter({ $negThumb.BackColor = $scrollThumbHoverBg })
$negThumb.Add_MouseLeave({ if (-not $script:horzNegDragging) { $negThumb.BackColor = $scrollThumbBg } })
$negThumb.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:horzNegDragging = $true
        $script:horzNegDragY    = [System.Windows.Forms.Cursor]::Position.Y
        $script:horzNegDragLine = (Get-RtbScrollInfo $horzNegRtb).First
        $negThumb.Capture = $true; $negThumb.BackColor = $scrollThumbHoverBg
    }
})
$negThumb.Add_MouseMove({
    if (-not $script:horzNegDragging) { return }
    $info = Get-RtbScrollInfo $horzNegRtb
    $scrollable = [Math]::Max(1, $info.Total - $info.Visible)
    $range  = [Math]::Max(1, $negTrack.ClientSize.Height - $negThumb.Height)
    $dy     = [System.Windows.Forms.Cursor]::Position.Y - $script:horzNegDragY
    $target = $script:horzNegDragLine + [int](($dy / $range) * $scrollable)
    $delta  = $target - $info.First
    if ($delta -ne 0) { [void][Win32]::SendMessage($horzNegRtb.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr]$delta) }
    Update-RtbThumb $horzNegRtb $negTrack $negThumb
})
$negThumb.Add_MouseUp({
    if ($script:horzNegDragging) { $script:horzNegDragging = $false; $negThumb.Capture = $false; $negThumb.BackColor = $scrollThumbBg }
})
$horzNegRtb.Add_MouseWheel({
    param($s, $e)
    $lines = [Math]::Max(1, [int](3 * [Math]::Abs($e.Delta) / 120))
    $dir = if ($e.Delta -lt 0) { $lines } else { -$lines }
    Scroll-RtbLines $horzNegRtb $dir $negTrack $negThumb
})
$horzNegRtb.Add_KeyUp({ Update-RtbThumb $horzNegRtb $negTrack $negThumb })
$horzCol2.Scroll.Add_SizeChanged({ Update-RtbThumb $horzNegRtb $negTrack $negThumb })

# Column 3: Info — pre-built mini-rows with custom dark scroll track
$horzCol3 = New-HorzCol 'Info' 3

$infoTrack = New-Object System.Windows.Forms.Panel
$infoTrack.Dock = 'Right'; $infoTrack.Width = 10; $infoTrack.BackColor = $scrollTrackBg; $infoTrack.Visible = $false
$infoThumb = New-Object System.Windows.Forms.Panel
$infoThumb.Left = 1; $infoThumb.Width = 8; $infoThumb.Height = 40; $infoThumb.BackColor = $scrollThumbBg
$infoTrack.Controls.Add($infoThumb)
$horzCol3.Scroll.Controls.Add($infoTrack)

$infoViewport = New-Object System.Windows.Forms.Panel
$infoViewport.Dock = 'Fill'; $infoViewport.BackColor = $rowBg
$horzCol3.Scroll.Controls.Add($infoViewport)
$infoTrack.BringToFront()

$infoContent = New-Object System.Windows.Forms.Panel
$infoContent.Left = 0; $infoContent.Top = 0; $infoContent.BackColor = $rowBg
$infoViewport.Controls.Add($infoContent)

$script:horzInfoScroll.Track = $infoTrack; $script:horzInfoScroll.Thumb = $infoThumb
$script:horzInfoScroll.Viewport = $infoViewport; $script:horzInfoScroll.Content = $infoContent

[void]$script:horzInfoRows.Add((New-HorzMiniRow 'Seed'         $infoContent))
[void]$script:horzInfoRows.Add((New-HorzMiniRow 'Resolution'   $infoContent))
[void]$script:horzInfoRows.Add((New-HorzMiniRow 'Model'        $infoContent))
[void]$script:horzInfoRows.Add((New-HorzMiniRow 'Text Encoder' $infoContent))

$infoThumb.Add_MouseEnter({ $infoThumb.BackColor = $scrollThumbHoverBg })
$infoThumb.Add_MouseLeave({ if (-not $script:horzInfoScroll.Dragging) { $infoThumb.BackColor = $scrollThumbBg } })
$infoThumb.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:horzInfoScroll.Dragging   = $true
        $script:horzInfoScroll.DragY      = [System.Windows.Forms.Cursor]::Position.Y
        $script:horzInfoScroll.DragOffset = $script:horzInfoScroll.Offset
        $infoThumb.Capture = $true; $infoThumb.BackColor = $scrollThumbHoverBg
    }
})
$infoThumb.Add_MouseMove({
    if (-not $script:horzInfoScroll.Dragging) { return }
    $range = [Math]::Max(1, $infoTrack.ClientSize.Height - $infoThumb.Height)
    $dy    = [System.Windows.Forms.Cursor]::Position.Y - $script:horzInfoScroll.DragY
    $script:horzInfoScroll.Offset = [Math]::Min($script:horzInfoScroll.MaxScroll, [Math]::Max(0,
        $script:horzInfoScroll.DragOffset + [int](($dy / $range) * [Math]::Max(1, $script:horzInfoScroll.MaxScroll))))
    Update-HorzMiniThumb $script:horzInfoScroll
})
$infoThumb.Add_MouseUp({
    if ($script:horzInfoScroll.Dragging) { $script:horzInfoScroll.Dragging = $false; $infoThumb.Capture = $false; $infoThumb.BackColor = $scrollThumbBg }
})
$infoViewport.Add_MouseWheel({
    param($s, $e); $delta = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $script:horzInfoScroll $delta
})
$infoContent.Add_MouseWheel({
    param($s, $e); $delta = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $script:horzInfoScroll $delta
})
foreach ($row in $script:horzInfoRows) {
    $row.Panel.Tag = $script:horzInfoScroll
    $row.Panel.Add_MouseWheel({ param($s,$e); $d = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $s.Tag $d })
    $row.ValueLabel.Tag = $script:horzInfoScroll
    $row.ValueLabel.Add_MouseWheel({ param($s,$e); $d = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $s.Tag $d })
}
$horzCol3.Scroll.Add_SizeChanged({ Layout-HorzMiniRows $script:horzInfoScroll $script:horzInfoRows.ToArray() })

# Column 4: Sampler — pre-built mini-rows with custom dark scroll track
$horzCol4 = New-HorzCol 'Sampler' 4

$sampTrack = New-Object System.Windows.Forms.Panel
$sampTrack.Dock = 'Right'; $sampTrack.Width = 10; $sampTrack.BackColor = $scrollTrackBg; $sampTrack.Visible = $false
$sampThumb = New-Object System.Windows.Forms.Panel
$sampThumb.Left = 1; $sampThumb.Width = 8; $sampThumb.Height = 40; $sampThumb.BackColor = $scrollThumbBg
$sampTrack.Controls.Add($sampThumb)
$horzCol4.Scroll.Controls.Add($sampTrack)

$sampViewport = New-Object System.Windows.Forms.Panel
$sampViewport.Dock = 'Fill'; $sampViewport.BackColor = $rowBg
$horzCol4.Scroll.Controls.Add($sampViewport)
$sampTrack.BringToFront()

$sampContent = New-Object System.Windows.Forms.Panel
$sampContent.Left = 0; $sampContent.Top = 0; $sampContent.BackColor = $rowBg
$sampViewport.Controls.Add($sampContent)

$script:horzSampScroll.Track = $sampTrack; $script:horzSampScroll.Thumb = $sampThumb
$script:horzSampScroll.Viewport = $sampViewport; $script:horzSampScroll.Content = $sampContent

[void]$script:horzSampRows.Add((New-HorzMiniRow "LoRA's"    $sampContent))
[void]$script:horzSampRows.Add((New-HorzMiniRow 'Sampler'   $sampContent))
[void]$script:horzSampRows.Add((New-HorzMiniRow 'Scheduler' $sampContent))
[void]$script:horzSampRows.Add((New-HorzMiniRow 'Steps'     $sampContent))
[void]$script:horzSampRows.Add((New-HorzMiniRow 'CFG'       $sampContent))

$sampThumb.Add_MouseEnter({ $sampThumb.BackColor = $scrollThumbHoverBg })
$sampThumb.Add_MouseLeave({ if (-not $script:horzSampScroll.Dragging) { $sampThumb.BackColor = $scrollThumbBg } })
$sampThumb.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:horzSampScroll.Dragging   = $true
        $script:horzSampScroll.DragY      = [System.Windows.Forms.Cursor]::Position.Y
        $script:horzSampScroll.DragOffset = $script:horzSampScroll.Offset
        $sampThumb.Capture = $true; $sampThumb.BackColor = $scrollThumbHoverBg
    }
})
$sampThumb.Add_MouseMove({
    if (-not $script:horzSampScroll.Dragging) { return }
    $range = [Math]::Max(1, $sampTrack.ClientSize.Height - $sampThumb.Height)
    $dy    = [System.Windows.Forms.Cursor]::Position.Y - $script:horzSampScroll.DragY
    $script:horzSampScroll.Offset = [Math]::Min($script:horzSampScroll.MaxScroll, [Math]::Max(0,
        $script:horzSampScroll.DragOffset + [int](($dy / $range) * [Math]::Max(1, $script:horzSampScroll.MaxScroll))))
    Update-HorzMiniThumb $script:horzSampScroll
})
$sampThumb.Add_MouseUp({
    if ($script:horzSampScroll.Dragging) { $script:horzSampScroll.Dragging = $false; $sampThumb.Capture = $false; $sampThumb.BackColor = $scrollThumbBg }
})
$sampViewport.Add_MouseWheel({
    param($s, $e); $delta = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $script:horzSampScroll $delta
})
$sampContent.Add_MouseWheel({
    param($s, $e); $delta = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $script:horzSampScroll $delta
})
foreach ($row in $script:horzSampRows) {
    $row.Panel.Tag = $script:horzSampScroll
    $row.Panel.Add_MouseWheel({ param($s,$e); $d = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $s.Tag $d })
    $row.ValueLabel.Tag = $script:horzSampScroll
    $row.ValueLabel.Add_MouseWheel({ param($s,$e); $d = if ($e.Delta -lt 0) { 72 } else { -72 }; Scroll-HorzMini $s.Tag $d })
}
$horzCol4.Scroll.Add_SizeChanged({ Layout-HorzMiniRows $script:horzSampScroll $script:horzSampRows.ToArray() })

function Update-HorzNavBar {
    $show = $script:siblingPngs.Count -gt 1
    $script:horzPrevArrow.Visible  = $show
    $script:horzNextArrow.Visible  = $show
    $script:horzImgCounter.Visible = $show
    $horzNavBar.Visible = $show
    $horzNavBar.Height  = if ($show) { 24 } else { 0 }
    if ($show) {
        $cnt = if ($script:siblingIndex -ge 0) { "$($script:siblingIndex + 1) / $($script:siblingPngs.Count)" } else { "? / $($script:siblingPngs.Count)" }
        $script:horzImgCounter.Text = $cnt
    }
}

function Apply-LayoutMode {
    param([string]$Mode)
    if ($Mode -eq $script:layoutMode) { return }

    # Remember the vertical-mode window size before switching away from it
    if ($script:layoutMode -eq 'Vertical') {
        $script:vertWidth  = $form.Width
        $script:vertHeight = $form.Height
    }

    $script:layoutMode = $Mode

    if ($Mode -eq 'Horizontal') {
        $scrollHost.Visible    = $false
        $horzContainer.Visible = $true
        if ($null -ne $script:horzIconV) { $layoutBtn.Image = $script:horzIconV; $layoutBtn.Text = '' }
        else { $layoutBtn.Image = $null; $layoutBtn.Text = 'V' }
        $toolTip.SetToolTip($layoutBtn, 'Switch to Vertical')
        $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 640, 280
        # Default to a wide layout if the window is too narrow for 5 columns
        if ($form.Width -lt 900) { $form.Width = 1100; $form.Height = 430 }
    } else {
        $scrollHost.Visible    = $true
        $horzContainer.Visible = $false
        if ($null -ne $script:horzIconH) { $layoutBtn.Image = $script:horzIconH; $layoutBtn.Text = '' }
        else { $layoutBtn.Image = $null; $layoutBtn.Text = 'H' }
        $toolTip.SetToolTip($layoutBtn, 'Switch to Horizontal')
        $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 300, 420
        if ($script:vertWidth -gt 0) { $form.Width = $script:vertWidth; $form.Height = $script:vertHeight }
        else { $form.Width = 430; $form.Height = 760 }
    }

    $script:stateDirty = $true
    $stateSaveTimer.Stop(); $stateSaveTimer.Start()
    if (-not [string]::IsNullOrWhiteSpace($script:currentFile)) { Load-FileIntoPanel $script:currentFile }
}

# ── End horizontal layout setup ───────────────────────────────────────────────

function Layout-MetaRows {
    if ($script:layoutMode -eq 'Horizontal') { return }
    $availableWidth = [Math]::Max(265, $viewport.ClientSize.Width - 8)
    $contentPanel.SuspendLayout()
    $y = 4

    if ($script:showImage -and $null -ne $script:currentImage) {
        $imagePanel.Visible = $true
        $imagePanel.Left = 4
        $imagePanel.Top = $y
        $imagePanel.Width = $availableWidth
        $boxWidth = [Math]::Max(80, $imagePanel.Width - 16)
        $imageHeight = [int]($boxWidth / [Math]::Max(0.05, $script:imageAspect))
        $imageHeight = [Math]::Min(420, [Math]::Max(90, $imageHeight))
        $imageBox.Left = 8
        $imageBox.Top = 8
        $imageBox.Width = $boxWidth
        $imageBox.Height = $imageHeight

        # Navigation bar below the image — only when the folder has more than one PNG.
        $showNav = $script:siblingPngs.Count -gt 1
        $navH = if ($showNav) { 20 } else { 0 }
        $imagePanel.Height = $imageHeight + 16 + $navH

        if ($showNav) {
            $navTop = $imageHeight + 11
            $prevArrow.Left    = 8
            $prevArrow.Top     = $navTop
            $prevArrow.Visible = $true
            $nextArrow.Left    = $imagePanel.Width - $nextArrow.Width - 8
            $nextArrow.Top     = $navTop
            $nextArrow.Visible = $true
            $imageCounter.Left    = $prevArrow.Right + 4
            $imageCounter.Width   = $nextArrow.Left - $prevArrow.Right - 8
            $imageCounter.Top     = $navTop
            $cnt = if ($script:siblingIndex -ge 0) { "$($script:siblingIndex + 1) / $($script:siblingPngs.Count)" } else { "? / $($script:siblingPngs.Count)" }
            $imageCounter.Text    = $cnt
            $imageCounter.Visible = $true
        } else {
            $prevArrow.Visible    = $false
            $nextArrow.Visible    = $false
            $imageCounter.Visible = $false
        }

        $y += $imagePanel.Height + 6
    } else {
        $imagePanel.Visible = $false
        $imagePanel.Height = 0
        $imagePanel.Top = -5000
        $prevArrow.Visible    = $false
        $nextArrow.Visible    = $false
        $imageCounter.Visible = $false
    }

    foreach ($row in $script:rowModels) {
        $rowPanel = $row.Panel
        $title = $row.Title
        $valueLabel = $row.ValueLabel
        $copyButton = $row.CopyButton
        $value = [string]$row.Value
        $large = [bool]$row.Large

        $rowPanel.Left = 4
        $rowPanel.Top = $y
        $rowPanel.Width = $availableWidth

        $copyButton.Width = if ($null -ne $script:copyIcon) { 14 } else { 54 }
        $copyButton.Height = if ($null -ne $script:copyIcon) { 12 } else { 24 }
        $copyButton.Left = $rowPanel.Width - $copyButton.Width - 8
        $copyButton.Top = $title.Top + [int](($title.Height - $copyButton.Height) / 2)

        $title.Left = 8
        $title.Top = 7
        $title.Width = [Math]::Max(70, $copyButton.Left - 14)
        $title.Height = 18

        $textLeft = 8
        $textTop = 30
        $textWidth = [Math]::Max(60, $rowPanel.Width - 16)
        $rowHeight = Get-RowHeight $value $large $textWidth
        $valueLabel.Left = $textLeft
        $valueLabel.Top = $textTop
        $valueLabel.Width = $textWidth
        $valueLabel.Height = [Math]::Max(18, $rowHeight - $textTop - 8)

        $rowPanel.Height = $rowHeight
        $y += $rowPanel.Height + 6
    }
    $script:contentHeight = $y + 4
    $contentPanel.Width = $availableWidth + 8
    $contentPanel.Height = [Math]::Max($script:contentHeight, $viewport.ClientSize.Height)
    $script:maxScroll = [Math]::Max(0, $script:contentHeight - $viewport.ClientSize.Height)
    $scrollTrack.Visible = ($script:maxScroll -gt 0)
    Apply-CustomScroll
    $contentPanel.ResumeLayout()
}

function Attach-WheelHandler {
    param([System.Windows.Forms.Control]$Control)
    $Control.Add_MouseWheel({
        param($sender, $eventArgs)
        $amount = if ($eventArgs.Delta -lt 0) { 72 } else { -72 }
        Scroll-By $amount
    })
}

Attach-WheelHandler $viewport
Attach-WheelHandler $contentPanel
Attach-WheelHandler $imagePanel
Attach-WheelHandler $imageBox
Attach-WheelHandler $prevArrow
Attach-WheelHandler $nextArrow
Attach-WheelHandler $imageCounter

function Add-MetaRow {
    param(
        [string]$Label,
        [string]$Value,
        [bool]$Large
    )
    $Value = Display-Value $Value

    $rowPanel = New-Object System.Windows.Forms.Panel
    $rowPanel.BackColor = $rowBg
    $rowPanel.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
    $rowPanel.Tag = $Value
    $rowPanel.Add_Paint({
        param($sender, $eventArgs)
        $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($sender.Width - 1), ($sender.Height - 1)
        $pen = New-Object System.Drawing.Pen -ArgumentList $rowBorder
        try { $eventArgs.Graphics.DrawRectangle($pen, $rect) } finally { $pen.Dispose() }
    })

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Label
    $title.ForeColor = $fg
    $title.BackColor = $rowBg
    $title.Font = $titleFont
    $title.AutoEllipsis = $true
    $title.TextAlign = 'MiddleLeft'

    $copy = New-Object System.Windows.Forms.Button
    $copy.FlatStyle = 'Flat'
    $copy.ForeColor = $fg
    $copy.BackColor = $copyButtonBg
    $copy.FlatAppearance.BorderSize = 0
    $copy.FlatAppearance.MouseOverBackColor = $copyButtonHoverBg
    $copy.FlatAppearance.MouseDownBackColor = $copyButtonBg
    if ($null -ne $script:copyIcon) {
        $copy.Text = ''
        $copy.Image = $script:copyIcon
        $copy.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $copy.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 1
        $toolTip.SetToolTip($copy, 'Copy')
    } else {
        $copy.Text = 'Copy'
    }
    $copy.Tag = [pscustomobject]@{ Value = $Value; Label = $Label }
    $copy.Add_Click({
        param($sender, $eventArgs)
        $info = $sender.Tag
        $t = [string]$info.Value
        if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne 'N/A') {
            [System.Windows.Forms.Clipboard]::SetText($t)
            $statusLabel.Text = 'Copied: ' + [string]$info.Label
            $statusRevertTimer.Stop()
            $statusRevertTimer.Start()
        }
    })

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = $Value
    $valueLabel.ForeColor = $fg
    $valueLabel.BackColor = $rowBg
    $valueLabel.Font = $valueFont
    $valueLabel.AutoSize = $false
    $valueLabel.UseMnemonic = $false
    $valueLabel.TextAlign = 'TopLeft'
    $valueLabel.Tag = [pscustomobject]@{ Value = $Value; Label = $Label }
    $valueLabel.Add_DoubleClick({
        param($sender, $eventArgs)
        $info = $sender.Tag
        $t = [string]$info.Value
        if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne 'N/A') {
            [System.Windows.Forms.Clipboard]::SetText($t)
            $statusLabel.Text = 'Copied: ' + [string]$info.Label
            $statusRevertTimer.Stop()
            $statusRevertTimer.Start()
        }
    })

    Attach-WheelHandler $rowPanel
    Attach-WheelHandler $title
    Attach-WheelHandler $copy
    Attach-WheelHandler $valueLabel

    $rowPanel.Controls.Add($valueLabel)
    $rowPanel.Controls.Add($title)
    $rowPanel.Controls.Add($copy)
    $contentPanel.Controls.Add($rowPanel)

    [void]$script:rowModels.Add([pscustomobject]@{
        Panel = $rowPanel
        Title = $title
        ValueLabel = $valueLabel
        CopyButton = $copy
        Value = $Value
        Large = $Large
    })
}

function Clear-MetaRows {
    $contentPanel.SuspendLayout()
    foreach ($row in $script:rowModels) {
        try { $contentPanel.Controls.Remove($row.Panel) } catch {}
        try { $row.Panel.Dispose() } catch {}
    }
    $script:rowModels.Clear()
    $script:scrollOffset = 0
    $contentPanel.ResumeLayout()
}

function Update-SiblingList {
    param([string]$FilePath)
    try {
        $dir = [System.IO.Path]::GetDirectoryName($FilePath)
        if ([string]::IsNullOrWhiteSpace($dir)) { $script:siblingPngs = @(); $script:siblingIndex = -1; return }
        # Only re-scan disk when the folder changes; just update index within the same folder.
        if ($script:siblingPngs.Count -gt 0) {
            $existingDir = [System.IO.Path]::GetDirectoryName($script:siblingPngs[0])
            if ($dir -ieq $existingDir) {
                $script:siblingIndex = [Array]::IndexOf($script:siblingPngs, $FilePath)
                return
            }
        }
        $pngs = @(Get-ChildItem -LiteralPath $dir -Filter '*.png' -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
        $script:siblingPngs  = $pngs
        $script:siblingIndex = [Array]::IndexOf($pngs, $FilePath)
    } catch {
        $script:siblingPngs  = @()
        $script:siblingIndex = -1
    }
}

function Navigate-Image {
    param([int]$Direction)
    if ($script:siblingPngs.Count -lt 2) { return }
    $newIdx = $script:siblingIndex + $Direction
    if ($newIdx -lt 0)                         { $newIdx = $script:siblingPngs.Count - 1 }
    if ($newIdx -ge $script:siblingPngs.Count) { $newIdx = 0 }
    Load-FileIntoPanel $script:siblingPngs[$newIdx]
}

function Load-FileIntoPanel {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return }
    if (-not (Test-Path -LiteralPath $FilePath)) { return }

    $script:currentFile = $FilePath
    Update-SiblingList $FilePath
    Set-PanelImage $FilePath
    if ($null -ne $imagePanel) { $imagePanel.Visible = ($script:showImage -and $null -ne $script:currentImage) }
    $statusLabel.Text = 'Reading metadata...'
    [System.Windows.Forms.Application]::DoEvents()

    Clear-MetaRows
    try {
        $meta = Get-ComfyMetaJson $FilePath
        $script:lastMetaText = ConvertTo-PlainRows $meta

        if ($script:layoutMode -eq 'Horizontal') {
            # ── Horizontal path ──────────────────────────────────────────────
            # Image is already set by Set-PanelImage above
            Update-HorzNavBar

            $script:horzPosRtb.Text = Display-Value ([string]$meta.PositivePrompt)
            [void][Win32]::SendMessage($script:horzPosRtb.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr](-99999))
            Update-RtbThumb $script:horzPosRtb $posTrack $posThumb

            $negText = [string]$meta.NegativePrompt
            $hasNeg  = -not [string]::IsNullOrWhiteSpace($negText)
            if ($hasNeg) {
                $script:horzNegRtb.Text = $negText
                $horzCol2.Panel.Visible = $true
                $horzTable.ColumnStyles[2].SizeType = [System.Windows.Forms.SizeType]::Percent
                $horzTable.ColumnStyles[2].Width    = 22
                [void][Win32]::SendMessage($script:horzNegRtb.Handle, 0x00B6, [IntPtr]::Zero, [IntPtr](-99999))
                Update-RtbThumb $script:horzNegRtb $negTrack $negThumb
            } else {
                $script:horzNegRtb.Text = ''
                $horzCol2.Panel.Visible = $false
                $horzTable.ColumnStyles[2].SizeType = [System.Windows.Forms.SizeType]::Absolute
                $horzTable.ColumnStyles[2].Width    = 0
            }

            # Info column — update each mini-row's value label then re-layout
            $script:horzInfoRows[0].ValueLabel.Text = Display-Value ([string]$meta.Seed)
            $script:horzInfoRows[1].ValueLabel.Text = Display-Value ([string]$meta.Resolution)
            $script:horzInfoRows[2].ValueLabel.Text = Display-Value ([string]$meta.Model)
            $script:horzInfoRows[3].ValueLabel.Text = Display-Value ([string]$meta.TextEncoder)
            Layout-HorzMiniRows $script:horzInfoScroll $script:horzInfoRows.ToArray()

            # Sampler column — same pattern
            $script:horzSampRows[0].ValueLabel.Text = Display-Value ([string]$meta.LoRAs)
            $script:horzSampRows[1].ValueLabel.Text = Display-Value ([string]$meta.Sampler)
            $script:horzSampRows[2].ValueLabel.Text = Display-Value ([string]$meta.Scheduler)
            $script:horzSampRows[3].ValueLabel.Text = Display-Value ([string]$meta.Steps)
            $script:horzSampRows[4].ValueLabel.Text = Display-Value ([string]$meta.CFG)
            Layout-HorzMiniRows $script:horzSampScroll $script:horzSampRows.ToArray()
        } else {
            # ── Vertical path (original) ─────────────────────────────────────
            Add-MetaRow 'Positive Prompt' ([string]$meta.PositivePrompt) $true

            $rawNeg = [string]$meta.NegativePrompt
            if (-not [string]::IsNullOrWhiteSpace($rawNeg)) { Add-MetaRow 'Negative Prompt' $rawNeg $true }

            Add-MetaRow 'Seed' ([string]$meta.Seed) $false
            Add-MetaRow 'Resolution' ([string]$meta.Resolution) $false

            $rawLoras = [string]$meta.LoRAs
            if (-not [string]::IsNullOrWhiteSpace($rawLoras)) { Add-MetaRow "LoRA's" $rawLoras $false }

            Add-MetaRow 'Model' ([string]$meta.Model) $false

            $rawEnc = [string]$meta.TextEncoder
            if (-not [string]::IsNullOrWhiteSpace($rawEnc)) { Add-MetaRow 'Text Encoder' $rawEnc $false }

            Add-MetaRow 'Sampler' ([string]$meta.Sampler) $false
            Add-MetaRow 'Scheduler' ([string]$meta.Scheduler) $false
            Add-MetaRow 'Steps' ([string]$meta.Steps) $false
            Add-MetaRow 'CFG' ([string]$meta.CFG) $false
            Layout-MetaRows
        }

        $script:loadedStatusText = 'Loaded: ' + (Get-Date).ToString('HH:mm:ss')
        $statusLabel.Text = $script:loadedStatusText
        Update-ImageBtnState
    } catch {
        if ($script:layoutMode -eq 'Horizontal') {
            $script:horzPosRtb.Text = 'Error: ' + $_.Exception.Message
            $script:horzNegRtb.Text = ''
            foreach ($row in ($script:horzInfoRows + $script:horzSampRows)) { $row.ValueLabel.Text = 'N/A' }
        } else {
            Add-MetaRow 'Error' $_.Exception.Message $true
            Layout-MetaRows
        }
        $script:lastMetaText = 'Error: ' + $_.Exception.Message
        $statusLabel.Text = 'Error reading metadata'
    }
}

function Begin-PanelDrag {
    param($eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:draggingWindow = $true
    $script:dragMouseStart = [System.Windows.Forms.Cursor]::Position
    $script:dragFormStart = New-Object System.Drawing.Point -ArgumentList $form.Left, $form.Top
}

function Move-PanelDrag {
    if (-not $script:draggingWindow) { return }
    $pos = [System.Windows.Forms.Cursor]::Position
    $form.Left = $script:dragFormStart.X + ($pos.X - $script:dragMouseStart.X)
    $form.Top = $script:dragFormStart.Y + ($pos.Y - $script:dragMouseStart.Y)
}

function End-PanelDrag {
    if ($script:draggingWindow) {
        $script:draggingWindow = $false
        $script:stateDirty = $true
        $stateSaveTimer.Stop(); $stateSaveTimer.Start()
    }
}

$toolbar.Add_MouseDown({ param($sender, $eventArgs) Begin-PanelDrag $eventArgs })
$toolbar.Add_MouseMove({ Move-PanelDrag })
$toolbar.Add_MouseUp({ End-PanelDrag })

$toolbar.Add_SizeChanged({
    try {
        $openBtn.Left        = 8
        $aboutBtn.Left       = $openBtn.Right + 4
        $closeButton.Left    = [Math]::Max($aboutBtn.Right + 4, $toolbar.ClientSize.Width - $closeButton.Width - 8)
        $minimizeButton.Left = [Math]::Max($aboutBtn.Right + 4, $closeButton.Left - $minimizeButton.Width - 4)
        $collapseBtn.Left    = [Math]::Max($aboutBtn.Right + 4, $minimizeButton.Left - $collapseBtn.Width - 4)
        $pinBtn.Left         = [Math]::Max($aboutBtn.Right + 4, $collapseBtn.Left - $pinBtn.Width - 4)
        $layoutBtn.Left      = [Math]::Max($aboutBtn.Right + 4, $pinBtn.Left - $layoutBtn.Width - 4)
    } catch {}
})

$viewport.Add_SizeChanged({ Layout-MetaRows })
$scrollTrack.Add_SizeChanged({ Apply-CustomScroll })

$scrollThumb.Add_MouseEnter({ $scrollThumb.BackColor = $scrollThumbHoverBg })
$scrollThumb.Add_MouseLeave({ if (-not $script:draggingThumb) { $scrollThumb.BackColor = $scrollThumbBg } })
$scrollThumb.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:draggingThumb = $true
        $script:dragStartY = [System.Windows.Forms.Cursor]::Position.Y
        $script:dragStartOffset = $script:scrollOffset
        $scrollThumb.Capture = $true
        $scrollThumb.BackColor = $scrollThumbHoverBg
    }
})
$scrollThumb.Add_MouseMove({
    if ($script:draggingThumb) {
        $trackH = [Math]::Max(1, $scrollTrack.ClientSize.Height)
        $range = [Math]::Max(1, $trackH - $scrollThumb.Height)
        $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:dragStartY
        $newOffset = $script:dragStartOffset + [int](($dy / $range) * [Math]::Max(1, $script:maxScroll))
        Set-CustomScrollOffset $newOffset
    }
})
$scrollThumb.Add_MouseUp({
    if ($script:draggingThumb) {
        $script:draggingThumb = $false
        $scrollThumb.Capture = $false
        $scrollThumb.BackColor = $scrollThumbBg
    }
})
$scrollTrack.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $eventArgs.Y -lt $scrollThumb.Top) {
        Scroll-By (-[Math]::Max(80, $viewport.ClientSize.Height - 40))
    } elseif ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $eventArgs.Y -gt ($scrollThumb.Top + $scrollThumb.Height)) {
        Scroll-By ([Math]::Max(80, $viewport.ClientSize.Height - 40))
    }
})
Attach-WheelHandler $scrollTrack
Attach-WheelHandler $scrollThumb

$stateSaveTimer = New-Object System.Windows.Forms.Timer
$stateSaveTimer.Interval = 600
$stateSaveTimer.Add_Tick({
    if ($script:stateDirty) { Save-PanelState }
    $stateSaveTimer.Stop()
})

$form.Add_Move({
    if (-not $script:loadingState) {
        $script:stateDirty = $true
        $stateSaveTimer.Stop(); $stateSaveTimer.Start()
    }
})
$form.Add_Resize({
    if (-not $script:loadingState) {
        $script:stateDirty = $true
        $stateSaveTimer.Stop(); $stateSaveTimer.Start()
    }
})

$form.Add_FormClosed({
    try { Save-PanelState } catch {}
    try { if ($null -ne $script:currentImage)   { $script:currentImage.Dispose()   } } catch {}
    try { if ($null -ne $script:copyIcon)       { $script:copyIcon.Dispose()       } } catch {}
    try { if ($null -ne $script:prevIcon)       { $script:prevIcon.Dispose()       } } catch {}
    try { if ($null -ne $script:nextIcon)       { $script:nextIcon.Dispose()       } } catch {}
    try { if ($null -ne $script:closeIcon)      { $script:closeIcon.Dispose()      } } catch {}
    try { if ($null -ne $script:collapseIcon)   { $script:collapseIcon.Dispose()   } } catch {}
    try { if ($null -ne $script:expandIcon)     { $script:expandIcon.Dispose()     } } catch {}
    try { if ($null -ne $script:imageIconNormal){ $script:imageIconNormal.Dispose() } } catch {}
    try { if ($null -ne $script:imageIconDimmed){ $script:imageIconDimmed.Dispose() } } catch {}
    try { if ($null -ne $script:minimizeIcon)   { $script:minimizeIcon.Dispose()   } } catch {}
    try { if ($null -ne $script:moveIcon)       { $script:moveIcon.Dispose()       } } catch {}
    try { if ($null -ne $script:openIcon)       { $script:openIcon.Dispose()       } } catch {}
    try { if ($null -ne $script:pinIconNormal)  { $script:pinIconNormal.Dispose()  } } catch {}
    try { if ($null -ne $script:pinIconDimmed)  { $script:pinIconDimmed.Dispose()  } } catch {}
    try { if ($null -ne $script:horzIconH)      { $script:horzIconH.Dispose()      } } catch {}
    try { if ($null -ne $script:horzIconV)      { $script:horzIconV.Dispose()      } } catch {}
    try { if ($null -ne $form.Icon)             { $form.Icon.Dispose()             } } catch {}
    try { $statusRevertTimer.Stop(); $statusRevertTimer.Dispose() } catch {}
    try { $toolTip.Dispose() } catch {}
    try { $stateSaveTimer.Stop() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
})

# Register drag-drop on all major surfaces so files can be dropped anywhere on the app.
Add-DropTarget $form
Add-DropTarget $toolbar
Add-DropTarget $viewport
Add-DropTarget $contentPanel
Add-DropTarget $imagePanel
Add-DropTarget $imageBox

# Restore layout mode from saved state without triggering a file reload
# (the file hasn't been set yet — that happens immediately below).
if ($script:layoutMode -eq 'Horizontal') {
    $scrollHost.Visible    = $false
    $horzContainer.Visible = $true
    if ($null -ne $script:horzIconV) { $layoutBtn.Image = $script:horzIconV; $layoutBtn.Text = '' }
    else { $layoutBtn.Image = $null; $layoutBtn.Text = 'V' }
    $toolTip.SetToolTip($layoutBtn, 'Switch to Vertical')
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 640, 280
}

if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-Path -LiteralPath $FilePath)) {
    Load-FileIntoPanel $FilePath
} elseif (-not [string]::IsNullOrWhiteSpace($script:restoredFile) -and (Test-Path -LiteralPath $script:restoredFile)) {
    Load-FileIntoPanel $script:restoredFile
} else {
    $statusLabel.Text = "Click the 'Open Folder' icon in the toolbar to choose an image folder"
}
[void][System.Windows.Forms.Application]::Run($form)
