function Invoke-AppCenterFlow([IntPtr]$mainHandle) {
    $script:PreNavigationHandles=@([DingRpa]::ListWindows()|ForEach-Object {$_.Handle})
    $null=Save-FocusSnapshot 'before-app-center'
    $testResult.Actions+=Invoke-NavButton $mainHandle $Config.ApplicationCenter.AutomationId $Config.ApplicationCenter.Name -MouseClick
    Start-Sleep -Milliseconds $Config.Timing.PageLoadMilliseconds
    $appHandle=Get-DingForeground -Stage 'after-app-center' -WaitMilliseconds $Config.Timing.FocusWaitMilliseconds -RecoverNavigation
    Save-TargetImage $appHandle '01-app-center.png'
    $label=$null
    for($attempt=0;$attempt -lt $Config.Timing.LabelAttempts;$attempt++){
        $appHandle=Get-DingForeground
        $label=Find-ExactVisibleLabel $appHandle $Config.LowCode.Name
        if($null -ne $label){break}
        Start-Sleep -Milliseconds $Config.Timing.LabelWaitMilliseconds
    }
    $lowCodeSelected=$false
    $script:PreNavigationHandles=@([DingRpa]::ListWindows()|ForEach-Object {$_.Handle})
    if($null -ne $label){
        $box=$label.Current.BoundingRectangle
        [DingRpa]::ClickPoint($appHandle,[int]($box.X+$box.Width/2),[int]($box.Y+$box.Height/2));$clickMethod='Mouse click on current UIA bounds'
        Start-Sleep -Milliseconds $Config.Timing.LabelWaitMilliseconds
        try{$selection=$null;if($label.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection)){$lowCodeSelected=([System.Windows.Automation.SelectionItemPattern]$selection).Current.IsSelected}}catch{}
    }else{
        Save-TargetImage $appHandle '01-app-center.png'
        $regions=@(Get-ExactOcrRegions (Join-Path $resultDir '01-app-center.png') $Config.LowCode.Name)
        if($regions.Count -ne 1){Save-VisibleControls $appHandle 'app-center-controls.json';throw ('无法唯一识别“低代码平台”，已保存应用中心截图。OCR 匹配数：'+$regions.Count)}
        $position=New-Object DingRpa+Rect
        $null=[DingRpa]::GetWindowRect($appHandle,[ref]$position)
        $region=$regions[0]
        [DingRpa]::ClickPoint($appHandle,[int]($position.Left+$region.X+$region.Width/2),[int]($position.Top+$region.Y+$region.Height/2))
        $clickMethod='Exact OCR text match'
    }
    $testResult.Actions+=[pscustomobject]@{Name=$Config.LowCode.Name;Method=$clickMethod}
    Write-Host '已点击低代码平台，等待页面加载。'
    Start-Sleep -Milliseconds $Config.Timing.PageLoadMilliseconds
    $pageHandle=Get-DingForeground -Stage 'after-low-code' -WaitMilliseconds $Config.Timing.FocusWaitMilliseconds -RecoverNavigation
    Save-TargetImage $pageHandle '02-low-code-before-scroll.png'
    $pageRoot=[System.Windows.Automation.AutomationElement]::FromHandle($pageHandle)
    $windowBox=$pageRoot.Current.BoundingRectangle
    $scrollCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty,$true)
    $scrollables=@(foreach($element in $pageRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,$scrollCondition)){
        try{$box=$element.Current.BoundingRectangle;$pattern=[System.Windows.Automation.ScrollPattern]$element.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            if(-not $element.Current.IsOffscreen -and $pattern.Current.VerticallyScrollable -and $box.Width -gt $windowBox.Width*0.45 -and $box.Height -gt $windowBox.Height*0.3){[pscustomobject]@{Element=$element;Pattern=$pattern;Area=$box.Width*$box.Height}}
        }catch{}
    })
    $bottomConfirmed=$false;$scrollMethod='';$iterations=0
    if($scrollables.Count -gt 0){
        $scroller=$scrollables|Sort-Object Area -Descending|Select-Object -First 1
        for($round=0;$round -lt 3;$round++){
            if((Get-DingForeground) -ne $pageHandle){throw '滚动前页面切换到了其他钉钉窗口，停止操作。'}
            if(([DingRpa]::GetAsyncKeyState(0x1b) -band 0x8000) -ne 0){throw '检测到 Escape，停止操作。'}
            $scroller.Pattern.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll,100)
            Start-Sleep -Milliseconds 800
        }
        $bottomConfirmed=$scroller.Pattern.Current.VerticalScrollPercent -ge 99.9
        $scrollMethod='UIA ScrollPattern';$iterations=3
    }else{
        $scrollX=[int]($windowBox.X+$windowBox.Width*0.78);$scrollY=[int]($windowBox.Y+$windowBox.Height*0.72)
        $documentCondition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
        $documents=$pageRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants,$documentCondition)
        $largeDocuments=@(foreach($doc in $documents){$box=$doc.Current.BoundingRectangle;if(-not $doc.Current.IsOffscreen -and $box.Width -gt $windowBox.Width*0.45 -and $box.Height -gt $windowBox.Height*0.3){[pscustomobject]@{Box=$box;Area=$box.Width*$box.Height}}})
        if($largeDocuments.Count -gt 0){$documentBox=($largeDocuments|Sort-Object Area -Descending|Select-Object -First 1).Box;$scrollX=[int]($documentBox.X+$documentBox.Width*0.7);$scrollY=[int]($documentBox.Y+$documentBox.Height*0.7)}
        $lastHash='';$unchanged=0
        for($round=0;$round -lt $Config.Scroll.MaxWheelRounds;$round++){
            [DingRpa]::WheelDown($pageHandle,$scrollX,$scrollY)
            Start-Sleep -Milliseconds $Config.Scroll.WheelWaitMilliseconds
            Save-TargetImage $pageHandle '03-bottom.png'
            $hash=(Get-FileHash -LiteralPath (Join-Path $resultDir '03-bottom.png') -Algorithm SHA256).Hash
            if($hash -eq $lastHash){$unchanged++}else{$unchanged=0}
            $lastHash=$hash;$iterations++
            if($unchanged -ge $Config.Scroll.UnchangedFrameLimit){break}
        }
        $scrollMethod='Mouse wheel; final screenshot requires verification'
    }
    Save-TargetImage $pageHandle '03-bottom.png'
    Save-VisibleControls $pageHandle 'low-code-controls.json'
    $testResult['LowCodeSelectionConfirmed']=$lowCodeSelected
    $testResult['BottomConfirmedByScrollPattern']=$bottomConfirmed
    $testResult['ScrollMethod']=$scrollMethod
    $testResult['ScrollIterations']=$iterations
    $testResult.Actions+=[pscustomobject]@{Name='滚动到底部';Method=$scrollMethod;Iterations=$iterations}
    if($lowCodeSelected -and $bottomConfirmed){$testResult.Status='Passed';$testResult.Reason='已通过控件选中状态和滚动位置确认。'}
    else{$testResult.Status='NeedsVisualReview';$testResult.Reason='已执行应用中心、低代码平台、向下滚动流程；请结合截图确认页面选择和底部状态。'}
    Write-Host $testResult.Reason
}
