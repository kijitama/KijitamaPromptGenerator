#requires -Version 7.0
param([switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
trap {
    $null = [Windows.MessageBox]::Show($_.Exception.Message, 'Kijitama Prompt Generator — 起動エラー', 'OK', 'Error')
    exit 1
}
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'History.ps1')
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'pwsh.exe -STA -File Start.ps1 で起動してください。' }
$script:settingsFile = Join-Path $PSScriptRoot 'settings.json'
try { $script:settings = Read-AppSettings $script:settingsFile }
catch {
    $null = [Windows.MessageBox]::Show('設定を読み込めませんでした。設定画面で保存し直してください。' + "`n" + $_.Exception.Message, '設定の読み込み')
    $script:settings = New-DefaultAppSettings $script:settingsFile
}
$defaultOutput = Initialize-AppDataDirectory $PSScriptRoot
if ($script:settings.OutputDirectory -eq $defaultOutput) {
    $script:settings | Add-Member -NotePropertyName UseDefaultOutputDirectory -NotePropertyValue $true -Force
}
if (![IO.File]::Exists($script:settingsFile)) { Write-AppJson $script:settingsFile @{} }
$script:worker = $null; $script:jobDirectory = ''; $script:resultPrompt = ''; $script:jobMode = ''
function Read-Window($Name) {
    $reader = [Xml.XmlReader]::Create((Join-Path $PSScriptRoot ($Name + '.xaml')))
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
}
$script:window = Read-Window 'Main'
$script:window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'Launcher/Kijitama.ico'))
$script:ui = @{}
foreach ($name in @('SettingsButton','ModeTabs','ImagePrompt','IdeaPrompt','BrowseImage','ReferenceSource','ReferencePrompt','GenerateButton','CancelButton','StatusText','Progress','ResultText','ResultImage','CopyButton','UseButton','OpenFolderButton')) { $script:ui[$name]=$window.FindName($name) }
function Show-AppError($Message) { $script:ui.StatusText.Text = $Message }
function Show-Settings {
    $dialog = Read-Window 'Settings'; $dialog.Owner = $script:window
    $output = $dialog.FindName('OutputDirectory'); $codex = $dialog.FindName('CodexPath'); $errorText = $dialog.FindName('SettingsError')
    $output.Text = $script:settings.OutputDirectory; $codex.Text = $script:settings.CodexPath
    $dialog.FindName('BrowseOutput').Add_Click({
        $picker = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            $picker.Description = '生成結果の保存先を選択してください。'
            if ([IO.Directory]::Exists($output.Text)) { $picker.SelectedPath = $output.Text }
            if ($picker.ShowDialog() -eq 'OK') { $output.Text = $picker.SelectedPath }
        } finally { $picker.Dispose() }
    }.GetNewClosure())
    $dialog.FindName('BrowseCodex').Add_Click({
        $picker = [Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter = 'Codex CLI (codex.exe)|codex.exe|実行ファイル (*.exe)|*.exe'
        if ($picker.ShowDialog($dialog)) { $codex.Text = $picker.FileName }
    }.GetNewClosure())
    $dialog.FindName('DetectCodex').Add_Click((New-CodexDetectionHandler $codex $errorText))
    $dialog.FindName('SaveSettings').Add_Click({
        try {
            $candidate = [pscustomobject]@{OutputDirectory=$output.Text.Trim(); CodexPath=$codex.Text.Trim()}
            if (![IO.Path]::IsPathFullyQualified($candidate.OutputDirectory)) { throw '保存先は絶対パスで指定してください。' }
            $candidate.OutputDirectory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($candidate.OutputDirectory))
            $previousOutput = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($script:settings.OutputDirectory))
            Assert-AppSettings $candidate -ValidateOnly
            $copyData = $false
            if ($candidate.OutputDirectory -ne $previousOutput) {
                $message = "現在の情報をコピーしますか？`n`nコピー元：$previousOutput`nコピー先：$($candidate.OutputDirectory)`n`n「いいえ」は保存先だけを変更します。"
                $choice = [Windows.MessageBox]::Show($dialog,$message,'保存先の変更','YesNoCancel','Question','Cancel')
                if ($choice -eq 'Cancel') { return }
                $copyData = $choice -eq 'Yes'
            }
            if ($copyData) {
                Copy-AppDataDirectory $previousOutput $candidate.OutputDirectory
            }
            Assert-AppSettings $candidate
            $candidate | Add-Member -NotePropertyName UseDefaultOutputDirectory -NotePropertyValue ($candidate.OutputDirectory -eq $defaultOutput)
            Write-AppJson $script:settingsFile $candidate
            if ($candidate.OutputDirectory -ne $script:settings.OutputDirectory) { $script:jobDirectory = '' }
            $script:settings=$candidate; $dialog.DialogResult=$true
        } catch { $errorText.Text=$_.Exception.Message }
    })
    $dialog.FindName('ResetSettings').Add_Click({
        try {
            Write-AppJson $script:settingsFile @{}
            $dialog.Tag = 'reset'
            $dialog.DialogResult = $true
        } catch { $errorText.Text = $_.Exception.Message }
    })
    $null = $dialog.ShowDialog()
    if ($dialog.Tag -eq 'reset') { $script:window.Close(); return }
    $tab = $script:ui.ModeTabs.SelectedItem
    if ($dialog.DialogResult -and $tab.Content -is [Windows.Controls.UserControl]) {
        $mode = if ($tab.Name -eq 'ImageHistory') { 'image' } else { 'prompt' }
        $query = $tab.Content.FindName('Keyword').Text
        $tab.Content = New-HistoryView $mode $script:settings.OutputDirectory
        $tab.Content.FindName('Keyword').Text = $query
    }
}
function Set-Busy([bool]$Busy) {
    $script:ui.GenerateButton.IsEnabled = !$Busy; $script:ui.CancelButton.IsEnabled = $Busy
    $script:ui.SettingsButton.IsEnabled = !$Busy; $script:ui.ModeTabs.IsEnabled = !$Busy
    $script:ui.UseButton.IsEnabled = !$Busy -and !!$script:resultPrompt
    $script:ui.Progress.IsIndeterminate = $Busy
}
function Stop-Generation {
    if ($script:worker -and !$script:worker.HasExited) {
        [IO.File]::WriteAllText((Join-Path $script:jobDirectory 'cancel'), '')
        $script:ui.CancelButton.IsEnabled=$false; $script:ui.StatusText.Text='中止しています…'
        $script:cancelAt=[datetime]::UtcNow
    }
}
$script:cancelAt = $null
$script:ui.SettingsButton.Add_Click({ Show-Settings })
$window.FindName('CloseApp').Add_Click({ $script:window.Close() })
function Show-InfoPage([ValidateSet('Help','License')]$Page) {
    $helpHost = $window.FindName('HelpContent')
    if ($Page -eq 'Help' -and !$helpHost.Children.Count) {
        $null = $helpHost.Children.Add((Read-Window 'Help'))
    }
    $licenseHost = $window.FindName('LicenseContent')
    if ($Page -eq 'License' -and !$licenseHost.Children.Count) {
        $licenseView = Read-Window 'License'
        $licenseView.FindName('ProjectLicense').Text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LICENSE.txt'))
        $licenseFile = Join-Path $PSHOME 'LICENSE.txt'
        $licenseView.FindName('LocalLicense').Text = if ([IO.File]::Exists($licenseFile)) { [IO.File]::ReadAllText($licenseFile) } else { '原文は上のリンクからご確認ください。' }
        $licenseView.AddHandler([Windows.Documents.Hyperlink]::RequestNavigateEvent, [Windows.Navigation.RequestNavigateEventHandler]{
            param($sender,$eventArgs)
            $eventArgs.Handled = $true
            if ($eventArgs.Uri.Scheme -eq 'https') {
                try {
                    $info = [Diagnostics.ProcessStartInfo]::new($eventArgs.Uri.AbsoluteUri)
                    $info.UseShellExecute = $true
                    $null = [Diagnostics.Process]::Start($info)
                } catch { [Windows.MessageBox]::Show('リンクを開けませんでした。') }
            }
        })
        $null = $licenseHost.Children.Add($licenseView)
    }
    $window.FindName('InfoTitle').Text = $window.FindName($Page + 'Button').Content
    foreach ($name in 'Help','License') {
        $window.FindName($name + 'Content').Visibility = if ($name -eq $Page) { 'Visible' } else { 'Collapsed' }
    }
    $ui.ModeTabs.Visibility = 'Collapsed'
    $window.FindName('GenerationPanel').Visibility = 'Collapsed'
    $window.FindName('InfoPage').Visibility = 'Visible'
    $null = $window.FindName('BackFromInfo').Focus()
}
$window.FindName('HelpButton').Add_Click({ Show-InfoPage 'Help' })
$window.FindName('LicenseButton').Add_Click({ Show-InfoPage 'License' })
$window.FindName('BackFromInfo').Add_Click({
    $window.FindName('InfoPage').Visibility = 'Collapsed'
    $ui.ModeTabs.Visibility = 'Visible'
    $window.FindName('GenerationPanel').Visibility = if ($ui.ModeTabs.SelectedIndex -lt 3) { 'Visible' } else { 'Collapsed' }
})
$script:ui.ModeTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if ($eventArgs.OriginalSource -ne $sender) { return }
    $tab = $sender.SelectedItem
    $historyMode = switch ($tab.Name) { 'PromptHistory' { 'prompt' }; 'ImageHistory' { 'image' } }
    $panel = $script:window.FindName('GenerationPanel')
    if ($historyMode) {
        $panel.Visibility = 'Collapsed'
        $sender.Parent.RowDefinitions[1].Height = '*'
        $sender.Parent.RowDefinitions[2].Height = '0'
        $query = if ($tab.Content) { $tab.Content.FindName('Keyword').Text } else { '' }
        $tab.Content = New-HistoryView $historyMode $script:settings.OutputDirectory
        $tab.Content.FindName('Keyword').Text = $query
        return
    }
    $panel.Visibility = 'Visible'
    $sender.Parent.RowDefinitions[1].Height = 'Auto'
    $sender.Parent.RowDefinitions[2].Height = '*'
    $script:ui.GenerateButton.Content = if ($script:ui.ModeTabs.SelectedIndex -eq 0) { '画像を生成' } else { 'プロンプトを生成' }
})
$script:ui.BrowseImage.Add_Click({
    $picker = [Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter='画像 (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|すべてのファイル|*.*'
    if ($picker.ShowDialog($script:window)) { $script:ui.ReferenceSource.Text=$picker.FileName }
})
Register-PromptCopy $script:ui.CopyButton $script:ui.ResultText ($window.FindName('CopyNotice'))
$script:ui.UseButton.Add_Click({ $script:ui.ImagePrompt.Text=$script:resultPrompt; $script:ui.ModeTabs.SelectedIndex=0; $null=$script:ui.ImagePrompt.Focus() })
$script:ui.OpenFolderButton.Add_Click({
    try {
        $folder = if ($script:jobDirectory) { $script:jobDirectory } else { $script:settings.OutputDirectory }
        $null=[IO.Directory]::CreateDirectory($folder)
        $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$folder; $info.UseShellExecute=$true; $null=[Diagnostics.Process]::Start($info)
    } catch { Show-AppError $_.Exception.Message }
})
$script:ui.CancelButton.Add_Click({ Stop-Generation })
$script:ui.GenerateButton.Add_Click({
    try {
        Assert-AppSettings $script:settings
        $mode = @('image','prompt','reference')[$script:ui.ModeTabs.SelectedIndex]
        $prompt = switch ($mode) { 'image' {$script:ui.ImagePrompt.Text}; 'prompt' {$script:ui.IdeaPrompt.Text}; 'reference' {$script:ui.ReferencePrompt.Text} }
        $source = $script:ui.ReferenceSource.Text.Trim()
        if ($mode -eq 'reference') { if (!$source) { throw '参照画像を選択するか、画像URLを入力してください。' } }
        elseif ([string]::IsNullOrWhiteSpace($prompt)) { throw '生成したい内容を入力してください。' }
        if ($prompt.Length -gt 30000) { throw '入力内容は30,000文字以内にしてください。' }
        $directory = Join-Path $script:settings.OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $null=[IO.Directory]::CreateDirectory($directory)
        Write-AppJson (Join-Path $directory 'request.json') @{Mode=$mode; Prompt=$prompt; Source=$source; CodexPath=$script:settings.CodexPath; CreatedAt=[DateTimeOffset]::Now.ToString('o')}
        $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=Join-Path $PSHOME 'pwsh.exe'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        foreach ($arg in @('-NoProfile','-NonInteractive','-STA','-File',(Join-Path $PSScriptRoot 'Worker.ps1'),'-JobDirectory',$directory)) { $info.ArgumentList.Add($arg) }
        $script:worker=[Diagnostics.Process]::Start($info)
        $script:jobDirectory=$directory; $script:jobMode=$mode; $script:cancelAt=$null
        $script:resultPrompt=''; $script:ui.CopyButton.IsEnabled=$false
        $script:ui.ResultImage.Source=$null; $script:ui.ResultImage.Visibility='Collapsed'; $script:ui.ResultText.Visibility='Visible'; $script:ui.ResultText.Text='生成結果を待っています…'
        $script:ui.StatusText.Text='準備中…'; Set-Busy $true
        $script:timer.Start()
    } catch { Show-AppError $_.Exception.Message }
})
$script:timer=[Windows.Threading.DispatcherTimer]::new(); $script:timer.Interval=[TimeSpan]::FromMilliseconds(400)
$script:timer.Add_Tick({
    try {
        if (!$script:worker) { return }
        if ($script:cancelAt -and !$script:worker.HasExited -and ([datetime]::UtcNow-$script:cancelAt).TotalSeconds -gt 3) {
            $script:worker.Kill($true)
            Write-AppJson (Join-Path $script:jobDirectory 'status.json') @{State='cancelled';Message='処理を中止しました。';File=''}
        }
        $statusPath=Join-Path $script:jobDirectory 'status.json'
        $state=$null
        if (Test-Path -LiteralPath $statusPath) { try { $state=Get-Content -LiteralPath $statusPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { return } }
        if (!$script:worker.HasExited) { if ($state) { $script:ui.StatusText.Text=$state.Message }; return }
        $script:timer.Stop(); $script:worker.Dispose(); $script:worker=$null
        if (!$state -or $state.State -eq 'running') { throw '処理が予期せず終了しました。保存フォルダーのログを確認してください。' }
        $script:ui.StatusText.Text=$state.Message
        if ($state.State -eq 'complete') {
            $path=Join-Path $script:jobDirectory $state.File
            if ($script:jobMode -eq 'image') {
                $bitmap=[Windows.Media.Imaging.BitmapImage]::new(); $bitmap.BeginInit(); $bitmap.CacheOption='OnLoad'; $bitmap.UriSource=[uri]$path; $bitmap.EndInit(); $bitmap.Freeze()
                $script:ui.ResultImage.Source=$bitmap; $script:ui.ResultImage.Visibility='Visible'; $script:ui.ResultText.Visibility='Collapsed'
            } else {
                $script:resultPrompt=[IO.File]::ReadAllText($path); $script:ui.ResultText.Text=$script:resultPrompt; $script:ui.CopyButton.IsEnabled=$true
            }
        } else { $script:ui.ResultText.Text=$state.Message }
        Set-Busy $false
    } catch {
        $message=$_.Exception.Message; $script:timer.Stop()
        if ($script:worker) {
            if (!$script:worker.HasExited) { $script:worker.Kill($true) }
            $script:worker.Dispose(); $script:worker=$null
        }
        Set-Busy $false; Show-AppError $message
    }
})
$script:window.Add_Closing({
    $script:timer.Stop()
    if ($script:worker) {
        if (!$script:worker.HasExited) {
            [IO.File]::WriteAllText((Join-Path $script:jobDirectory 'cancel'), '')
            $script:worker.Kill($true)
            Write-AppJson (Join-Path $script:jobDirectory 'status.json') @{State='cancelled';Message='画面を閉じたため中止しました。';File=''}
        }
        $script:worker.Dispose()
    }
})
if ($SmokeTest) {
    $settingsWindow=Read-Window 'Settings'; $settingsWindow.Close()
    $script:window.Show(); $script:window.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $PSScriptRoot 'tests/main-preview.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    foreach ($name in @('PromptHistory','ImageHistory')) {
        $tab=$window.FindName($name); $tab.IsSelected=$true
        if ($tab.Content -isnot [Windows.Controls.UserControl]) { throw '一覧タブの表示に失敗しました。' }
        foreach ($page in 'Help','License') {
            $window.FindName($page+'Button').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if (!$window.FindName($page+'Content').IsVisible) { throw '案内ページを表示できませんでした。' }
        }
        $window.FindName('BackFromInfo').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if (!$tab.IsSelected -or !$ui.ModeTabs.IsVisible) { throw '元のタブに戻れませんでした。' }
    }
    $ui.ModeTabs.SelectedIndex=0
    if ($window.FindName('GenerationPanel').Visibility -ne 'Visible') { throw '生成画面の復帰に失敗しました。' }
    $window.FindName('CloseApp').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($window.IsVisible) { throw '閉じるボタンで終了できませんでした。' }
    Write-Output 'PASS: main/settings XAML loaded; main window shown and closed.'
} else { $null=$script:window.ShowDialog() }
