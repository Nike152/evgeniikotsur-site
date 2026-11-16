#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
$testBase = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $testBase) { throw 'Нужен новый каталог вымышленных данных.' }
[void][IO.Directory]::CreateDirectory($testBase)
. (Join-Path $PSScriptRoot '../scripts/copy-course-registry.ps1') -OutputRoot $testBase

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Test $failed 'Ожидаемая ошибка не возникла.'
}
function Reset-Mock([string]$Mode = 'valid') {
    $script:FixtureMode = $Mode
    $script:HashCalls = 0
}
function Get-CourseSourceHash {
    $script:HashCalls++
    if ($script:FixtureMode -eq 'changed' -and $script:HashCalls -gt 1) { return ('0' * 64) }
    return $script:FixtureHash
}
function Copy-CourseSourceFile([string]$Destination) {
    if ($script:FixtureMode -eq 'corrupt') { [IO.File]::WriteAllBytes($Destination, [byte[]](1, 2, 3)); return }
    [IO.File]::Copy($script:FixturePath, $Destination)
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:FixturePath = Join-Path $testBase 'synthetic.xlsx'
$archive = [IO.Compression.ZipFile]::Open($script:FixturePath, 'Create')
try {
    foreach ($name in @('[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet1.xml',
            'xl/worksheets/sheet2.xml', 'xl/worksheets/sheet3.xml')) {
        $writer = New-Object IO.StreamWriter($archive.CreateEntry($name).Open())
        try { $writer.Write('<synthetic-test/>') } finally { $writer.Dispose() }
    }
} finally { $archive.Dispose() }
$script:FixtureHash = (Get-FileHash -LiteralPath $script:FixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
$folder = Join-Path $testBase 'copies'
Reset-Mock
$first = Invoke-CourseLocalBackup -Folder $folder -DoPrune $false
Assert-Test ($first.sha256 -eq $script:FixtureHash) 'Хеш первой копии не совпал.'
Assert-Test ((Get-FileHash -LiteralPath (Join-Path $folder $first.snapshot)).Hash.ToLowerInvariant() -eq $script:FixtureHash) 'Копия повреждена.'

Reset-Mock 'corrupt'
Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false }
Assert-Test (@(Get-ChildItem -LiteralPath $folder -Filter 'registry-*.xlsx').Count -eq 1) 'Повреждённый файл попал в готовые копии.'
Assert-Test (@(Get-ChildItem -LiteralPath $folder -Filter '.pending-*' -Force).Count -eq 0) 'Остался незавершённый тестовый файл.'

Reset-Mock 'changed'
Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false }
Assert-Test (@(Get-ChildItem -LiteralPath $folder -Filter 'registry-*.xlsx').Count -eq 1) 'Изменившийся источник принят.'

$lock = [IO.File]::Open((Join-Path $folder '.backup.lock'), 'Open', 'ReadWrite', 'None')
try { Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false } } finally { $lock.Dispose() }
Assert-Fails { Assert-CourseLocalPath (Join-Path $testBase 'outside.xlsx') $folder }

foreach ($doPrune in @($true, $false)) {
    $rotation = Assert-CoursePrivateFolder (Join-Path $testBase ('rotation-' + $doPrune))
    for ($number = 0; $number -lt 20; $number++) {
        $stamp = ([datetime]'2020-01-01').AddDays($number).ToString('yyyyMMddTHHmmssZ')
        $name = 'registry-' + $stamp + '-' + $number.ToString('x8') + '.xlsx'
        [IO.File]::Copy($script:FixturePath, (Join-Path $rotation $name))
    }
    $unrelated = Join-Path $rotation 'manual-keep.txt'
    [IO.File]::WriteAllText($unrelated, 'synthetic unrelated fixture')
    Reset-Mock
    $result = Invoke-CourseLocalBackup -Folder $rotation -DoPrune $doPrune
    $expectedCount = if ($doPrune) { 14 } else { 21 }
    Assert-Test (@(Get-ChildItem -LiteralPath $rotation -Filter 'registry-*.xlsx').Count -eq $expectedCount) 'Неверное число снимков после ротации.'
    Assert-Test (Test-Path -LiteralPath $unrelated) 'Затронут посторонний файл.'
}

$real = Join-Path $testBase 'junction-target'
[void][IO.Directory]::CreateDirectory($real)
$junction = Join-Path $testBase 'junction'
New-Item -ItemType Junction -Path $junction -Target $real | Out-Null
Assert-Fails { Assert-CoursePrivateFolder $junction }
Assert-Test (Test-Path -LiteralPath $real) 'Затронута цель тестовой ссылки.'

[ordered]@{ tests_passed = 8; production_network_used = $false;
    fixtures_only = $true; scratch = $testBase } | ConvertTo-Json
