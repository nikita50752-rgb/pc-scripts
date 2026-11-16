# Поиск одинаковых файлов в выбранной папке.
# Ничего не удаляет без вашего подтверждения; выбранные копии уходят в Корзину (можно восстановить).
# Запуск: powershell -ExecutionPolicy Bypass -File ".\Дубликаты.ps1" [-Папка "путь"] [-ТолькоСписок]
param([string]$Папка, [switch]$ТолькоСписок)

Add-Type -AssemblyName System.Windows.Forms, Microsoft.VisualBasic
$LOG = Join-Path $PSScriptRoot 'Дубликаты_журнал.txt'

# --- 1. выбор папки
if (-not $Папка) {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'Где искать одинаковые файлы? (поиск идёт и во вложенных папках)'
  $dlg.SelectedPath = Join-Path $env:USERPROFILE 'Downloads'
  if ($dlg.ShowDialog() -ne 'OK') { return }
  $Папка = $dlg.SelectedPath
}
if ($Папка -match '^[A-Za-z]:\\?$' -or $Папка -like "$env:WINDIR*" -or $Папка -like "$env:ProgramFiles*" -or $Папка -like "${env:ProgramFiles(x86)}*" -or $Папка -like "$env:ProgramData*" -or $Папка -like "$env:APPDATA*" -or $Папка -like "$env:LOCALAPPDATA*") {
  $msg = "Эту папку проверять нельзя: в ней системные файлы или файлы программ.`n$Папка"
  if ($ТолькоСписок) { Write-Host $msg -ForegroundColor Red } else { [System.Windows.Forms.MessageBox]::Show($msg, 'Дубликаты', 'OK', 'Warning') | Out-Null }
  return
}
Write-Host "Ищу одинаковые файлы в: $Папка" -ForegroundColor Cyan

# --- 2. собрать файлы (без ссылок, без служебных папок сохранённых страниц и программ)
$skipExt = '.dll','.ini','.lnk','.url','.sys','.js','.css'
$stack = New-Object System.Collections.Stack; $stack.Push((Get-Item -LiteralPath $Папка))
$files = New-Object System.Collections.Generic.List[object]
while ($stack.Count) {
  $d = $stack.Pop()
  Get-ChildItem -LiteralPath $d.FullName -Force -EA SilentlyContinue | % {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    if ($_.PSIsContainer) {
      if ($_.Name -like '*_files' -or $_.Name -in '.git','node_modules','__pycache__') { return }
      # папка программы (есть .dll, или .exe вместе с файлами настроек) — пропускаем целиком, чтобы ничего не сломать
      $kids = Get-ChildItem -LiteralPath $_.FullName -File -Force -EA SilentlyContinue
      if ($_.Name -ne 'Установщики' -and ($kids | ? { $_.Extension -eq '.dll' } | Select -First 1)) { return }
      if ($_.Name -ne 'Установщики' -and ($kids | ? { $_.Extension -eq '.exe' }) -and (($kids | ? { $_.Extension -in '.json','.xml','.config','.ini','.cfg','.dat' }) -or (Get-ChildItem -LiteralPath $_.FullName -Directory -Force -EA SilentlyContinue | Select -First 1))) { return }
      $stack.Push($_)
    } elseif ($_.Length -gt 0 -and $_.Extension.ToLower() -notin $skipExt) { $files.Add($_) }
  }
}
Write-Host ("Файлов: {0}. Сравниваю..." -f $files.Count)

# --- 3. одинаковый размер -> одинаковое содержимое (MD5)
$groups = @(); $n = 0
$files | Group-Object Length | ? Count -gt 1 | % {
  $_.Group | Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5 -EA SilentlyContinue).Hash } | ? { $_.Name -and $_.Count -gt 1 } | % { $n++; $groups += ,@($n, $_.Group) }
}
if (-not $groups.Count) {
  Write-Host 'Одинаковых файлов не найдено.' -ForegroundColor Green
  if (-not $ТолькоСписок) { [System.Windows.Forms.MessageBox]::Show("Одинаковых файлов не найдено.`n$Папка", 'Дубликаты') | Out-Null }
  return
}

# --- 4. в каждой группе оставляем самый старый файл с самым коротким именем, остальные — кандидаты
$rows = foreach ($g in $groups) {
  $id = $g[0]; $grp = $g[1]
  $keep = $grp | Sort-Object { $_.Name.Length }, LastWriteTime | Select -First 1
  foreach ($f in ($grp | ? { $_.FullName -ne $keep.FullName })) {
    [pscustomobject]@{
      'Группа'      = $id
      'Копия (в Корзину)' = $f.FullName.Substring($Папка.TrimEnd('\').Length).TrimStart('\')
      'МБ'          = [math]::Round($f.Length/1MB, 2)
      'Оригинал (остаётся)' = $keep.FullName.Substring($Папка.TrimEnd('\').Length).TrimStart('\')
      'Полный путь' = $f.FullName
    }
  }
}
$totalMB = ($rows | Measure 'МБ' -Sum).Sum
Write-Host ("Найдено лишних копий: {0}, это {1:N1} МБ" -f @($rows).Count, $totalMB) -ForegroundColor Yellow

if ($ТолькоСписок) { $rows | Select 'Группа','Копия (в Корзину)','МБ','Оригинал (остаётся)' | Format-Table -AutoSize | Out-String -Width 300; return }

# --- 5. показать список: пользователь сам выбирает, что убрать
$sel = $rows | Out-GridView -Title "Копии: $(@($rows).Count) шт., $([math]::Round($totalMB,1)) МБ. Выделите, что убрать в Корзину (Ctrl+A — все), и нажмите OK" -PassThru
if (-not $sel) { Write-Host 'Ничего не выбрано, файлы не тронуты.'; return }
$selMB = [math]::Round(($sel | Measure 'МБ' -Sum).Sum, 1)
$ok = [System.Windows.Forms.MessageBox]::Show("Отправить в Корзину $(@($sel).Count) файл(ов), $selMB МБ?`nОригиналы останутся на месте. Из Корзины всё можно восстановить.", 'Дубликаты', 'YesNo', 'Question')
if ($ok -ne 'Yes') { Write-Host 'Отменено, файлы не тронуты.'; return }

# --- 6. в Корзину (с повторной проверкой, что оригинал на месте)
$done = 0
foreach ($r in $sel) {
  $orig = Join-Path $Папка $r.'Оригинал (остаётся)'
  if (-not (Test-Path -LiteralPath $orig)) { Write-Host "Пропущено (нет оригинала): $($r.'Копия (в Корзину)')"; continue }
  try {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($r.'Полный путь', 'OnlyErrorDialogs', 'SendToRecycleBin')
    ("{0:yyyy-MM-dd HH:mm}  В Корзину: {1}  (оригинал: {2})" -f (Get-Date), $r.'Полный путь', $orig) | Out-File $LOG -Append -Encoding utf8
    $done++
  } catch { Write-Host "Не удалось: $($r.'Копия (в Корзину)')" }
}
Write-Host "Готово: в Корзину отправлено $done файл(ов), $selMB МБ." -ForegroundColor Green
