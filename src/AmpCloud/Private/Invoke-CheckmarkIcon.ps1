function Invoke-CheckmarkIcon {
    <# Draws a checkmark (tick) inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $ix = [int]($r.Width * 0.25);  $iy = [int]($r.Height * 0.25)
    # Three points: left-mid, bottom-centre, top-right
    $p1 = New-Object System.Drawing.PointF(($r.X + $ix),               ($r.Y + $r.Height * 0.52))
    $p2 = New-Object System.Drawing.PointF(($r.X + $r.Width * 0.42),   ($r.Y + $r.Height - $iy))
    $p3 = New-Object System.Drawing.PointF(($r.X + $r.Width - $ix),    ($r.Y + $iy))
    $g.DrawLine($Pen, $p1, $p2)
    $g.DrawLine($Pen, $p2, $p3)
}
