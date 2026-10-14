function Get-DingMoreWindow([IntPtr]$mainHandle,[uint32]$ExpectedProcessId) {
    Assert-DingNavNotCancelled
    $handle=Get-DingNavForeground
    if($handle -eq [IntPtr]::Zero){return $null}
    $window=Get-WindowDetails $handle
    if(-not $window.IsDingTalk -or $window.ProcessId -ne $ExpectedProcessId){throw '打开更多后前台不是原钉钉进程，停止导航。'}
    if(-not $window.Visible){return $null}
    if((Get-DingNavRoot $handle).Current.AutomationId -cne $Config.ApplicationCenter.MoreWindowAutomationId){return $null}
    Assert-DingNavContext $handle $ExpectedProcessId $Config.ApplicationCenter.MoreWindowAutomationId
    return $handle
}
function Invoke-DingAppCenterNavigation([IntPtr]$mainHandle) {
    Assert-DingNavContext $mainHandle
    $direct=Find-NavButton $mainHandle $Config.ApplicationCenter.AutomationId $Config.ApplicationCenter.Name -AllowMissing
    if($null -ne $direct){
        $testResult['AppCenterRoute']='Direct'
        $testResult.Actions+=Invoke-NavButton $mainHandle $Config.ApplicationCenter.AutomationId $Config.ApplicationCenter.Name -MouseClick
        return
    }
    if(-not $Config.ApplicationCenter.MoreAutomationId){throw '旧应用中心入口不存在，且配置未启用已验证的更多入口。'}
    $mainWindow=Get-WindowDetails $mainHandle
    if(-not $mainWindow.IsDingTalk -or -not $mainWindow.Visible -or $mainWindow.ProcessId -le 0){throw '钉钉主窗口身份无效，停止导航。'}
    $expectedProcessId=[uint32]$mainWindow.ProcessId
    $testResult['AppCenterRoute']='More'
    $testResult.Actions+=Invoke-NavButton $mainHandle $Config.ApplicationCenter.MoreAutomationId $Config.ApplicationCenter.MoreName -MouseClick -ExpectedProcessId $expectedProcessId
    for($attempt=0;$attempt -lt $Config.Timing.LabelAttempts;$attempt++){
        $popupHandle=Get-DingMoreWindow $mainHandle $expectedProcessId
        if($null -ne $popupHandle){
            $item=Find-NavButton $popupHandle $Config.ApplicationCenter.MoreItemAutomationId $Config.ApplicationCenter.Name -AllowMissing
            if($null -ne $item){
                Save-TargetImage $popupHandle '00-more.png'
                Save-VisibleControls $popupHandle '00-more-controls.json'
                $script:PreNavigationHandles=@(Get-DingNavWindowHandles)
                # 保存证据后再次查找控件并核对前台、原进程和菜单根，绝不复用旧坐标。
                $testResult.Actions+=Invoke-NavButton $popupHandle $Config.ApplicationCenter.MoreItemAutomationId $Config.ApplicationCenter.Name -MouseClick -ExpectedProcessId $expectedProcessId -ExpectedRootAutomationId $Config.ApplicationCenter.MoreWindowAutomationId
                return
            }
        }
        if($attempt+1 -lt $Config.Timing.LabelAttempts){Wait-DingNavPoll $Config.Timing.LabelWaitMilliseconds}
    }
    throw '更多菜单中的应用中心未在限定次数内就绪，未执行后续导航。'
}
function Get-DingMarketBrowser([IntPtr]$handle) {
    $window=Get-WindowDetails $handle
    if(-not $window.IsDingTalk -or -not $window.Visible){throw '应用市场不属于已确认的钉钉窗口。'}
    Assert-DingNavContext $handle $window.ProcessId
    if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw '当前不是可操作的默认桌面。'}
    $browsers=@(Get-DingNavMatches $handle 'browser_window' | Where-Object {
        $_.Current.Name -ceq 'AI应用服务市场' -and -not $_.Current.IsOffscreen -and $_.Current.IsEnabled -and
        $_.Current.BoundingRectangle.Width -gt 300 -and $_.Current.BoundingRectangle.Height -gt 200
    })
    if($browsers.Count -ne 1){throw '未找到唯一的 AI应用服务市场容器，停止操作。'}
    return $browsers[0]
}
function Get-DingMarketOcrRegions([string]$Path,[string]$Text) {
    $regions=@(Get-ExactOcrRegions $Path $Text)
    if($regions.Count -gt 0){return $regions}
    # 小字号及浅灰提示可能漏字；最多尝试两种确定性增强，仍要求逐字匹配。
    $source=[Drawing.Image]::FromFile($Path)
    try{
        if([Math]::Max($source.Width,$source.Height)*2 -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension){return @()}
        foreach($contrast in @(1,2)){
            $scaled=New-Object Drawing.Bitmap ($source.Width*2),($source.Height*2)
            $graphics=[Drawing.Graphics]::FromImage($scaled)
            $attributes=New-Object Drawing.Imaging.ImageAttributes
            $matrix=New-Object Drawing.Imaging.ColorMatrix
            $matrix.Matrix00=$contrast;$matrix.Matrix11=$contrast;$matrix.Matrix22=$contrast
            $matrix.Matrix40=1-$contrast;$matrix.Matrix41=1-$contrast;$matrix.Matrix42=1-$contrast
            $attributes.SetColorMatrix($matrix)
            $scaledPath=Join-Path (Split-Path $Path -Parent) ([IO.Path]::GetFileNameWithoutExtension($Path)+'.ocr-2x-c'+$contrast+'.png')
            try{
                $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($source,(New-Object Drawing.Rectangle(0,0,$scaled.Width,$scaled.Height)),0,0,$source.Width,$source.Height,[Drawing.GraphicsUnit]::Pixel,$attributes)
                $scaled.Save($scaledPath,[Drawing.Imaging.ImageFormat]::Png)
            }finally{$attributes.Dispose();$graphics.Dispose();$scaled.Dispose()}
            $regions=@(Get-ExactOcrRegions $scaledPath $Text)
            if($regions.Count -gt 0){
                foreach($region in $regions){[pscustomobject]@{Text=$region.Text;X=$region.X/2;Y=$region.Y/2;Width=$region.Width/2;Height=$region.Height/2}}
                return
            }
        }
    }finally{$source.Dispose()}
}
function Find-DingMarketTarget([IntPtr]$handle,[string]$Name,[string]$ImageName,[switch]$Editor) {
    $browser=Get-DingMarketBrowser $handle
    $browserBox=$browser.Current.BoundingRectangle
    $element=Find-ExactVisibleLabel $handle $Name
    if($null -ne $element -and (-not $Editor -or $element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit)){
        $box=$element.Current.BoundingRectangle
        if($box.Left -lt $browserBox.Left -or $box.Top -lt $browserBox.Top -or $box.Right -gt $browserBox.Right -or $box.Bottom -gt $browserBox.Bottom){throw '目标控件不在已确认的应用市场内。'}
        return [pscustomobject]@{X=$box.X;Y=$box.Y;Width=$box.Width;Height=$box.Height;Element=$element;Method='UIA'}
    }
    Save-TargetImage $handle $ImageName
    $position=New-Object DingRpa+Rect
    if(-not [DingRpa]::GetWindowRect($handle,[ref]$position)){throw '不能读取应用市场窗口位置。'}
    $regions=@(Get-DingMarketOcrRegions (Join-Path $resultDir $ImageName) $Name | Where-Object {
        $_.X+$position.Left -ge $browserBox.Left -and $_.Y+$position.Top -ge $browserBox.Top -and
        $_.X+$_.Width+$position.Left -le $browserBox.Right -and $_.Y+$_.Height+$position.Top -le $browserBox.Bottom
    })
    if($regions.Count -gt 1){throw ('应用市场文字存在重复匹配：'+$Name)}
    if($regions.Count -eq 0){return $null}
    $region=$regions[0]
    return [pscustomobject]@{X=$position.Left+$region.X;Y=$position.Top+$region.Y;Width=$region.Width;Height=$region.Height;Element=$null;Method='Exact OCR text match'}
}
function Find-DingLowCodeWithRecovery([IntPtr]$handle) {
    $target=Find-DingMarketTarget $handle $Config.LowCode.Name '01-app-center.png'
    if($null -ne $target){return $target}
    # 应用市场复用旧页面时保留滚动位置；仅在已验证容器内向上滚动并重新识别。
    for($round=0;$round -lt $Config.Scroll.MaxWheelRounds;$round++){
        $browser=Get-DingMarketBrowser $handle
        $box=$browser.Current.BoundingRectangle
        [DingRpa]::WheelUp($handle,[int]($box.X+$box.Width/2),[int]($box.Y+$box.Height/2))
        Wait-DingNavPoll $Config.Scroll.WheelWaitMilliseconds
        $testResult['AppCenterRecoveryScrolls']=$round+1
        $target=Find-DingMarketTarget $handle $Config.LowCode.Name '01-app-center.png'
        if($null -ne $target){return $target}
    }
    Save-VisibleControls $handle 'app-center-controls.json'
    throw '向上滚动后仍无法唯一识别低代码平台，停止导航。'
}
function Assert-DingSearchFocus([IntPtr]$handle,$Target) {
    $browser=Get-DingMarketBrowser $handle
    if($null -ne $Target.Element){
        if(-not $Target.Element.Current.HasKeyboardFocus){throw '应用市场搜索框未取得键盘焦点。'}
        return
    }
    $focus=[DingRpa]::GetMenuState($handle).Focus
    if($focus -eq [IntPtr]::Zero -or ($focus -ne $handle -and [DingRpa]::GetAncestor($focus,2) -ne $handle)){throw '搜索输入的键盘焦点不属于当前钉钉窗口。'}
    $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
    if($null -eq $focused){throw '不能确认应用市场键盘焦点。'}
    $focusedBox=$focused.Current.BoundingRectangle;$browserBox=$browser.Current.BoundingRectangle
    if($focusedBox.Width -le 0 -or $focusedBox.Height -le 0 -or $focusedBox.Left -lt $browserBox.Left -or $focusedBox.Top -lt $browserBox.Top -or $focusedBox.Right -gt $browserBox.Right -or $focusedBox.Bottom -gt $browserBox.Bottom){throw '键盘焦点未处于已确认的应用市场内。'}
}
function Get-DingSearchValue([IntPtr]$handle,$Target) {
    $null=Get-DingMarketBrowser $handle
    if($null -ne $Target.Element){
        $pattern=$null
        if(-not $Target.Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern) -or $pattern.Current.IsReadOnly){throw '搜索输入框无法读取或只读。'}
        return [string]$pattern.Current.Value
    }
    Save-TargetImage $handle '04-search-input.png'
    $position=New-Object DingRpa+Rect
    if(-not [DingRpa]::GetWindowRect($handle,[ref]$position)){throw '不能读取搜索输入位置。'}
    $regions=@(Get-DingMarketOcrRegions (Join-Path $resultDir '04-search-input.png') $Config.SearchInput.Text | Where-Object {
        [Math]::Abs(($_.Y+$position.Top)-$Target.Y) -le [Math]::Max(8,$Target.Height/2) -and
        $_.X+$position.Left -ge $Target.X-8 -and $_.X+$_.Width+$position.Left -le $Target.X+$Target.Width+8
    })
    if($regions.Count -eq 1){return [string]$Config.SearchInput.Text}
    return $null
}
function Invoke-DingSearchClick([IntPtr]$handle,$Target) {
    [DingRpa]::ClickPoint($handle,[int]($Target.X+$Target.Width/2),[int]($Target.Y+$Target.Height/2))
}
function Send-DingSearchText([IntPtr]$handle,$Target,[string]$Text) {
    foreach($character in $Text.ToCharArray()){
        Assert-DingSearchFocus $handle $Target
        [DingRpa]::TypeUnicodeText($handle,[string]$character)
    }
}
function Invoke-DingSearchInput([IntPtr]$handle) {
    if($null -eq $Config.SearchInput){return}
    $testResult['SearchInput']=[ordered]@{Text=$Config.SearchInput.Text;InputAttempted=$false;Verified=$false;Submitted=$false;Method=$null}
    $target=Find-DingMarketTarget $handle $Config.SearchInput.Name '04-search-before.png' -Editor
    if($null -eq $target){throw '无法唯一识别应用市场搜索框，未输入 test。'}
    if($null -ne $target.Element -and (Get-DingSearchValue $handle $target) -cne ''){throw '搜索框已有文字，停止输入以免覆盖或追加。'}
    Invoke-DingSearchClick $handle $target
    Wait-DingNavPoll $Config.Timing.LabelWaitMilliseconds
    Assert-DingSearchFocus $handle $target
    # 点击后再次确认空框占位文字/可读值；不清空已有内容，不使用回车提交。
    if($null -ne $target.Element){
        if((Get-DingSearchValue $handle $target) -cne ''){throw '搜索框在输入前已发生变化。'}
    }else{
        $fresh=Find-DingMarketTarget $handle $Config.SearchInput.Name '04-search-focused.png' -Editor
        if($null -eq $fresh -or [Math]::Abs($fresh.X-$target.X) -gt 4 -or [Math]::Abs($fresh.Y-$target.Y) -gt 4){throw '搜索框位置或占位文字在输入前发生变化。'}
    }
    Assert-DingSearchFocus $handle $target
    $testResult.SearchInput.InputAttempted=$true
    $testResult.SearchInput.Method=$target.Method
    Write-JsonFile $testResult 'result.json'
    Send-DingSearchText $handle $target $Config.SearchInput.Text
    Wait-DingNavPoll $Config.Timing.LabelWaitMilliseconds
    if((Get-DingSearchValue $handle $target) -cne $Config.SearchInput.Text){throw '已尝试输入 test，但无法核验搜索框结果；保留现场，不自动重试。'}
    $testResult.SearchInput.Verified=$true
    $testResult.Actions+=[pscustomobject]@{Name='搜索框输入';Text=$Config.SearchInput.Text;Method=$target.Method;Verified=$true;Submitted=$false}
    Save-TargetImage $handle '04-search-input.png'
    Write-Host '已在应用市场搜索框输入 test，逐字核验通过。'
}
function Invoke-AppCenterFlow([IntPtr]$mainHandle) {
    $script:PreNavigationHandles=@([DingRpa]::ListWindows()|ForEach-Object {$_.Handle})
    $null=Save-FocusSnapshot 'before-app-center'
    Invoke-DingAppCenterNavigation $mainHandle
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
        $target=Find-DingLowCodeWithRecovery $appHandle
        $null=Get-DingMarketBrowser $appHandle
        [DingRpa]::ClickPoint($appHandle,[int]($target.X+$target.Width/2),[int]($target.Y+$target.Height/2))
        $clickMethod=$target.Method
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
    Invoke-DingSearchInput $pageHandle
    if($lowCodeSelected -and $bottomConfirmed){$testResult.Status='Passed';$testResult.Reason='已通过控件选中状态和滚动位置确认。'}
    else{$testResult.Status='NeedsVisualReview';$testResult.Reason='已执行应用中心、低代码平台、向下滚动及配置的搜索输入；请结合截图确认页面选择和底部状态。'}
    Write-Host $testResult.Reason
}
