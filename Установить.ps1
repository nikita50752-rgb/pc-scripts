# Установка: ярлыки на рабочем столе + еженедельные задачи (Уборка — вс 12:00, Сторож — вс 12:30).
# Права администратора не нужны. Удалить всё:  powershell -ExecutionPolicy Bypass -File .\Установить.ps1 -Удалить
param([switch]$Удалить)

$dir     = $PSScriptRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$ps      = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$items = @(
  @{ Name='Уборка';           Script='Уборка.ps1';    Icon="$env:WINDIR\System32\cleanmgr.exe,0";  Task='Еженедельная уборка';          At='12:00' }
  @{ Name='Найти дубликаты';  Script='Дубликаты.ps1'; Icon="$env:WINDIR\System32\imageres.dll,77"; Task=$null }
  @{ Name='Сторож';           Script='Сторож.ps1';    Icon="$env:WINDIR\System32\imageres.dll,101"; Task='Сторож (проверка на вирусы)'; At='12:30' }
)

foreach ($i in $items) {
  $lnk = Join-Path $desktop "$($i.Name).lnk"
  if ($Удалить) {
    if (Test-Path $lnk) { Remove-Item $lnk; "Удалён ярлык: $($i.Name)" }
    if ($i.Task -and (Get-ScheduledTask -TaskName $i.Task -EA SilentlyContinue)) { Unregister-ScheduledTask -TaskName $i.Task -Confirm:$false; "Удалена задача: $($i.Task)" }
    continue
  }
  $path = Join-Path $dir $i.Script
  Unblock-File -LiteralPath $path -EA SilentlyContinue   # снять пометку «скачано из интернета»

  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sc.TargetPath = $ps
  $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$path'; Write-Host; Read-Host 'Нажмите Enter, чтобы закрыть'`""
  $sc.WorkingDirectory = $dir; $sc.IconLocation = $i.Icon; $sc.Save()
  "Ярлык: $($i.Name)"

  if ($i.Task) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$path`""
    $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $i.At
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $i.Task -Action $a -Trigger $t -Settings $s -Force | Out-Null
    "Задача: $($i.Task) — по воскресеньям в $($i.At)"
  }
}
if (-not $Удалить) { "`nГотово. Первый запуск «Сторожа» запомнит текущее состояние ПК как нормальное." }
