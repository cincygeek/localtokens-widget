# ----------------------------------------------------------------- theme ----
# Colour themes, some with a faint pixel-art pattern tiled over the background.
# The window's colours are brushes in its resources ({DynamicResource ...} in
# window.xaml); a theme swaps those brushes, so everything recolours at once.
# Palettes and patterns are adapted from clawd-usage-winwidget (MIT).

$ThemeBase = [ordered]@{
    Bg     = '#FF15171C'   # window
    Border = '#33FFFFFF'   # window edge
    Line   = '#1FFFFFFF'   # dividers
    Track  = '#26FFFFFF'   # empty part of a bar
    TextHi = '#FFF4F4F5'   # big number
    Text2  = '#FFD4D4D8'   # values
    Muted  = '#FF8B8B94'   # captions
    Dim    = '#FF71717A'   # labels
    Accent = '#FF2DD4BF'   # speed bar, chart, "Generating"
}

# Name shown in the menu, then what differs from the base.
$Themes = [ordered]@{
    classic   = @{ name = 'Classic' }
    oled      = @{ name = 'OLED black'; Bg = '#FF000000' }
    midnight  = @{ name = 'Midnight'; Bg = '#FF0F172A'; TextHi = '#FFF1F5F9'; Text2 = '#FFCBD5E1'; Muted = '#FF8494AB'
                   Dim = '#FF64748B'; Accent = '#FF38BDF8' }
    mocha     = @{ name = 'Mocha'; Bg = '#FF1E1E2E'; TextHi = '#FFF5F7FF'; Text2 = '#FFBAC2DE'; Muted = '#FF9399B2'
                   Dim = '#FF7F849C'; Accent = '#FF89B4FA' }
    forest    = @{ name = 'Forest'; Bg = '#FF111814'; TextHi = '#FFF0F5F1'; Text2 = '#FFCFDBD2'; Muted = '#FF86998B'
                   Dim = '#FF66786B'; Accent = '#FF86EFAC' }
    paper     = @{ name = 'Paper (light)'; Bg = '#FFF7F7F4'; Border = '#26000000'; Line = '#1A000000'; Track = '#1F000000'
                   TextHi = '#FF18181B'; Text2 = '#FF3F3F46'; Muted = '#FF6B6B74'; Dim = '#FF85858E'; Accent = '#FF0D9488' }
    halloween = @{ name = 'Halloween'; Bg = '#FF1C1326'; TextHi = '#FFFFF7ED'; Text2 = '#FFE7D3C4'; Muted = '#FFA08B9C'
                   Dim = '#FF8A7690'; Accent = '#FFF97316'; pattern = 'halloween' }
    space     = @{ name = 'Space'; Bg = '#FF0E0820'; TextHi = '#FFF5F3FF'; Text2 = '#FFD6D0EE'; Muted = '#FF9A90BE'
                   Dim = '#FF7D73A3'; Accent = '#FFA78BFA'; pattern = 'space' }
    ocean     = @{ name = 'Ocean'; Bg = '#FF0A2236'; TextHi = '#FFF0F9FF'; Text2 = '#FFCDE6F5'; Muted = '#FF86A9BF'
                   Dim = '#FF6A8DA3'; Accent = '#FF22D3EE'; pattern = 'ocean' }
    cyberpunk = @{ name = 'Cyberpunk'; Bg = '#FF0C0B16'; TextHi = '#FFF2FBFF'; Text2 = '#FFCBD9E3'; Muted = '#FF8494A8'
                   Dim = '#FF6B7790'; Accent = '#FF00E5FF'; pattern = 'cyberpunk' }
}

# A tile of sprites ("." - empty, a letter - a colour), repeated over the window.
$Patterns = @{
    halloween = @{
        tile = 104; px = 2; opacity = 0.1
        colors = @{ o = '#FFF97316'; g = '#FF65A30D'; b = '#FFA78BFA'; w = '#FFF5F5F4'; y = '#FFFDE047' }
        sprites = @(
            @{ x = 6; y = 6; art = @('....gg...', '...g.....', '.ooo.ooo.', 'ooooooooo', 'oo.ooo.oo',
                                     'ooooooooo', 'oo.o.o.oo', '.ooooooo.') }
            @{ x = 58; y = 20; art = @('b.........b', 'bb..b.b..bb', 'bbbbbbbbbbb', '.bbb.b.bbb.', '..b.....b..') }
            @{ x = 30; y = 56; art = @('..www..', '.wwwww.', 'ww.w.ww', 'wwwwwww', 'wwwwwww', 'wwwwwww', 'w.w.w.w') }
            @{ x = 76; y = 70; art = @('.y.', 'yyy', '.y.') }
            @{ x = 8; y = 84; art = @('y') }
            @{ x = 92; y = 4; art = @('y') }
        )
    }
    space = @{
        tile = 96; px = 1; opacity = 0.45
        colors = @{ w = '#FFFFFFFF'; v = '#FFC4B5FD'; p = '#FFF9A8D4'; b = '#FF93C5FD' }
        sprites = @(
            @{ x = 10; y = 8; art = @('w') }; @{ x = 41; y = 22; art = @('v') }; @{ x = 77; y = 12; art = @('b') }
            @{ x = 24; y = 47; art = @('p') }; @{ x = 63; y = 58; art = @('.w.', 'www', '.w.') }
            @{ x = 88; y = 40; art = @('v') }; @{ x = 6; y = 79; art = @('b') }; @{ x = 47; y = 86; art = @('w') }
            @{ x = 83; y = 81; art = @('p') }
        )
    }
    ocean = @{
        tile = 104; px = 2; opacity = 0.07
        colors = @{ w = '#FFE0F2FE'; p = '#FFF9A8D4'; y = '#FFFDE68A' }
        sprites = @(
            @{ x = 8; y = 10; art = @('.ww.', 'w..w', 'w..w', '.ww.') }
            @{ x = 22; y = 2; art = @('w') }
            @{ x = 56; y = 28; art = @('.p.p.', 'ppppp', '.pyp.', 'ppppp', '.p.p.') }
            @{ x = 30; y = 70; art = @('.w.', 'w.w', '.w.') }
            @{ x = 84; y = 76; art = @('.ww.', 'w..w', 'w..w', '.ww.') }
            @{ x = 94; y = 62; art = @('w') }
        )
    }
    cyberpunk = @{   # scanlines, as on an old monitor
        tile = 3; px = 1; opacity = 0.05
        colors = @{ c = '#FF00E5FF' }
        sprites = @( @{ x = 0; y = 0; art = @('ccc') } )
    }
}

function ConvertTo-Color([string]$hex) { return [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }

$script:PatternBrushes = @{}
function Get-PatternBrush([string]$name) {
    if ($script:PatternBrushes.ContainsKey($name)) { return $script:PatternBrushes[$name] }
    $p = $Patterns[$name]
    $groups = @{}
    foreach ($s in $p.sprites) {
        for ($y = 0; $y -lt $s.art.Count; $y++) {
            for ($x = 0; $x -lt $s.art[$y].Length; $x++) {
                $c = [string]$s.art[$y][$x]
                if (-not $p.colors.ContainsKey($c)) { continue }
                if (-not $groups.ContainsKey($c)) { $groups[$c] = New-Object System.Windows.Media.GeometryGroup }
                $groups[$c].Children.Add([System.Windows.Media.RectangleGeometry]::new(
                    [System.Windows.Rect]::new(($s.x + $x * $p.px), ($s.y + $y * $p.px), $p.px, $p.px)))
            }
        }
    }
    $dg = New-Object System.Windows.Media.DrawingGroup
    # An invisible square sets the tile's size, wherever the sprites are.
    $dg.Children.Add([System.Windows.Media.GeometryDrawing]::new([System.Windows.Media.Brushes]::Transparent, $null,
        [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $p.tile, $p.tile))))
    foreach ($c in $groups.Keys) {
        $dg.Children.Add([System.Windows.Media.GeometryDrawing]::new(
            [System.Windows.Media.SolidColorBrush]::new((ConvertTo-Color $p.colors[$c])), $null, $groups[$c]))
    }
    $b = New-Object System.Windows.Media.DrawingBrush $dg
    $b.TileMode = 'Tile'
    $b.ViewportUnits = 'Absolute'
    $b.Viewport = [System.Windows.Rect]::new(0, 0, $p.tile, $p.tile)
    $b.Opacity = $p.opacity
    $b.Freeze()
    $script:PatternBrushes[$name] = $b
    return $b
}

# 'auto' follows the season: Halloween in October, Classic the rest of the year.
function Get-ThemeId {
    $id = ([string]$script:Cfg.theme).ToLower()
    if ($id -eq 'auto' -or -not $id) { $id = $(if ((Get-Date).Month -eq 10) { 'halloween' } else { 'classic' }) }
    if (-not $Themes.Contains($id)) { $id = 'classic' }
    return $id
}

$script:ThemeKey = ''
function Set-Theme {
    $id = Get-ThemeId
    $accent = ([string]$script:Cfg.accent).Trim()
    if ($accent -match '^#[0-9A-Fa-f]{6}$') { $accent = '#FF' + $accent.Substring(1) }
    elseif ($accent -notmatch '^#[0-9A-Fa-f]{8}$') { $accent = '' }
    if ("$id|$accent" -eq $script:ThemeKey) { return }
    $script:ThemeKey = "$id|$accent"
    $t = $Themes[$id]
    $pal = @{}
    foreach ($k in $ThemeBase.Keys) { $pal[$k] = $(if ($t.ContainsKey($k)) { $t[$k] } else { $ThemeBase[$k] }) }
    if ($accent) { $pal.Accent = $accent }
    foreach ($k in $pal.Keys) {
        # Typed: otherwise WPF gets a PSObject wrapper and ignores it.
        [System.Windows.Media.SolidColorBrush]$b = [System.Windows.Media.SolidColorBrush]::new((ConvertTo-Color $pal[$k]))
        $win.Resources[$k] = $b
    }
    # The colours the code paints with (view.ps1, tray.ps1).
    $Colors.accent    = $pal.Accent
    $Colors.accentDim = '#7F' + $pal.Accent.Substring(3)
    $Colors.text2     = $pal.Text2
    $Colors.muted     = $pal.Muted
    $Colors.dim       = $pal.Dim
    $UI.Pattern.Fill = $(if ($t.pattern) { Get-PatternBrush $t.pattern } else { $null })
    # redraw what was built with the old colours
    $script:DetKey = $null
    $script:BarsKey = $null
    $script:IconKey = ''
}
