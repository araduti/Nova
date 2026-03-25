function Get-SignalBar { param([int]$s) ('█' * [Math]::Round($s/20)) + ('░' * (5-[Math]::Round($s/20))) }
