# Сверяет общедоступные ответы сервера с файлами проверенной сборки.
param(
    [uri]$BaseUrl = 'https://evgeniikotsur.ru/',
    [string]$BuildPath = (Join-Path $PSScriptRoot '../dist/course')
)

$ErrorActionPreference = 'Stop'
if (-not $BaseUrl.IsAbsoluteUri -or $BaseUrl.UserInfo -or $BaseUrl.Query -or $BaseUrl.Fragment) {
    throw 'Укажите обычный абсолютный адрес сайта без логина, параметров и якоря.'
}
if ($BaseUrl.Scheme -ne 'https' -and -not ($BaseUrl.Scheme -eq 'http' -and $BaseUrl.IsLoopback)) {
    throw 'Для публичного адреса требуется HTTPS. HTTP разрешён для локальной проверки.'
}
$origin = [uri]($BaseUrl.AbsoluteUri.TrimEnd('/') + '/')
$folder = Get-Item -LiteralPath $BuildPath
if (-not $folder.PSIsContainer -or -not (Test-Path -LiteralPath (Join-Path $folder.FullName 'index.html') -PathType Leaf)) {
    throw 'Сначала соберите сайт командой node scripts/build.mjs.'
}
$root = $folder.FullName.TrimEnd('\', '/')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
$results = [System.Collections.Generic.List[string]]::new()
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $route = $relative -replace '(^|/)index\.html$', '$1'
        $encoded = ($route.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $url = [uri]::new($origin, $encoded)
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -MaximumRedirection 0
            if ([int]$response.StatusCode -ne 200) {
                $results.Add("${relative}: HTTP $($response.StatusCode)")
                continue
            }
            $response.RawContentStream.Position = 0
            $remoteHash = [BitConverter]::ToString($sha.ComputeHash($response.RawContentStream)).Replace('-', '')
            $localHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if ($remoteHash -ne $localHash) {
                $results.Add("${relative}: содержимое отличается от сборки")
            }
            $mime = [string]$response.Headers['Content-Type']
            if ($file.Extension -eq '.css' -and $mime -notmatch '^text/css(?:;|$)') {
                $results.Add("${relative}: сервер не отдаёт CSS с типом text/css")
            }
            if ($file.Extension -eq '.js' -and $mime -notmatch '^(application|text)/(x-)?javascript(?:;|$)') {
                $results.Add("${relative}: неверный тип ответа для JavaScript")
            }
        }
        catch {
            $status = $_.Exception.Response.StatusCode
            if ($null -ne $status) { $results.Add("${relative}: HTTP $([int]$status)") }
            else { $results.Add("${relative}: не удалось получить ответ") }
        }
    }
}
finally { $sha.Dispose() }

if ($results.Count -gt 0) {
    $results | ForEach-Object { Write-Output $_ }
    throw "Проверка не пройдена: $($results.Count) несовпадений для $($files.Count) файлов."
}
Write-Output "Проверка пройдена: $($files.Count) файлов совпадают со сборкой."
