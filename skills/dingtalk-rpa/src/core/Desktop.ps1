function Write-JsonFile($value, $name) {
    ConvertTo-Json -InputObject $value -Depth 10 | Set-Content -LiteralPath (Join-Path $resultDir $name) -Encoding UTF8
}
function Get-DingNavForeground {return [DingRpa]::GetForegroundWindow()}
function Get-DingNavRoot([IntPtr]$handle) {return [System.Windows.Automation.AutomationElement]::FromHandle($handle)}
function Get-DingNavWindowHandles {return @([DingRpa]::ListWindows()|ForEach-Object {$_.Handle})}
function Assert-DingNavNotCancelled {
    if(([DingRpa]::GetAsyncKeyState(0x1b) -band 0x8000) -ne 0){throw [OperationCanceledException]::new('检测到 Escape，停止操作。')}
}
function Wait-DingNavPoll([int]$Milliseconds) {
    Assert-DingNavNotCancelled
    Start-Sleep -Milliseconds $Milliseconds
}
function Assert-DingNavContext([IntPtr]$handle,[uint32]$ExpectedProcessId=0,[string]$ExpectedRootAutomationId) {
    Assert-DingNavNotCancelled
    if((Get-DingNavForeground) -ne $handle){throw '钉钉失去前台焦点，停止操作。'}
    if($ExpectedProcessId -gt 0){
        $window=Get-WindowDetails $handle
        if(-not $window.IsDingTalk -or -not $window.Visible -or $window.ProcessId -ne $ExpectedProcessId){throw '钉钉导航窗口进程归属已变化，停止操作。'}
    }
    if($ExpectedRootAutomationId -and (Get-DingNavRoot $handle).Current.AutomationId -cne $ExpectedRootAutomationId){throw '钉钉更多菜单身份已变化，停止操作。'}
}
function Get-DingNavMatches([IntPtr]$handle,[string]$id) {
    $uiRoot=Get-DingNavRoot $handle
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$id)
    return @($uiRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition))
}
function Find-NavButton([IntPtr]$handle,[string]$id,[string]$name,[switch]$AllowMissing) {
    $matches=@(Get-DingNavMatches $handle $id)
    if($matches.Count -eq 0 -and $AllowMissing){return $null}
    if($matches.Count -ne 1){throw ('导航控件不是唯一匹配：'+$id)}
    $button=$matches[0]
    if($button.Current.Name -ne $name -or $button.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button -or -not $button.Current.IsEnabled -or $button.Current.IsOffscreen){throw ('导航控件校验失败：'+$name)}
    if($button.Current.BoundingRectangle.Width -le 0 -or $button.Current.BoundingRectangle.Height -le 0){throw ('导航控件位置无效：'+$name)}
    return $button
}
function Invoke-DingNavMouseClick([IntPtr]$handle,$Button) {
    $bounds=$Button.Current.BoundingRectangle
    [DingRpa]::ClickPoint($handle,[int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))
}
function Invoke-NavButton([IntPtr]$handle,[string]$id,[string]$name,[switch]$MouseClick,[uint32]$ExpectedProcessId=0,[string]$ExpectedRootAutomationId) {
    Assert-DingNavContext $handle $ExpectedProcessId $ExpectedRootAutomationId
    $button=Find-NavButton $handle $id $name
    Assert-DingNavContext $handle $ExpectedProcessId $ExpectedRootAutomationId
    $invoke=$null
    if(-not $MouseClick -and $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$invoke)) {
        ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
        $method='UIA InvokePattern'
    } else {
        Invoke-DingNavMouseClick $handle $button
        $method='Mouse click on current UIA bounds'
    }
    Write-Host ('已操作导航：'+$name+'（'+$method+'）')
    return [pscustomobject]@{Name=$name;AutomationId=$id;Method=$method}
}
function Read-NavState([IntPtr]$handle,[string]$id,[string]$name) {
    $button=Find-NavButton $handle $id $name
    $selected=$null; $pattern=$null
    if($button.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$selected=([System.Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected}
    $uiRoot=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $headingCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'ConvTabTopBarV2Class.stackedWidget.pageTabTitle.labelTitle')
    $heading=$uiRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$headingCondition)
    $messageHeadingVisible=$null -ne $heading -and -not $heading.Current.IsOffscreen -and $heading.Current.Name -eq '消息'
    return [pscustomobject]@{Navigation=$name;IsSelected=$selected;MessageHeadingVisible=$messageHeadingVisible}
}
function Get-WindowDetails([IntPtr]$handle) {
    $window=[DingRpa]::ReadWindow($handle)
    $process=$null
    if($window.ProcessId -gt 0){$process=Get-Process -Id $window.ProcessId -ErrorAction SilentlyContinue}
    $executable=$null
    if($null -ne $process){try{$executable=$process.Path}catch{}}
    $box=New-Object DingRpa+Rect
    $null=[DingRpa]::GetWindowRect($handle,[ref]$box)
    $isDing=$false
    if($null -ne $process -and $process.ProcessName -eq 'DingTalk'){
        $isDing=$script:DingProcessIds -contains [int]$window.ProcessId
        if(-not $isDing -and $executable){$isDing=$script:DingExecutablePaths -contains $executable}
    }
    return [pscustomobject]@{Handle=$window.Handle;ProcessId=$window.ProcessId;ProcessName=$process.ProcessName;ExecutablePath=$executable;Title=$window.Title;ClassName=$window.ClassName;Visible=$window.Visible;IsDingTalk=$isDing;Width=$box.Right-$box.Left;Height=$box.Bottom-$box.Top}
}
function Save-FocusSnapshot([string]$stage) {
    $foreground=Get-WindowDetails ([DingRpa]::GetForegroundWindow())
    $dingIds=@(Get-Process DingTalk -ErrorAction SilentlyContinue|ForEach-Object {$_.Id})
    $dingWindows=@([DingRpa]::ListWindows()|Where-Object {$_.Visible -and $dingIds -contains [int]$_.ProcessId})
    $snapshot=[pscustomobject]@{Time=(Get-Date -Format o);Stage=$stage;Foreground=$foreground;DingTalkWindows=$dingWindows}
    $script:FocusHistory.Add($snapshot)
    Write-JsonFile $script:FocusHistory.ToArray() 'focus-history.json'
    return $foreground
}
function Get-DingForeground([string]$Stage='active',[int]$WaitMilliseconds=0,[switch]$RecoverNavigation) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $foreground=$null
    do {
        if(([DingRpa]::GetAsyncKeyState(0x1b) -band 0x8000) -ne 0){throw '检测到 Escape，停止操作。'}
        $foreground=Get-WindowDetails ([DingRpa]::GetForegroundWindow())
        if($foreground.IsDingTalk -and $foreground.Visible){
            $script:LastDingHandle=[IntPtr]$foreground.Handle
            if($WaitMilliseconds -gt 0){$null=Save-FocusSnapshot $Stage}
            return [IntPtr]$foreground.Handle
        }
        if($timer.ElapsedMilliseconds -ge $WaitMilliseconds){break}
        Start-Sleep -Milliseconds 250
    }while($true)
    $foreground=Save-FocusSnapshot ($Stage+'-focus-mismatch')
    # Recover only if focus returned to this script's own console, or there is no foreground.
    # An unrelated app remains a stop condition; do not redirect input into it.
    $runnerConsole=$script:RunnerForeground -and $foreground.Handle -eq $script:RunnerForeground.Handle -and $foreground.ProcessId -eq $script:RunnerForeground.ProcessId -and $foreground.ClassName -eq 'ConsoleWindowClass'
    if($RecoverNavigation -and ($foreground.Handle -eq 0 -or $runnerConsole)){
        $current=@(foreach($window in [DingRpa]::ListWindows()){
            if($window.Visible -and $window.Title -and $window.ClassName -notmatch 'Shadow|water_mask'){
                $details=Get-WindowDetails ([IntPtr]$window.Handle)
                if($details.IsDingTalk -and $details.Width -ge 300 -and $details.Height -ge 200){$details}
            }
        })
        $newWindows=@($current|Where-Object {$script:PreNavigationHandles -notcontains $_.Handle})
        $candidate=$null
        if($newWindows.Count -eq 1){$candidate=$newWindows[0]}
        elseif($newWindows.Count -eq 0){
            $retained=@($current|Where-Object {$_.Handle -eq $script:LastDingHandle.ToInt64()})
            if($retained.Count -eq 1){$candidate=$retained[0]}
        }
        if($null -ne $candidate){
            $candidateHandle=[IntPtr]$candidate.Handle
            $null=[DingRpa]::SetForegroundWindow($candidateHandle)
            Start-Sleep -Milliseconds 600
            if([DingRpa]::GetForegroundWindow() -eq $candidateHandle){
                $script:LastDingHandle=$candidateHandle
                $null=Save-FocusSnapshot ($Stage+'-restored')
                Write-Host ('已重新激活钉钉窗口：'+$candidate.Title)
                return $candidateHandle
            }
        }
    }
    $description='句柄={0}；进程={1}({2})；标题={3}；类名={4}' -f $foreground.Handle,$foreground.ProcessName,$foreground.ProcessId,$foreground.Title,$foreground.ClassName
    throw ('等待窗口切换后，前台仍未确认为钉钉。'+$description+'。详情已保存至 focus-history.json。')
}
function Find-ExactVisibleLabel([IntPtr]$handle,[string]$name) {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
    $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
    $visible=@(foreach($element in $all){if(-not $element.Current.IsOffscreen -and $element.Current.IsEnabled -and $element.Current.BoundingRectangle.Width -gt 0){$element}})
    $interactive=@($visible|Where-Object {$_.Current.ControlType.ProgrammaticName -match 'Button|Hyperlink|TabItem|ListItem|TreeItem|RadioButton'})
    if($interactive.Count -gt 0){$visible=$interactive}
    if($visible.Count -gt 1){throw ('找到多个同名入口，停止点击：'+$name)}
    if($visible.Count -eq 1){return $visible[0]}
    return $null
}
function Wait-RpaWinRt($operation,[type]$resultType) {
    $task=$script:RpaAsTask.MakeGenericMethod($resultType).Invoke($null,@($operation))
    if(-not $task.Wait(15000)){throw '文字识别操作超时。'}
    return $task.Result
}
function Get-ExactOcrRegions([string]$path,[string]$expected) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null=[Windows.Storage.Streams.IRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $null=[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
    $null=[Windows.Graphics.Imaging.SoftwareBitmap,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
    $null=[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
    $null=[Windows.Media.Ocr.OcrResult,Windows.Foundation,ContentType=WindowsRuntime]
    $script:RpaAsTask=[System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'}|Select-Object -First 1
    $file=Wait-RpaWinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream=Wait-RpaWinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder=Wait-RpaWinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap=Wait-RpaWinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        try {
            $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
            if($null -eq $engine){throw '本机没有可用的 OCR 识别引擎。'}
            $ocr=Wait-RpaWinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            foreach($line in $ocr.Lines){
                $words=@(foreach($word in $line.Words){$word})
                for($start=0;$start -lt $words.Count;$start++){
                    $joined='';$left=[double]::PositiveInfinity;$top=[double]::PositiveInfinity;$right=0.0;$bottom=0.0
                    for($end=$start;$end -lt $words.Count;$end++){
                        $joined+=($words[$end].Text -replace '\s','')
                        $box=$words[$end].BoundingRect
                        $left=[Math]::Min($left,$box.X);$top=[Math]::Min($top,$box.Y);$right=[Math]::Max($right,$box.X+$box.Width);$bottom=[Math]::Max($bottom,$box.Y+$box.Height)
                        if($joined -ceq $expected){[pscustomobject]@{Text=$expected;X=$left;Y=$top;Width=$right-$left;Height=$bottom-$top};break}
                        if($joined.Length -ge $expected.Length){break}
                    }
                }
            }
        }finally{$bitmap.Dispose()}
    }finally{$stream.Dispose()}
}
function Save-VisibleControls([IntPtr]$handle,[string]$filename) {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
    $queue=New-Object 'System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]'
    $queue.Enqueue($root);$total=1;$items=@();$timer=[Diagnostics.Stopwatch]::StartNew()
    while($queue.Count -gt 0 -and $items.Count -lt 400 -and $timer.Elapsed.TotalSeconds -lt 10){
        $element=$queue.Dequeue()
        try{
            $current=$element.Current
            if(-not $current.IsOffscreen){$items+=[pscustomobject]@{Name=$current.Name;Type=$current.ControlType.ProgrammaticName;AutomationId=$current.AutomationId;Bounds=$current.BoundingRectangle.ToString()}}
            $child=$walker.GetFirstChild($element)
            while($null -ne $child -and $total -lt 400 -and $timer.Elapsed.TotalSeconds -lt 10){$queue.Enqueue($child);$total++;$child=$walker.GetNextSibling($child)}
        }catch{}
    }
    Write-JsonFile $items $filename
}
