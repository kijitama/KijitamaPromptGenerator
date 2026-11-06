#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Core.ps1')
$root = Join-Path $PSScriptRoot ('run-detection-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$local = Join-Path $root 'Local'; $roaming = Join-Path $root 'Roaming'
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
Assert (!(Find-Codex -LocalAppData $local -RoamingAppData $roaming -SkipPath)) 'Missing executable should return empty.'
$older = Join-Path $local 'OpenAI/Codex/bin/old/codex.exe'
$newer = Join-Path $local 'OpenAI/Codex/bin/new/codex.exe'
foreach ($file in @($older,$newer)) { $null=[IO.Directory]::CreateDirectory((Split-Path $file)); [IO.File]::WriteAllText($file,'fixture') }
[IO.File]::WriteAllText((Join-Path (Split-Path $older) 'codex-code-mode-host.exe'),'fixture')
Assert ((Find-Codex -LocalAppData $local -RoamingAppData $roaming -SkipPath) -eq $older) 'Incomplete runtime should be skipped.'
[IO.File]::WriteAllText((Join-Path (Split-Path $newer) 'codex-code-mode-host.exe'),'fixture')
[IO.Directory]::SetLastWriteTimeUtc((Split-Path $older),[datetime]::UtcNow.AddDays(-1))
Assert ((Find-Codex -LocalAppData $local -RoamingAppData $roaming -SkipPath) -eq $newer) 'Latest desktop runtime was not found without PATH.'
$platform = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64' } else { 'x86_64' }
$package = if ($platform -eq 'aarch64') { 'codex-win32-arm64' } else { 'codex-win32-x64' }
$npm = Join-Path $roaming "npm/node_modules/@openai/codex/node_modules/@openai/$package/vendor/$platform-pc-windows-msvc/codex/codex.exe"
$null=[IO.Directory]::CreateDirectory((Split-Path $npm)); [IO.File]::WriteAllText($npm,'fixture')
Assert ((Find-Codex -LocalAppData (Join-Path $root 'empty') -RoamingAppData $roaming -SkipPath) -eq $npm) 'npm executable was not found.'
# Execute the exact button callback after its creating scope has returned.
$pathControl=[pscustomobject]@{Text='original'}; $messageControl=[pscustomobject]@{Text=''}
$handler = & { New-CodexDetectionHandler $pathControl $messageControl }
& $handler
Assert (!$messageControl.Text) ('Button callback failed: ' + $messageControl.Text)
Assert (Test-Path -LiteralPath $pathControl.Text -PathType Leaf) 'Button did not populate the executable path.'
Write-Output ('PASS: missing install, desktop without PATH, npm layout, and button callback. Detected: ' + $pathControl.Text)
