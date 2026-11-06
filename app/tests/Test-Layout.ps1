#requires -Version 7.0
$ErrorActionPreference='Stop'
$appRoot=Split-Path $PSScriptRoot -Parent
$installRoot=Split-Path $appRoot -Parent
$fixture=Join-Path $PSScriptRoot ('run-layout-' + [guid]::NewGuid().ToString('N'))
$fixtureApp=Join-Path $fixture 'app'
$null=[IO.Directory]::CreateDirectory((Join-Path $fixtureApp 'tests'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixtureApp 'Launcher'))
$config=Join-Path $fixtureApp 'Launcher/launcher.json'
Copy-Item -LiteralPath (Join-Path $appRoot 'Launcher/launcher.json') -Destination $config
Copy-Item -LiteralPath (Join-Path $appRoot 'Launcher/Kijitama.ico') -Destination (Join-Path $fixtureApp 'Launcher')
foreach($name in @('Start.ps1','Core.ps1','Worker.ps1','Main.xaml','Settings.xaml','History.ps1','History.xaml','License.xaml','LICENSE.txt','Help.xaml')) {
    Copy-Item -LiteralPath (Join-Path $appRoot $name) -Destination (Join-Path $fixtureApp $name)
}
$exe=Join-Path $fixture 'Kijitama Prompt Generator.exe'
Copy-Item -LiteralPath (Join-Path $installRoot 'Kijitama Prompt Generator.exe') -Destination $exe
$data=Join-Path $fixture 'data'
if(Test-Path -LiteralPath $data){throw 'Fixture must start without data.'}
$process=Start-Process -FilePath $exe -ArgumentList '--smoke-test' -WindowStyle Hidden -Wait -PassThru
if($process.ExitCode -ne 0){throw 'First launch failed.'}
if(!(Test-Path -LiteralPath $data -PathType Container)){throw 'First launch did not create data.'}
$settingsPath=Join-Path $fixtureApp 'settings.json'
if ([IO.File]::ReadAllText($settingsPath).Trim() -ne '{}'){throw 'First launch persisted implicit defaults.'}
# A subsequent launch must preserve existing generated content.
$marker=Join-Path $data 'existing-result.txt'
[IO.File]::WriteAllText($marker,'preserve me')
$process=Start-Process -FilePath $exe -ArgumentList '--smoke-test' -WindowStyle Hidden -Wait -PassThru
if($process.ExitCode -ne 0 -or [IO.File]::ReadAllText($marker) -ne 'preserve me'){throw 'Existing data was not preserved.'}
if ([IO.File]::ReadAllText($settingsPath).Trim() -ne '{}'){throw 'Restart repopulated empty settings.'}
$unexpected=@(Get-ChildItem -LiteralPath $fixture -Force | Where-Object {$_.Name -notin @('app','data','Kijitama Prompt Generator.exe')})
if($unexpected.Count){throw 'Files leaked into the install root.'}
Write-Output 'PASS: first-launch data creation, app-local settings, existing data preserved, clean install root.'
$alternate=Join-Path $fixtureApp '別の 起動.ps1'
[IO.File]::WriteAllText($alternate, '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "launched.txt"), "OK")')
[IO.File]::WriteAllText($config, '{"script":"app/別の 起動.ps1"}')
$process=Start-Process -FilePath $exe -WindowStyle Hidden -Wait -PassThru
$signal=Join-Path $fixtureApp 'launched.txt'
$deadline=[datetime]::UtcNow.AddSeconds(15)
while (!(Test-Path -LiteralPath $signal) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $signal)) { throw 'JSON-selected script did not run.' }
Write-Output 'PASS: normal EXE launch used the alternate script from JSON.'
