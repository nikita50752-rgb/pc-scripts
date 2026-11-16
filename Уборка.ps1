# Еженедельная уборка: сортирует Загрузки, чистит временные файлы.
# Запуск вручную:      powershell -ExecutionPolicy Bypass -File ".\Уборка.ps1"
# Только посмотреть:   ... -File "...\Уборка.ps1" -Проверка
param([switch]$Проверка)

$ErrorActionPreference = 'Continue'
$DL   = Join-Path $env:USERPROFILE 'Downloads'
$LOG  = Join-Path $PSScriptRoot 'Уборка_журнал.txt'
$ДнейУстановщики = 30   # установщики старше N дней -> в Корзину
$ДнейTemp        = 7    # временные файлы старше N дней -> удалить

Add-Type -AssemblyName Microsoft.VisualBasic
function Log($msg) { $line = "{0:yyyy-MM-dd HH:mm}  {1}" -f (Get-Date), $msg; Write-Output $line; if (-not $Проверка) { $line | Out-File $LOG -Append -Encoding utf8 } }

$map = [ordered]@{
  'Документы'            = '.doc','.docx','.docm','.txt','.md','.xlsx','.xls','.csv','.ods','.odt','.rtf','.apkg'
  'Презентации'          = '.ppt','.pptx'
  'PDF и книги'          = '.pdf','.djvu','.epub','.fb2'
  'Изображения'          = '.jpg','.jpeg','.png','.gif','.webp','.svg','.bmp','.heic'
  'Видео'                = '.mp4','.avi','.webm','.mkv','.mov'
  'Музыка'               = '.mp3','.wav','.flac','.ogg','.m4a'
  'Архивы'               = '.zip','.rar','.7z','.tar','.gz'
  'Установщики'          = '.exe','.msi','.vbox-extpack'
  'Образы дисков'        = '.iso','.img'
  'Minecraft моды (jar)' = '.jar'
  'Чертежи КОМПАС и CAD' = '.m3d','.cdw','.step','.stp','.dxf','.dwg','.frw','.a3d','.frg','.spw'
  'Веб-страницы'         = '.html','.htm','.mhtml'
  'Торренты'             = '.torrent'
}
$ext2dir = @{}; foreach ($k in $map.Keys) { foreach ($e in $map[$k]) { $ext2dir[$e] = $k } }
$skipExt = '.crdownload','.part','.partial','.opdownload','.tmp','.download','.ini'

function Move-Safe($item, $dstDir) {
  $target = Join-Path $dstDir $item.Name; $i = 1
  while (Test-Path -LiteralPath $target) {
    $b = if ($item.PSIsContainer) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
    $e = if ($item.PSIsContainer) { '' } else { $item.Extension }
    $target = Join-Path $dstDir ("{0} ({1}){2}" -f $b, $i, $e); $i++
  }
  if ($Проверка) { Log "[проверка] $($item.Name) -> $dstDir"; return }
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  try { Move-Item -LiteralPath $item.FullName -Destination $target -ErrorAction Stop; Log "Перемещено: $($item.Name) -> $(Split-Path $dstDir -Leaf)" }
  catch { Log "Пропущено (занято?): $($item.Name)" }
}

Log "=== Уборка начата$(if ($Проверка) {' (режим проверки, ничего не меняется)'})"
$fresh = (Get-Date).AddMinutes(-30)   # не трогаем то, что качается прямо сейчас

# 1. Файлы в корне Загрузок -> по папкам
Get-ChildItem -LiteralPath $DL -File -Force | ? { $_.Extension.ToLower() -notin $skipExt -and $_.LastWriteTime -lt $fresh } | % {
  $dir = $ext2dir[$_.Extension.ToLower()]; if (-not $dir) { $dir = 'Прочее' }
  Move-Safe $_ (Join-Path $DL $dir)
}
# 2. Папки сохранённых страниц (*_files) -> к веб-страницам
Get-ChildItem -LiteralPath $DL -Directory -Force | ? { $_.Name -like '*_files' -and $_.LastWriteTime -lt $fresh } | % { Move-Safe $_ (Join-Path $DL 'Веб-страницы') }

# 3. Старые установщики -> Корзина (можно восстановить)
$inst = Join-Path $DL 'Установщики'
if (Test-Path -LiteralPath $inst) {
  Get-ChildItem -LiteralPath $inst -File -Force | ? { $_.LastWriteTime -lt (Get-Date).AddDays(-$ДнейУстановщики) } | % {
    if ($Проверка) { Log "[проверка] в Корзину: $($_.Name)" }
    else { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($_.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin'); Log "В Корзину (установщик старше $ДнейУстановщики дн.): $($_.Name)" } catch { Log "Не удалось в Корзину: $($_.Name)" } }
  }
}

# 4. Временные файлы и дампы сбоев старше N дней
$freed = 0
foreach ($t in "$env:LOCALAPPDATA\Temp", "$env:LOCALAPPDATA\CrashDumps") {
  if (-not (Test-Path $t)) { continue }
  # обходим папки сами и НЕ заходим в ссылки/соединения (reparse points), чтобы не задеть чужие файлы
  $stack = New-Object System.Collections.Stack; $stack.Push((Get-Item -LiteralPath $t -Force))
  $files = while ($stack.Count) { $d = $stack.Pop(); Get-ChildItem -LiteralPath $d.FullName -Force -EA SilentlyContinue | % { if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { } elseif ($_.PSIsContainer) { $stack.Push($_) } else { $_ } } }
  $files | ? { $_.FullName.StartsWith($t, [StringComparison]::OrdinalIgnoreCase) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$ДнейTemp) } | % {
    $len = $_.Length
    if ($Проверка) { $freed += $len } else { try { [IO.File]::Delete($_.FullName); $freed += $len } catch {} }
  }
}
Log ("Временные файлы: {0} {1:N0} МБ" -f $(if ($Проверка) {'можно очистить'} else {'очищено'}), ($freed/1MB))

# 5. Пустые папки в Загрузках
# (только совсем пустые папки, без вложений и не ссылки; удаляется без -Recurse)
Get-ChildItem -LiteralPath $DL -Directory -Force | ? { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue) -and $_.LastWriteTime -lt $fresh } | % {
  if ($Проверка) { Log "[проверка] пустая папка: $($_.Name)" } else { try { [IO.Directory]::Delete($_.FullName, $false); Log "Удалена пустая папка: $($_.Name)" } catch {} }
}

Log ("=== Готово. Свободно на C: {0:N1} ГБ" -f ((Get-PSDrive C).Free/1GB))
