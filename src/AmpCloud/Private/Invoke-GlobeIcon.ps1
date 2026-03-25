function Invoke-GlobeIcon {
    <# Draws a simple globe (circle + crosshairs + equator arc) inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $cx = $r.X + $r.Width / 2;  $cy = $r.Y + $r.Height / 2
    $inset = [int]($r.Width * 0.22)
    $ir = New-Object System.Drawing.Rectangle(
        ($r.X + $inset), ($r.Y + $inset),
        ($r.Width - $inset * 2), ($r.Height - $inset * 2))
    $g.DrawEllipse($Pen, $ir)                                   # outer circle
    $g.DrawLine($Pen, $cx, $ir.Top, $cx, $ir.Bottom)            # vertical line
    $g.DrawLine($Pen, $ir.Left, $cy, $ir.Right, $cy)            # horizontal line
    $g.DrawArc($Pen, ($cx - $ir.Width / 4), $ir.Top,
        ($ir.Width / 2), $ir.Height, 0, 180)                    # longitude arc
}
