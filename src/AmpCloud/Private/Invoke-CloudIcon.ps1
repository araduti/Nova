function Invoke-CloudIcon {
    <# Draws a simple cloud silhouette inside a rect. #>
    param($Graphics, $Rect, $Pen)
    $g = $Graphics; $r = $Rect
    $inset = [int]($r.Width * 0.18)
    $bx = $r.X + $inset;  $by = $r.Y + $r.Height * 0.40
    $bw = $r.Width - $inset * 2;  $bh = $r.Height * 0.35
    # Base rounded rect
    $g.DrawArc($Pen, $bx, $by, $bh, $bh, 90, 180)
    $g.DrawLine($Pen, ($bx + $bh / 2), ($by + $bh), ($bx + $bw - $bh / 2), ($by + $bh))
    $g.DrawArc($Pen, ($bx + $bw - $bh), $by, $bh, $bh, 270, 180)
    # Top bump
    $topW = $bw * 0.50;  $topH = $bh * 1.1
    $g.DrawArc($Pen, ($bx + $bw * 0.25), ($by - $topH * 0.50), $topW, $topH, 180, 180)
}
