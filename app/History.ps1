function Register-PromptCopy($Button, $PromptBox, $Notice) {
    $PromptBox.Add_TextChanged({ $Notice.Text = '' }.GetNewClosure())
    $Button.Add_Click({
        $Notice.Text = ''
        try {
            [Windows.Clipboard]::SetText($PromptBox.Text)
            $null = $PromptBox.Focus()
            $PromptBox.SelectAll()
            $Notice.Text = 'プロンプトをコピーしました'
        } catch {
            $Notice.Text = 'コピーできませんでした。もう一度お試しください。'
        }
    }.GetNewClosure())
}

function Read-HistoryBitmap([string]$Path, [int]$Width) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        $bitmap.CacheOption = 'OnLoad'
        $bitmap.DecodePixelWidth = $Width
        $bitmap.StreamSource = $stream
        $bitmap.EndInit()
        $bitmap.Freeze()
        return $bitmap
    } finally { $stream.Dispose() }
}

function New-HistoryView([ValidateSet('prompt','image')]$Mode, [string]$Directory) {
    $view = Read-Window 'History'
    $list = $view.FindName('Records')
    $body = $view.FindName('Body')
    $preview = $view.FindName('Preview')
    $copy = $view.FindName('CopyText')
    $isImage = $Mode -eq 'image'
    $view.FindName('Heading').Text = if ($isImage) { '生成画像一覧' } else { '生成プロンプト一覧' }

    $bodyRow = $body.Parent.RowDefinitions[1]
    if ($isImage) {
        $view.FindName('ImageRow').Height = '*'
        $bodyRow.Height = '110'
    } else { $bodyRow.Height = '*' }
    $filename = if ($isImage) { 'image.png' } else { 'prompt.txt' }
    foreach ($job in (Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name -Descending)) {
        $file = Join-Path $job.FullName $filename
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $status = Get-Content -LiteralPath (Join-Path $job.FullName 'status.json') -Raw | ConvertFrom-Json
            if ($status.State -ne 'complete') { continue }
            $result = if ($isImage) {
                try { [string](Get-Content -LiteralPath (Join-Path $job.FullName 'request.json') -Raw | ConvertFrom-Json).Prompt } catch { '' }
            } else { [IO.File]::ReadAllText($file) }
            $thumbnail = if ($isImage) { Read-HistoryBitmap $file 80 }
            $stamp = [datetime]::MinValue
            $prefix = ($job.Name -split '-')[0..1] -join '-'
            $label = if ([datetime]::TryParseExact($prefix,'yyyyMMdd-HHmmss',$null,'None',[ref]$stamp)) { $stamp.ToString('yyyy/MM/dd HH:mm:ss') } else { $job.Name }
            $summary = ($result -replace '\s+', ' ').Trim()
            if (!$summary) { $summary = $filename }
            $null = $list.Items.Add([pscustomobject]@{ Stamp=$label; Summary=$summary; Text=$result; Path=$file; Thumbnail=$thumbnail; ThumbVisibility=$(if($isImage){'Visible'}else{'Collapsed'}) })
        } catch { continue }
    }
    $view.FindName('CountLabel').Text = "$($list.Items.Count) 件"
    $readBitmap = ${function:Read-HistoryBitmap}
    $list.Add_SelectionChanged({
        $item = $list.SelectedItem
        if (!$item) { return }
        $preview.Source = $null
        $body.Text = $item.Text
        $copy.IsEnabled = ![string]::IsNullOrWhiteSpace($body.Text)
        if ($isImage) {
            try { $preview.Source = & $readBitmap $item.Path 1000 }
            catch { $body.Text = '画像を読み込めませんでした。'; $copy.IsEnabled = $false }
        }
    }.GetNewClosure())
    Register-PromptCopy $copy $body ($view.FindName('CopyNotice'))
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    else { $body.Text = if ($isImage) { '保存済みの生成画像はありません。' } else { '保存済みの生成プロンプトはありません。' } }
    $keyword = $view.FindName('Keyword')
    $clear = $view.FindName('ClearKeyword')
    $countLabel = $view.FindName('CountLabel')
    $total = $list.Items.Count
    $emptyMessage = $body.Text
    $keyword.Add_TextChanged({
        $query = $keyword.Text.Trim()
        $clear.IsEnabled = $keyword.Text.Length -gt 0
        if ($query) {
            $terms = $query -split '\s+'
            $list.Items.Filter = [Predicate[object]]{
                param($record)
                foreach ($term in $terms) {
                    if ($record.Text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
                }
                return $true
            }.GetNewClosure()
        } else { $list.Items.Filter = $null }
        $countLabel.Text = if ($query) { "$($list.Items.Count) 件（全 $total 件）" } else { "$total 件" }
        if ($list.Items.Count) {
            if ($list.SelectedIndex -lt 0) { $list.SelectedIndex = 0 }
        } else {
            $preview.Source = $null
            $copy.IsEnabled = $false
            $body.Text = if ($total) { 'キーワードに一致する結果はありません。' } else { $emptyMessage }
        }
    }.GetNewClosure())
    $clear.Add_Click({ $keyword.Clear(); $null = $keyword.Focus() }.GetNewClosure())
    return $view
}
