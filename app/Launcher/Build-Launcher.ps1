param([string]$OutputPath)
$ErrorActionPreference='Stop'
if (!$OutputPath) { $OutputPath=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Kijitama Prompt Generator.exe' }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
if (!(Test-Path -LiteralPath $compiler)) { throw '.NET Framework C#コンパイラーが見つかりません。' }
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll ("/win32icon:"+(Join-Path $PSScriptRoot 'Kijitama.ico')) ("/out:"+$OutputPath) (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw '起動用exeのビルドに失敗しました。' }
Write-Output $OutputPath
