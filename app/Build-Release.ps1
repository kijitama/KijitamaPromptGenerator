#requires -Version 7.0
param([string]$Revision = 'HEAD')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$files = @(
    'Kijitama Prompt Generator.exe', 'LICENSE',
    'app/Start.ps1', 'app/Core.ps1', 'app/History.ps1', 'app/Worker.ps1',
    'app/Main.xaml', 'app/Settings.xaml', 'app/History.xaml', 'app/Help.xaml', 'app/License.xaml',
    'app/LICENSE.txt', 'app/Launcher/launcher.json', 'app/Launcher/Kijitama.ico'
)
$releaseDir = Join-Path $PSScriptRoot 'release'
$null = [IO.Directory]::CreateDirectory($releaseDir)
$destination = Join-Path $releaseDir 'KijitamaPromptGenerator-Windows.zip'
$temp = Join-Path $releaseDir ([guid]::NewGuid().ToString('N') + '.tmp')
try {
    & git -C $project archive --format=zip "--output=$temp" $Revision -- @files
    if ($LASTEXITCODE -ne 0) { throw '配布ファイルを読み込めません。対象のコミットを確認してください。' }
    $archive = [IO.Compression.ZipFile]::OpenRead($temp)
    try {
        $entries = @($archive.Entries | Where-Object Name | ForEach-Object FullName)
        if (Compare-Object $files $entries) { throw 'ZIPの内容が配布ファイルの一覧と一致しません。' }
    } finally { $archive.Dispose() }
    [IO.File]::Move($temp, $destination, $true)
    Write-Output $destination
} finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
