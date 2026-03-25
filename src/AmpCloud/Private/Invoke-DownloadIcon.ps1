function Invoke-DownloadIcon {
    <# Draws a downward arrow with a base-line inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $cx = $r.X + $r.Width / 2
    $inset = [int]($r.Width * 0.28)
    $top = $r.Y + $inset;  $bot = $r.Y + $r.Height - $inset
    $aw = [int]($r.Width * 0.18)  # arrow-head half-width
    $g.DrawLine($Pen, $cx, $top, $cx, $bot)                     # shaft
    $g.DrawLine($Pen, ($cx - $aw), ($bot - $aw), $cx, $bot)     # left barb
    $g.DrawLine($Pen, ($cx + $aw), ($bot - $aw), $cx, $bot)     # right barb
    $basY = $r.Y + $r.Height - $inset + 3
    $g.DrawLine($Pen, ($r.X + $inset), $basY,
        ($r.X + $r.Width - $inset), $basY)                      # base line
}
