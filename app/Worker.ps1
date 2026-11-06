#requires -Version 7.0
param([Parameter(Mandatory)][string]$JobDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
$process = $null; $stdout = $null; $stderr = $null
function Set-JobState($State, $Message, $File = '') {
    Write-AppJson (Join-Path $JobDirectory 'status.json') @{ State=$State; Message=$Message; File=$File }
}
try {
    $request = Get-Content -LiteralPath (Join-Path $JobDirectory 'request.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Set-JobState 'running' '準備中…'
    if ($request.Mode -eq 'image' -and !(Test-Path -LiteralPath (Join-Path (Split-Path $request.CodexPath) 'codex-code-mode-host.exe') -PathType Leaf)) {
        throw '選択したCodexには画像生成に必要な補助ファイルがありません。設定の「自動検出」で選び直し、保存してください。'
    }
    $reference = ''
    if ($request.Mode -eq 'reference') { $reference = Import-ReferenceImage $request.Source $JobDirectory }
    if (Test-Path -LiteralPath (Join-Path $JobDirectory 'cancel')) { throw '処理を中止しました。' }
    $info = New-CodexStartInfo $request $JobDirectory $reference
    $started = [datetime]::UtcNow
    $process = [Diagnostics.Process]::Start($info)
    $stdout = [IO.File]::Open((Join-Path $JobDirectory 'events.jsonl'), 'Create', 'Write', 'ReadWrite')
    $stderr = [IO.File]::Open((Join-Path $JobDirectory 'diagnostic.log'), 'Create', 'Write', 'ReadWrite')
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $process.StandardInput.Write((Get-GenerationInstruction $request)); $process.StandardInput.Close()
    Set-JobState 'running' 'Codexで生成中…（数分かかる場合があります）'
    while (!$process.WaitForExit(250)) {
        if (Test-Path -LiteralPath (Join-Path $JobDirectory 'cancel')) { throw '処理を中止しました。' }
        if (([datetime]::UtcNow - $started).TotalMinutes -gt 15) { throw '15分以内に完了しませんでした。時間をおいて再試行してください。' }
        if ($stdout.Length -gt 32MB -or $stderr.Length -gt 4MB) { throw 'Codexの出力が上限を超えました。' }
    }
    $null=$outTask.GetAwaiter().GetResult(); $null=$errTask.GetAwaiter().GetResult()
    $stdout.Dispose(); $stdout=$null; $stderr.Dispose(); $stderr=$null
    if ($process.ExitCode -ne 0) { throw 'Codexの実行に失敗しました。ログイン状態とCodexパスを確認してください。保存フォルダーのdiagnostic.logに詳細があります。' }
    if (Test-Path -LiteralPath (Join-Path $JobDirectory 'cancel')) { throw '処理を中止しました。' }
    if ($request.Mode -eq 'image') {
        $threadIds = @(Get-Content -LiteralPath (Join-Path $JobDirectory 'events.jsonl') | ForEach-Object {
            try { $entry = $_ | ConvertFrom-Json; if ($entry.type -eq 'thread.started') { $entry.thread_id } } catch { }
        } | Select-Object -Unique)
        if ($threadIds.Count -ne 1 -or $threadIds[0] -notmatch '^[0-9a-fA-F-]{36}$') { throw '生成画像の保存場所を確認できませんでした。events.jsonlを確認してください。' }
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $folder = Join-Path $codexHome ('generated_images/' + $threadIds[0])
        $files = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.png' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $started.AddSeconds(-2) })
        if ($files.Count -ne 1) {
            $eventsText = [IO.File]::ReadAllText((Join-Path $JobDirectory 'events.jsonl'))
            if ($eventsText -match 'host executable was not found|failed to spawn code-mode host') {
                throw '選択したCodexには画像生成に必要な補助ファイルがありません。設定の「自動検出」で選び直し、保存してください。'
            }
            $answerPath = Join-Path $JobDirectory 'response.txt'
            $answer = if (Test-Path -LiteralPath $answerPath) { [IO.File]::ReadAllText($answerPath).Trim() } else { '' }
            if ($answer.Length -gt 500) { $answer = $answer.Substring(0,500) + '…' }
            throw ('画像ファイルを取得できませんでした。Codexの回答：' + $answer)
        }
        if ($files[0].Length -gt 40MB) { throw '生成画像が40MBを超えています。' }
        Add-Type -AssemblyName PresentationCore
        $stream = [IO.File]::OpenRead($files[0].FullName)
        try { $null = [Windows.Media.Imaging.BitmapDecoder]::Create($stream,'PreservePixelFormat','OnLoad') } finally { $stream.Dispose() }
        Copy-Item -LiteralPath $files[0].FullName -Destination (Join-Path $JobDirectory 'image.png')
        Set-JobState 'complete' '画像を保存しました。' 'image.png'
    } else {
        $response = Join-Path $JobDirectory 'response.txt'
        if (!(Test-Path -LiteralPath $response) -or [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($response))) { throw 'プロンプトが返りませんでした。ログを確認してください。' }
        Copy-Item -LiteralPath $response -Destination (Join-Path $JobDirectory 'prompt.txt')
        Set-JobState 'complete' 'プロンプトを保存しました。' 'prompt.txt'
    }
} catch {
    $state = if (Test-Path -LiteralPath (Join-Path $JobDirectory 'cancel')) { 'cancelled' } else { 'failed' }
    Set-JobState $state $_.Exception.Message
} finally {
    if ($process) { if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
    if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
}
