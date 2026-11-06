#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Core.ps1')
$testRoot=Join-Path $PSScriptRoot ('run-' + [guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$passed=0
function Assert($Condition, $Message) { if (!$Condition) { throw $Message }; $script:passed++ }
function Assert-Throws([scriptblock]$Action, $Message) {
    $thrown=$false
    try { & $Action } catch { $thrown=$true }
    Assert $thrown $Message
}

$settings=[pscustomobject]@{OutputDirectory=$testRoot;CodexPath=(Join-Path $PSHOME 'pwsh.exe')}
Assert-AppSettings $settings
Write-AppJson (Join-Path $testRoot 'settings.json') $settings
$loaded=Read-AppSettings (Join-Path $testRoot 'settings.json')
Assert ($loaded.OutputDirectory -eq $testRoot) 'Settings did not round-trip.'
Assert-Throws { Assert-AppSettings ([pscustomobject]@{OutputDirectory='relative';CodexPath=$settings.CodexPath}) } 'Relative output directory accepted.'
Assert-Throws { Assert-AppSettings ([pscustomobject]@{OutputDirectory=$testRoot;CodexPath='missing.exe'}) } 'Missing executable accepted.'

$request=[pscustomobject]@{Mode='reference';Prompt='日本語 "quotes" & $(literal)';Source='';CodexPath=$settings.CodexPath}
$info=New-CodexStartInfo $request $testRoot 'C:\日本語 & space\画像.png'
Assert ($info.ArgumentList.Contains('C:\日本語 & space\画像.png')) 'Image argument was split.'
Assert (!$info.ArgumentList.Contains($request.Prompt)) 'Prompt should travel over stdin.'
Assert ((Get-GenerationInstruction $request).Contains($request.Prompt)) 'Prompt changed.'
Assert (!$info.UseShellExecute -and $info.CreateNoWindow) 'Unexpected shell/window execution.'

Add-Type -AssemblyName PresentationCore
$pixels=[byte[]](0,0,255,255)
$bitmap=[Windows.Media.Imaging.BitmapSource]::Create(1,1,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,4)
$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$sample=Join-Path $testRoot 'sample.png'; $stream=[IO.File]::Create($sample)
try { $encoder.Save($stream) } finally { $stream.Dispose() }
$local=Join-Path $testRoot 'local'; $null=[IO.Directory]::CreateDirectory($local)
$imported=Import-ReferenceImage $sample $local
Assert (Test-Path -LiteralPath $imported) 'Local image import failed.'
[IO.File]::WriteAllText((Join-Path $testRoot 'invalid.txt'),'not an image')
Assert-Throws { Import-ReferenceImage (Join-Path $testRoot 'invalid.txt') $local } 'Non-image input accepted.'

# A local HTTP server checks URL download and image decoding without external services.
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
$port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
$server=Start-ThreadJob -ArgumentList $listener,$sample -ScriptBlock {
    param($Listener,$Sample)
    $client=$Listener.AcceptTcpClient(); $stream=$client.GetStream()
    try {
        $buffer=[byte[]]::new(8192); $null=$stream.Read($buffer,0,$buffer.Length)
        $bytes=[IO.File]::ReadAllBytes($Sample)
        $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: image/png`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($header); $stream.Write($bytes)
    } finally { $stream.Dispose(); $client.Dispose(); $Listener.Stop() }
}
try {
    $remote=Join-Path $testRoot 'remote'; $null=[IO.Directory]::CreateDirectory($remote)
    $downloaded=Import-ReferenceImage "http://127.0.0.1:$port/sample.png" $remote
    Assert ((Get-FileHash $downloaded).Hash -eq (Get-FileHash $imported).Hash) 'URL image bytes changed.'
} finally { $listener.Stop(); $server | Wait-Job -Timeout 5 | Receive-Job -ErrorAction SilentlyContinue; $server | Remove-Job -Force }

$cancelled=Join-Path $testRoot 'cancelled'; $null=[IO.Directory]::CreateDirectory($cancelled)
$request.Mode='prompt'
Write-AppJson (Join-Path $cancelled 'request.json') $request
[IO.File]::WriteAllText((Join-Path $cancelled 'cancel'),'')
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File (Join-Path $PSScriptRoot '../Worker.ps1') -JobDirectory $cancelled
$status=Get-Content (Join-Path $cancelled 'status.json') -Raw | ConvertFrom-Json
Assert ($status.State -eq 'cancelled') 'Cancellation was not recorded.'

$failure=Join-Path $testRoot 'failure'; $null=[IO.Directory]::CreateDirectory($failure)
Write-AppJson (Join-Path $failure 'request.json') $request
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File (Join-Path $PSScriptRoot '../Worker.ps1') -JobDirectory $failure
$status=Get-Content (Join-Path $failure 'status.json') -Raw | ConvertFrom-Json
Assert ($status.State -eq 'failed') 'CLI failure was not recorded.'
Write-Output "PASS: $passed assertions. Evidence: $testRoot"
