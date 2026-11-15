#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [switch]$Prune,
    [ValidateRange(1, 3650)][int]$RetentionDays = 14
)

# Сохраняем только реестр из согласованного SSH-подключения; пароли не запрашиваем.
$ErrorActionPreference = 'Stop'
$script:CourseRegistryRemote = '/var/lib/course-admin/2026-11-28/registry.xlsx'
$script:CourseSshOptions = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2')

function Assert-CourseLocalPath([string]$Path, [string]$Folder) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full), $Folder, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Файл находится за пределами каталога копий.'
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Вместо обычного файла обнаружена папка или ссылка.'
        }
    }
    return $full
}

function Assert-CoursePrivateFolder([string]$Folder) {
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $allowed = @($current.Value, 'S-1-5-18', 'S-1-5-32-544')
    if (-not (Test-Path -LiteralPath $full)) {
        [void][IO.Directory]::CreateDirectory($full)
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($current)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in $allowed) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $full -AclObject $acl
    }
    $directory = Get-Item -LiteralPath $full -Force
    if (-not $directory.PSIsContainer) { throw 'Нужен каталог копий.' }
    $ancestor = [IO.DirectoryInfo]$directory
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Ссылка в пути каталога копий.' }
        $ancestor = $ancestor.Parent
    }
    $acl = Get-Acl -LiteralPath $full
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $current.Value) {
        throw 'У каталога копий другой владелец.'
    }
    foreach ($rule in $acl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($rule.AccessControlType -eq 'Allow' -and $allowed -notcontains $sid) {
            throw 'Каталог копий открыт другой учётной записи.'
        }
    }
    return $full
}

function Get-CourseRemoteHash {
    $ssh = Join-Path $env:WINDIR 'System32/OpenSSH/ssh.exe'
    $answer = @(& $ssh @script:CourseSshOptions 'dedal' '/usr/bin/sha256sum /var/lib/course-admin/2026-11-28/registry.xlsx' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $answer.Count -ne 1 -or
        [string]$answer[0] -notmatch '^([0-9a-f]{64})  /var/lib/course-admin/2026-11-28/registry\.xlsx$') {
        throw 'Не удалось проверить источник по SSH; пароли и новые ключи автоматически не принимаются.'
    }
    return $Matches[1]
}

function Copy-CourseRemoteFile([string]$Destination) {
    $scp = Join-Path $env:WINDIR 'System32/OpenSSH/scp.exe'
    $messages = @(& $scp '-q' @script:CourseSshOptions 'dedal:/var/lib/course-admin/2026-11-28/registry.xlsx' $Destination 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось получить копию с VPS.' }
}

function Test-CourseLocalBook([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -eq 0 -or $file.Length -gt 20MB) { throw 'Неподходящий размер реестра.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $expanded = ($archive.Entries | Measure-Object -Property Length -Sum).Sum
        if ($expanded -gt 20MB) { throw 'Слишком большой распакованный реестр.' }
        $names = @($archive.Entries | ForEach-Object FullName)
        foreach ($name in @('[Content_Types].xml', 'xl/workbook.xml',
                'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml', 'xl/worksheets/sheet3.xml')) {
            if ($names -notcontains $name) { throw 'Отсутствуют ожидаемые части XLSX.' }
        }
        if (@($names | Where-Object { $_ -match '^xl/(vbaProject\.bin|externalLinks/)' }).Count) {
            throw 'В книге появились макросы или внешние связи; требуется проверка.'
        }
        foreach ($entry in $archive.Entries) {
            $stream = $entry.Open()
            try { $stream.CopyTo([IO.Stream]::Null) } finally { $stream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Invoke-CourseLocalBackup([string]$Folder, [bool]$DoPrune, [int]$Days = 14) {
    $folderPath = Assert-CoursePrivateFolder $Folder
    $lockPath = Assert-CourseLocalPath (Join-Path $folderPath '.backup.lock') $folderPath
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $temporary = $null
    try {
        $before = Get-CourseRemoteHash
        $temporary = Assert-CourseLocalPath (Join-Path $folderPath ('.pending-' + [guid]::NewGuid().ToString('N') + '.xlsx')) $folderPath
        Copy-CourseRemoteFile $temporary
        [void](Assert-CourseLocalPath $temporary $folderPath)
        Test-CourseLocalBook $temporary
        $copied = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        $after = Get-CourseRemoteHash
        if ($copied -ne $before -or $after -ne $before) { throw 'Источник изменился или контрольная сумма копии не совпала.' }
        $now = [datetime]::UtcNow
        $name = 'registry-' + $now.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xlsx'
        $target = Assert-CourseLocalPath (Join-Path $folderPath $name) $folderPath
        [IO.File]::Move($temporary, $target)
        $temporary = $null
        $deleted = 0
        $copies = @(Get-ChildItem -LiteralPath $folderPath -File | Where-Object {
            $_.Name -match '^registry-\d{8}T\d{6}Z-[a-f0-9]{8}\.xlsx$'
        } | Sort-Object Name -Descending)
        if ($DoPrune) {
            foreach ($old in @($copies | Select-Object -Skip 14)) {
                $stamp = [datetime]::ParseExact($old.Name.Substring(9, 16), 'yyyyMMddTHHmmssZ',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
                if ($stamp -lt $now.AddDays(-$Days)) {
                    $oldPath = Assert-CourseLocalPath $old.FullName $folderPath
                    Remove-Item -LiteralPath $oldPath
                    $deleted++
                }
            }
        }
        $result = [ordered]@{ checked_at_utc = $now.ToString('o'); snapshot = $name;
            bytes = (Get-Item -LiteralPath $target).Length; sha256 = $copied;
            source_modified = $false; prune_enabled = $DoPrune; retention_days = $Days;
            minimum_snapshots = 14; deleted = $deleted; cloud_upload = $false }
        $report = Assert-CourseLocalPath (Join-Path $folderPath 'last-success.json') $folderPath
        $result | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
        return [pscustomobject]$result
    }
    finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            $temporary = Assert-CourseLocalPath $temporary $folderPath
            Remove-Item -LiteralPath $temporary
        }
        $lock.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CourseLocalBackup -Folder $OutputRoot -DoPrune $Prune.IsPresent -Days $RetentionDays | ConvertTo-Json
}
