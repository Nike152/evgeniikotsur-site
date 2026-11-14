#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,
    [ValidateRange(0, 86400)]
    [double]$SkipSeconds = 0,
    [ValidateRange(0, 86400)]
    [double]$DurationSeconds = 0,
    [ValidateRange(60, 3600)]
    [int]$PartSeconds = 3600
)

# Только локальная обработка: исходник сохраняется, отправки и удаления нет.
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$ffmpeg = (Get-Command ffmpeg -CommandType Application -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -CommandType Application -ErrorAction Stop).Source
$sourcePath = (Resolve-Path -LiteralPath $Source).ProviderPath
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw 'Нужен существующий видеофайл.'
}

function Read-VideoInfo([string]$Path) {
    $raw = & $ffprobe -v error -show_streams -show_format -of json $Path
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось прочитать свойства видео.' }
    return ($raw -join "`n" | ConvertFrom-Json)
}

$info = Read-VideoInfo $sourcePath
if (-not @($info.streams | Where-Object codec_type -EQ 'video').Count) {
    throw 'В исходнике нет видеодорожки.'
}
$hasAudio = @($info.streams | Where-Object codec_type -EQ 'audio').Count -gt 0
$sourceDuration = [double]::Parse([string]$info.format.duration, $culture)
if ($SkipSeconds -ge $sourceDuration) { throw 'Начало фрагмента находится за концом исходника.' }
$selectedDuration = $sourceDuration - $SkipSeconds
if ($DurationSeconds -gt 0) { $selectedDuration = [Math]::Min($selectedDuration, $DurationSeconds) }
if ($selectedDuration -le 0) { throw 'Продолжительность фрагмента должна быть больше нуля.' }

$outputPath = [IO.Path]::GetFullPath($OutputRoot)
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($outputPath))
# Запас для ограниченного битрейта и служебных данных; размер исходника не предсказывается.
$requiredSpace = [long]($selectedDuration * 3128000 / 8 * 1.25 + 512MB)
if ($drive.AvailableFreeSpace -lt $requiredSpace) {
    throw 'На выбранном диске недостаточно свободного места для обработки с запасом.'
}
$sourceHashBefore = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$jobName = 'запись-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$jobPath = Join-Path $outputPath $jobName
[void][IO.Directory]::CreateDirectory($jobPath)
$pattern = Join-Path $jobPath 'часть-%03d.mp4'

# WebM Телемоста может объявлять 1000 кадров/с. Ограничиваем выход 25 кадрами/с.
# Размер изображения сохраняется; добавляется только чётная граница для H.264.
$arguments = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-i', $sourcePath)
if ($SkipSeconds -gt 0) { $arguments += @('-ss', $SkipSeconds.ToString($culture)) }
$arguments += @('-t', $selectedDuration.ToString($culture), '-map', '0:v:0', '-map', '0:a:0?',
    '-sn', '-dn', '-map_metadata', '-1', '-map_chapters', '-1',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-maxrate', '3000k', '-bufsize', '6000k',
    '-vf', 'fps=25,pad=ceil(iw/2)*2:ceil(ih/2)*2', '-fps_mode', 'cfr', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '128k',
    '-force_key_frames', "expr:gte(t,n_forced*$PartSeconds)",
    '-f', 'segment', '-segment_time', [string]$PartSeconds, '-segment_time_delta', '0.05',
    '-segment_start_number', '1', '-reset_timestamps', '1',
    '-segment_format', 'mp4', '-segment_format_options', 'movflags=+faststart', $pattern)
Write-Host 'Подготовка MP4. Исходник не изменяется; это может занять время.'
& $ffmpeg @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Обработка прервана. Частичные файлы сохранены для проверки: $jobPath"
}

$parts = @(Get-ChildItem -LiteralPath $jobPath -Filter 'часть-*.mp4' -File | Sort-Object Name)
if (-not $parts.Count) { throw 'Готовые части не найдены.' }
$results = @()
foreach ($part in $parts) {
    $partInfo = Read-VideoInfo $part.FullName
    $video = @($partInfo.streams | Where-Object codec_type -EQ 'video')[0]
    $audio = @($partInfo.streams | Where-Object codec_type -EQ 'audio')
    $partDuration = [double]::Parse([string]$partInfo.format.duration, $culture)
    if ($video.codec_name -ne 'h264' -or $partDuration -le 0 -or $partDuration -gt ($PartSeconds + 2)) {
        throw "Не пройдена проверка видео: $($part.Name)"
    }
    if ($hasAudio -and ($audio.Count -ne 1 -or $audio[0].codec_name -ne 'aac')) {
        throw "Не сохранена звуковая дорожка: $($part.Name)"
    }
    if ($part.Length -ge 1900000000) { throw "Часть превышает безопасный размер для Telegram: $($part.Name)" }
    # Проверяется декодирование всей части, а не только её заголовок.
    $decodeMessages = @(& $ffmpeg -hide_banner -v error -nostdin -i $part.FullName -f null - 2>&1)
    if ($LASTEXITCODE -ne 0 -or $decodeMessages.Count) { throw "Ошибка декодирования: $($part.Name)" }
    $results += [pscustomobject]@{
        file = $part.Name
        bytes = $part.Length
        duration_seconds = $partDuration
        video = 'h264'
        audio = $(if ($audio.Count) { 'aac' } else { 'отсутствует в исходнике' })
        sha256 = (Get-FileHash -LiteralPath $part.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$totalDuration = ($results | Measure-Object duration_seconds -Sum).Sum
if ([Math]::Abs($totalDuration - $selectedDuration) -gt (1 + 0.1 * $parts.Count)) {
    throw 'Длительность готовых частей не совпала с выбранным фрагментом.'
}
if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $sourceHashBefore) {
    throw 'Исходник изменился во время обработки. Проверка не завершена.'
}
$report = [ordered]@{
    source_name = [IO.Path]::GetFileName($sourcePath)
    source_sha256 = $sourceHashBefore.ToLowerInvariant()
    skip_seconds = $SkipSeconds
    selected_seconds = $selectedDuration
    source_has_audio = $hasAudio
    manual_review_required = $true
    manual_review = 'Прослушать речь, проверить подписи и отсутствие личных окон во всех частях. Наличие аудиодорожки не подтверждает слышимость голоса.'
    parts = $results
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $jobPath 'проверка.json') -Encoding utf8
Write-Host "Готово: $jobPath"
Write-Host 'Перед отправкой проверьте речь, читаемость и посторонние фрагменты. Файлы никуда не отправлялись.'
