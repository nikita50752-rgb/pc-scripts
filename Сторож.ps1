# «Сторож»: ищет признаки возвращения майнера/вируса. Ничего не удаляет и не меняет — только сообщает.
# Первый запуск запоминает «нормальное» состояние; дальше тревога только на НОВОЕ подозрительное.
# Запуск: powershell -ExecutionPolicy Bypass -File ".\Сторож.ps1" [-БезУведомления] [-СброситьБазу]
param([switch]$БезУведомления, [switch]$СброситьБазу)

$ErrorActionPreference = 'SilentlyContinue'
$DIR    = $PSScriptRoot
$BASEFILE = Join-Path $DIR 'Сторож_база.json'
$REPORT = Join-Path $DIR 'Сторож_отчёт.txt'
$now    = Get-Date

# ---------- база ----------
$base = $null
if ((Test-Path $BASEFILE) -and -not $СброситьБазу) { $base = Get-Content $BASEFILE -Raw -Encoding UTF8 | ConvertFrom-Json }
$firstRun = -not $base
$known    = @{}; if ($base) { $base.Known | % { $known[$_] = $true } }
$lastRun  = if ($base) { [datetime]$base.LastRun } else { $now }   # при первом запуске старые события не показываем

$alerts = New-Object System.Collections.Generic.List[string]
$info   = New-Object System.Collections.Generic.List[string]
$seen   = New-Object System.Collections.Generic.List[string]
$alertKeys = New-Object System.Collections.Generic.HashSet[string]

$badPlace = '(?i)\\ProgramData\\[^\\]+\\[^\\]+\.exe$|\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\Users\\Public\\|\\AppData\\Roaming\\[^\\]+\.exe$|\\\$Recycle'
$randName = '^[a-z]{10,14}$'

function Get-Exe([string]$cmd) {
  if (-not $cmd) { return $null }
  $cmd = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
  if ($cmd -match '^"([^"]+)"') { return $matches[1] }
  if ($cmd -match '^(.+?\.(exe|com|bat|cmd|vbs|js|ps1|scr))(\s|$)') { return $matches[1] }
  return ($cmd -split ' ')[0]
}
function Get-Sig([string]$exe) {
  if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return 'нет файла' }
  $s = Get-AuthenticodeSignature -LiteralPath $exe
  if ($s.Status -eq 'Valid') { return 'OK ' + (($s.SignerCertificate.Subject -split ',')[0] -replace 'CN=','') }
  return 'БЕЗ ПОДПИСИ'
}
# Проверка элемента автозапуска: тревога, если он новый И (без подписи ИЛИ в подозрительном месте)
function Check-Item([string]$kind, [string]$name, [string]$cmd) {
  $exe = Get-Exe $cmd
  $key = "$kind|$name|$exe"
  $seen.Add($key)
  if ($known.ContainsKey($key)) { return }
  $sig = Get-Sig $exe
  $why = @()
  if ($sig -eq 'БЕЗ ПОДПИСИ') { $why += 'нет цифровой подписи' }
  if ($exe -match $badPlace)  { $why += 'запускается из подозрительной папки' }
  if ((Split-Path (Split-Path $exe -Parent) -Leaf) -cmatch $randName -or [IO.Path]::GetFileNameWithoutExtension($exe) -cmatch $randName) { $why += 'случайное имя' }
  if ($firstRun) { return }
  if ($why) { [void]$alertKeys.Add($key); $alerts.Add("НОВОЕ в «$kind»: $name`n      $cmd`n      Причина: $($why -join ', ')") }
  else      { $info.Add("Новое в «$kind» (подписано: $sig): $name") }
}

# ---------- 1. Защитник ----------
$st = Get-MpComputerStatus
if ($st) {
  if (-not $st.RealTimeProtectionEnabled) { $alerts.Add('Защитник: ЗАЩИТА В РЕАЛЬНОМ ВРЕМЕНИ ВЫКЛЮЧЕНА') }
  if (-not $st.AntivirusEnabled)          { $alerts.Add('Защитник: АНТИВИРУС ВЫКЛЮЧЕН') }
  if ($st.AntivirusSignatureLastUpdated -lt $now.AddDays(-7)) { $alerts.Add("Защитник: базы не обновлялись с $($st.AntivirusSignatureLastUpdated)") }
} else { $alerts.Add('Защитник: не удалось получить состояние (служба отключена?)') }

# новые исключения (журнал событий 5007 — читается без прав администратора)
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational'; Id=5007; StartTime=$lastRun} | % {
  $m = $_.Message
  $new = ($m -split "`n" | ? { $_ -match 'New value:' }) -join ''
  if ($new -match 'Exclusions\\(Paths|Processes|Extensions|IpAddresses)\\(.+?)\s*=') {
    $alerts.Add("Защитник: ДОБАВЛЕНО ИСКЛЮЧЕНИЕ ($($matches[1])): $($matches[2])  [$($_.TimeCreated)]")
  }
  if ($new -match 'DisableRealtimeMonitoring|DisableAntiSpyware|DisableBehaviorMonitoring|DisableIOAVProtection' -and $new -match '= 0x1') {
    $alerts.Add("Защитник: кто-то отключил защиту: $($new.Trim())  [$($_.TimeCreated)]")
  }
}
# что Защитник нашёл с прошлой проверки
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational'; Id=1116; StartTime=$lastRun} | % {
  $n = (($_.Message -split "`n") | ? { $_ -match '^\s*(Name|Имя):' }) -join ''
  $p = (($_.Message -split "`n") | ? { $_ -match '^\s*(Path|Путь):' }) -join ''
  $alerts.Add("Защитник нашёл угрозу [$($_.TimeCreated)]: $($n.Trim()) $($p.Trim())")
}

# ---------- 2. Папки со случайными именами в ProgramData ----------
Get-ChildItem C:\ProgramData -Directory -Force | ? { $_.Name -cmatch $randName } | % {
  $key = "ProgramData|$($_.Name)"; $seen.Add($key)
  if (-not $firstRun -and -not $known.ContainsKey($key)) {
    [void]$alertKeys.Add($key)
    $exes = (Get-ChildItem -LiteralPath $_.FullName -Filter *.exe -Recurse -Force | % Name) -join ', '
    $alerts.Add("НОВАЯ папка со случайным именем: $($_.FullName)  (exe: $exes)")
  }
}

# ---------- 3. Автозагрузка ----------
foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
  $p = Get-ItemProperty $rk
  if ($p) { $p.PSObject.Properties | ? { $_.Name -notlike 'PS*' } | % { Check-Item 'Автозагрузка' $_.Name ([string]$_.Value) } }
}
$ws = New-Object -ComObject WScript.Shell
foreach ($sf in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") {
  Get-ChildItem -LiteralPath $sf -Force | ? { $_.Name -ne 'desktop.ini' } | % {
    $t = if ($_.Extension -eq '.lnk') { $ws.CreateShortcut($_.FullName).TargetPath } else { $_.FullName }
    Check-Item 'Папка автозагрузки' $_.Name $t
  }
}
# Winlogon (майнеры иногда подменяют Shell/Userinit)
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if ($wl.Shell -and $wl.Shell -notmatch '^explorer\.exe,?$') { $alerts.Add("Winlogon Shell изменён: $($wl.Shell)") }
if ($wl.Userinit -and $wl.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { $alerts.Add("Winlogon Userinit изменён: $($wl.Userinit)") }

# ---------- 4. Планировщик задач (кроме встроенных Microsoft) ----------
Get-ScheduledTask | ? { $_.TaskPath -notlike '\Microsoft\*' } | % {
  $t = $_; $t.Actions | ? { $_.Execute } | % { Check-Item 'Планировщик' ($t.TaskPath + $t.TaskName) ("$($_.Execute) $($_.Arguments)") }
}

# ---------- 5. Службы (кроме стандартных svchost) ----------
Get-CimInstance Win32_Service | ? { $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\(system32|SysWOW64)\\svchost\.exe' } | % {
  Check-Item 'Службы' $_.Name $_.PathName
}

# ---------- 6. Запущенные процессы из подозрительных мест ----------
Get-Process | ? { $_.Path } | % {
  $p = $_.Path
  if ($p -match $badPlace -or (Split-Path (Split-Path $p -Parent) -Leaf) -cmatch $randName -or [IO.Path]::GetFileNameWithoutExtension($p) -cmatch $randName) {
    if ((Get-Sig $p) -eq 'БЕЗ ПОДПИСИ') { $alerts.Add("Сейчас работает неподписанная программа из подозрительного места: $p (CPU $([math]::Round($_.CPU)) c)") }
  }
}

# ---------- сохранить базу (только при отсутствии тревог новые элементы считаются «нормой») ----------
# подозрительное в базу не добавляем — тревога будет повторяться, пока не разберётесь
$keep = @(@($known.Keys) + @($seen | ? { -not $alertKeys.Contains($_) }) | Select -Unique)
@{ LastRun = $now.ToString('o'); Known = $keep } | ConvertTo-Json -Depth 3 | Out-File $BASEFILE -Encoding utf8

# ---------- отчёт ----------
$lines = @("Проверка «Сторож»: $($now.ToString('dd.MM.yyyy HH:mm'))", '')
if ($firstRun) { $lines += "Первый запуск: запомнено текущее состояние ($($seen.Count) элементов). Дальше тревога будет только на новое подозрительное." }
if ($alerts.Count) { $lines += "⚠ ТРЕВОГИ ($($alerts.Count)):"; $lines += ($alerts | % { " - $_" }); $lines += ''
  $lines += 'Что делать: запустите полную проверку (Безопасность Windows → Защита от вирусов → Параметры сканирования → Полное) и покажите этот отчёт Claude.' }
else { $lines += '✅ Всё чисто: новых подозрительных программ, исключений и угроз не найдено.' }
if ($info.Count) { $lines += ''; $lines += 'Для сведения (новые, но подписанные — скорее всего, вы сами что-то установили):'; $lines += ($info | % { " - $_" }) }
$st2 = if ($st) { "Защитник: реальное время = $($st.RealTimeProtectionEnabled), базы от $($st.AntivirusSignatureLastUpdated)" } else { '' }
$lines += ''; $lines += $st2
$lines | Out-File $REPORT -Encoding utf8
$lines | % { Write-Output $_ }

# ---------- уведомление ----------
if ($alerts.Count -and -not $БезУведомления) {
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $first = [Security.SecurityElement]::Escape(($alerts[0] -split "`n")[0])
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast activationType='protocol' launch='file:///$($REPORT -replace '\\','/')'><visual><binding template='ToastGeneric'><text>⚠ Сторож: найдено подозрительное ($($alerts.Count))</text><text>$first</text><text>Нажмите, чтобы открыть отчёт</text></binding></visual></toast>")
    $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
  } catch { Start-Process notepad.exe $REPORT }
}
