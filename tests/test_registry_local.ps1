#requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $base) { throw 'Нужен новый каталог для вымышленных файлов.' }
. (Join-Path $PSScriptRoot '../scripts/copy-course-registry.ps1') -OutputRoot $base

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Test $failed 'Ожидаемый отказ не произошёл.'
}

$sourceFolder = Assert-CoursePrivateFolder (Join-Path $base 'working')
$folder = Join-Path $base 'backups'
$script:CourseRegistryLocalSource = Join-Path $sourceFolder 'registry.xlsx'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($script:CourseRegistryLocalSource, 'Create')
try {
    foreach ($name in @('[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet1.xml',
            'xl/worksheets/sheet2.xml', 'xl/worksheets/sheet3.xml')) {
        $writer = New-Object IO.StreamWriter($archive.CreateEntry($name).Open())
        try { $writer.Write('<synthetic-local-fixture/>') } finally { $writer.Dispose() }
    }
} finally { $archive.Dispose() }
$fixture = [IO.File]::ReadAllBytes($script:CourseRegistryLocalSource)
$sha = (Get-FileHash -LiteralPath $script:CourseRegistryLocalSource).Hash.ToLowerInvariant()
$first = Invoke-CourseLocalBackup -Folder $folder -DoPrune $false
Assert-Test ($first.sha256 -eq $sha -and $first.source_location -eq 'laptop' -and
    -not $first.network_used) 'Локальная копия или сведения об источнике неверны.'
$report = [IO.File]::ReadAllBytes((Join-Path $folder 'last-success.json'))

# Повреждение источника не должно заменить последнюю успешную копию и сводку.
[IO.File]::WriteAllBytes($script:CourseRegistryLocalSource, [byte[]](1, 2, 3))
Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false }
Assert-Test (@(Get-ChildItem -LiteralPath $folder -Filter 'registry-*.xlsx').Count -eq 1) 'Повреждённый источник принят.'
Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $folder 'last-success.json'))) -eq
    [Convert]::ToBase64String($report)) 'Успешная сводка заменена при ошибке.'
[IO.File]::WriteAllBytes($script:CourseRegistryLocalSource, $fixture)

$sourceLock = [IO.File]::Open($script:CourseRegistryLocalSource, 'Open', 'ReadWrite', 'None')
try { Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false } }
finally { $sourceLock.Dispose() }
Assert-Fails { Invoke-CourseLocalBackup -Folder $sourceFolder -DoPrune $false }

$actualSource = $script:CourseRegistryLocalSource
$script:CourseRegistryLocalSource = Join-Path $sourceFolder 'missing.xlsx'
Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false }
$script:CourseRegistryLocalSource = $actualSource

$junction = Join-Path $base 'working-link'
New-Item -ItemType Junction -Path $junction -Target $sourceFolder | Out-Null
$script:CourseRegistryLocalSource = Join-Path $junction 'registry.xlsx'
Assert-Fails { Invoke-CourseLocalBackup -Folder $folder -DoPrune $false }
$script:CourseRegistryLocalSource = $actualSource
Assert-Test ((Get-FileHash -LiteralPath $actualSource).Hash.ToLowerInvariant() -eq $sha) 'Источник изменён.'
Assert-Test (@(Get-ChildItem -LiteralPath $folder -Filter '.pending-*' -Force).Count -eq 0) 'Остались незавершённые файлы.'
[ordered]@{tests_passed=6;fixtures_only=$true;production_network_used=$false} | ConvertTo-Json
