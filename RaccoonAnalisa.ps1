# Raccoon Analisa: sempre baixa uma copia nova da ultima release publica.
# Publique este arquivo na raiz de main. Na release: ZIP portatil + manifest.json.
# Compativel com Windows PowerShell 5.1 e PowerShell 7; nao requer SDK.
[CmdletBinding()]
param(
    [string]$RepositorioGitHub = 'ithalloCoury/RaccoonAnalisa',
    [string]$Tag = 'latest',
    [switch]$SomenteBaixar,
    [switch]$Administrador,
    [string]$DiretorioBase = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RaccoonAnalisa\Releases')
)

& {
param($RepositorioGitHub, $Tag, [switch]$SomenteBaixar, [switch]$Administrador, $DiretorioBase)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Raccoon Analisa requer Windows x64.' }
if ($RepositorioGitHub -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$') { throw 'Repositorio invalido. Use usuario/repositorio.' }
if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'Tag invalida.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$releaseBase = 'https://github.com/' + $RepositorioGitHub + '/releases/'
$manifestBase = if ($Tag -eq 'latest') { $releaseBase + 'latest/download/' } else { $releaseBase + 'download/' + [Uri]::EscapeDataString($Tag) + '/' }
try {
    $manifest = Invoke-RestMethod -Uri ($manifestBase + 'manifest.json?fresh=' + [Guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec 45 -Headers @{'Cache-Control'='no-cache'}
} catch { throw ('Nao foi possivel obter a release. Publique manifest.json e o ZIP na release publica marcada como Latest. ' + $_.Exception.Message) }
if ($manifest.schema -ne 1 -or $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $manifest.url -ne 'RaccoonAnalisa-Portatil-win-x64.zip') { throw 'Manifesto invalido.' }
$releaseTag = if ($Tag -eq 'latest') { 'v' + $manifest.version } else { $Tag }
$archiveUrl = $releaseBase + 'download/' + [Uri]::EscapeDataString($releaseTag) + '/RaccoonAnalisa-Portatil-win-x64.zip'
$cacheRoot = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DiretorioBase)).TrimEnd('\')
if ($cacheRoot -eq [IO.Path]::GetPathRoot($cacheRoot).TrimEnd('\')) { throw 'Escolha uma pasta dedicada ao Raccoon, nao a raiz do disco.' }
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
if ((Get-Item -LiteralPath $cacheRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A pasta de instalacao nao pode ser um link.' }
$rootPrefix = $cacheRoot + '\'
$dataRoot = Join-Path $cacheRoot 'Dados'
if ((Test-Path -LiteralPath $dataRoot) -and ((Get-Item -LiteralPath $dataRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A pasta de dados nao pode ser um link.' }
$token = [Guid]::NewGuid().ToString('N')
$download = Join-Path $cacheRoot ($token + '.zip')
$staging = Join-Path $cacheRoot ('staging-' + $token)
$destination = Join-Path $cacheRoot ($manifest.version + '-' + $manifest.sha256.Substring(0,12).ToLowerInvariant() + '-' + $token.Substring(0,8))
function Assert-Child([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($full) -ne $cacheRoot) { throw 'Operacao fora da pasta dedicada bloqueada.' }
}
function Assert-NoLinks([string]$Folder) {
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($Folder)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $current -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Link encontrado; pasta preservada: ' + $item.FullName) }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
}
function Prepare-RunningApp {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.',('RaccoonAnalisa.Update.'+$sid+'.'+$session),[IO.Pipes.PipeDirection]::InOut)
    try {
        try { $pipe.Connect(700) } catch [TimeoutException] { return }
        $writer = New-Object IO.StreamWriter($pipe)
        $writer.AutoFlush = $true
        $writer.WriteLine('prepare-update')
        $reader = New-Object IO.StreamReader($pipe)
        $reply = $reader.ReadLineAsync()
        if (-not $reply.Wait(20000) -or $reply.Result -ne 'closed') { throw 'A instancia aberta nao concluiu o encerramento. Use Sair do programa e execute novamente.' }
        Start-Sleep -Milliseconds 500
    } finally { $pipe.Dispose() }
}
$allowed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
if (@($manifest.files).Count -lt 2 -or @($manifest.files).Count -gt 4000) { throw 'Lista de arquivos invalida.' }
foreach ($file in $manifest.files) {
    $name = ([string]$file.path).Replace('\','/')
    $full = [IO.Path]::GetFullPath((Join-Path $staging $name))
    if (-not $full.StartsWith($staging+'\',[StringComparison]::OrdinalIgnoreCase) -or $name.Contains(':') -or $name -match '(^|/)(Dados|\.\.?)(/|$)' -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $allowed.ContainsKey($name)) { throw 'Caminho ou hash invalido no manifesto.' }
    $allowed.Add($name,[string]$file.sha256)
}
if (-not $allowed.ContainsKey('RaccoonAnalisa.exe')) { throw 'Executavel ausente no manifesto.' }
try {
    Write-Host ('Baixando uma copia nova do Raccoon Analisa ' + $manifest.version + '...')
    Invoke-WebRequest -Uri ($archiveUrl+'?fresh='+$token) -OutFile $download -UseBasicParsing -TimeoutSec 300 -Headers @{'Cache-Control'='no-cache'}
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $manifest.sha256) { throw 'SHA-256 divergente. A versao anterior foi preservada.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($download)
    try {
        [long]$totalSize = 0
        $entries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($archive.Entries.Count -gt 4000) { throw 'Pacote excedeu o limite de arquivos.' }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\','/')
            $entryPath = [IO.Path]::GetFullPath((Join-Path $staging $name))
            $totalSize += $entry.Length
            if (-not $entryPath.StartsWith($staging+'\',[StringComparison]::OrdinalIgnoreCase) -or $name.Contains(':') -or $totalSize -gt 1500MB -or ($entry.ExternalAttributes -band 0x400) -ne 0 -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Pacote contem caminho, link ou tamanho invalido.' }
            if (-not $name.EndsWith('/')) {
                if (-not $allowed.ContainsKey($name) -or -not $entries.Add($name)) { throw 'Arquivo extra ou duplicado no pacote.' }
            }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($download,$staging)
    foreach ($name in $allowed.Keys) {
        $file = Join-Path $staging $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $allowed[$name]) { throw 'Arquivo extraido nao passou na verificacao.' }
    }
    Assert-Child $staging
    Assert-Child $destination
    Move-Item -LiteralPath $staging -Destination $destination
    # Never remove the previous installation until the new download has been verified.
    Prepare-RunningApp
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    Assert-NoLinks $dataRoot
    $oldFolders = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -Force | Where-Object {
        $_.FullName -ne $destination -and $_.Name -match '^\d+\.\d+\.\d+-[0-9a-fA-F]{12}(-[0-9a-fA-F]{8})?$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'RaccoonAnalisa.exe') -PathType Leaf)
    } | Sort-Object LastWriteTime -Descending)
    # Check locks before removing any part of a running legacy installation.
    foreach ($old in $oldFolders) {
        Assert-Child $old.FullName
        if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Instalacao antiga e um link; exclusao bloqueada.' }
        Assert-NoLinks $old.FullName
        foreach ($file in Get-ChildItem -LiteralPath $old.FullName -Recurse -File -Force) {
            try { $handle = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $handle.Dispose() }
            catch { throw ('Feche a versao antiga em Sair do programa e execute novamente. Nenhuma instalacao anterior foi removida: ' + $_.Exception.Message) }
        }
    }
    foreach ($old in $oldFolders) {
        Assert-Child $old.FullName
        if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Instalacao antiga e um link; exclusao bloqueada.' }
        Assert-NoLinks $old.FullName
        $oldData = Join-Path $old.FullName 'Dados'
        if (Test-Path -LiteralPath $oldData) {
            foreach ($file in Get-ChildItem -LiteralPath $oldData -Recurse -File -Force) {
                $relative = $file.FullName.Substring($oldData.Length+1)
                $target = Join-Path $dataRoot $relative
                if (Test-Path -LiteralPath $target) {
                    if ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) { continue }
                    $target = Join-Path (Join-Path (Join-Path $dataRoot 'Importados') $old.Name) $relative
                }
                if (-not [IO.Path]::GetFullPath($target).StartsWith($dataRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Destino de dados invalido.' }
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
        }
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force }
        catch { throw ('A copia nova foi baixada e seus dados foram preservados. Feche a versao antiga em Sair do programa e execute o comando novamente. ' + $_.Exception.Message) }
    }
    Write-Host ('Versao ' + $manifest.version + ' renovada. Dados preservados em: ' + $dataRoot)
    if (-not $SomenteBaixar) {
        $launch = @{FilePath=(Join-Path $destination 'RaccoonAnalisa.exe'); WorkingDirectory=$destination; WindowStyle='Normal'; ArgumentList=@('--data-directory',('"'+$dataRoot+'"'))}
        if ($Administrador) { $launch.Verb = 'RunAs' }
        Start-Process @launch | Out-Null
    }
} finally {
    if (Test-Path -LiteralPath $download) { Assert-Child $download; Remove-Item -LiteralPath $download -Force }
    if (Test-Path -LiteralPath $staging) { Assert-Child $staging; Assert-NoLinks $staging; Remove-Item -LiteralPath $staging -Recurse -Force }
}
} -RepositorioGitHub $RepositorioGitHub -Tag $Tag -SomenteBaixar:$SomenteBaixar -Administrador:$Administrador -DiretorioBase $DiretorioBase
