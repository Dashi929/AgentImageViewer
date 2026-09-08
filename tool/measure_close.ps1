# Close-time regression probe (handover doc section 4.14 / 6).
# Launch exe -> wait for stable -> WM_CLOSE (same as clicking X) -> time process exit.
# Expect < 1s. If > 3s, the ExitProcess contract in windows/runner/main.cpp is broken
# (windows_single_instance pipe isolate stalls engine shutdown; see handover doc section 7).
# Keep this file ASCII-only: PowerShell 5.1 parses it under codepage 936.
param(
  [string]$Exe = 'E:\SoftwareProjects\AgentImageViewer\build\windows\x64\runner\Release\agent_image_viewer.exe',
  [string]$Arg = '',
  [int]$StartupWaitSec = 8
)
if (-not (Test-Path $Exe)) { Write-Output "exe not found: $Exe"; exit 1 }
$p = if ($Arg) { Start-Process -FilePath $Exe -ArgumentList $Arg -PassThru } else { Start-Process -FilePath $Exe -PassThru }
Start-Sleep -Seconds $StartupWaitSec
if ($p.HasExited) { Write-Output "process exited during startup, exit=$($p.ExitCode)"; exit 1 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& taskkill /PID $p.Id | Out-Null
try { Wait-Process -Id $p.Id -Timeout 30 -ErrorAction Stop } catch { Write-Output 'TIMEOUT 30s'; exit 1 }
$sw.Stop()
Write-Output "close_ms=$($sw.ElapsedMilliseconds)"
