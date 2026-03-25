function New-RoundedRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($X,          $Y,          $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y,          $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
    $p.AddArc($X,          $Y + $H - $d, $d, $d,  90, 90)
    $p.CloseFigure()
    return $p
}
