# 两个抖音 Skill 共用的 Chrome 身份、前台、UIA、输入与证据原语。
# 先加载 Urls.ps1、DingRpa、UIAutomationClient/UIAutomationTypes 及 shared/core/Screenshot.ps1。
# 调用方提供 Config.Browser、Config.Selectors、Config.Timing、RunDirectory、VideoEvidence，
# 并提供 Assert-RpaRunning、Wait-RpaDelay、Write-RpaStateJson；本文件不启动任务或发布评论。
function Initialize-DouyinBrowser {
    if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw '当前不是已解锁的 Default 桌面，停止原生 RPA。'}
    $null=[DingRpa]::SetProcessDPIAware()
    $candidates=@([DingRpa]::ListWindows() | Where-Object {
        $_.Visible -and $_.Title.Contains($Config.Browser.TitleContains) -and (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).ProcessName -eq $Config.Browser.ProcessName
    })
    if($candidates.Count -ne 1){throw '请打开唯一的抖音 Chrome 窗口；不能从零个或多个候选中猜测目标。'}
    $script:BrowserWindow=$candidates[0]
    $script:BrowserHandle=[IntPtr]$script:BrowserWindow.Handle
    $script:ExpectedVideoId=$null
    Ensure-DouyinForeground
}
function Assert-DouyinIdentity {
    Assert-RpaRunning
    if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw '桌面已锁定或切换，停止输入。'}
    $window=[DingRpa]::ReadWindow($script:BrowserHandle)
    if($window.ProcessId -ne $script:BrowserWindow.ProcessId -or (Get-Process -Id $window.ProcessId -ErrorAction SilentlyContinue).ProcessName -ne 'chrome'){throw 'Chrome 目标进程或句柄已变化。'}
}
function Get-DouyinRoot {
    Assert-DouyinIdentity
    return [System.Windows.Automation.AutomationElement]::FromHandle($script:BrowserHandle)
}
function Get-UiaValue($Element) {
    $pattern=$null
    if($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){return ([System.Windows.Automation.ValuePattern]$pattern).Current.Value}
    return $null
}
function Get-DouyinAddressElement {
    $root=Get-DouyinRoot
    $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$Config.Selectors.AddressAutomationId)))
    if($nodes.Count -ne 1){throw '未找到唯一的 Chrome 地址栏。'}
    return $nodes[0]
}
function Test-UiaInBrowser($Element) {
    $c=$Element.Current;$b=$c.BoundingRectangle
    if($c.IsOffscreen -or -not $c.IsEnabled -or $b.IsEmpty -or $b.Width -le 0 -or $b.Height -le 0){return $false}
    $r=New-Object DingRpa+Rect
    if(-not [DingRpa]::GetWindowRect($script:BrowserHandle,[ref]$r)){return $false}
    return ($b.X+$b.Width -gt $r.Left -and $b.X -lt $r.Right -and $b.Y+$b.Height -gt $r.Top -and $b.Y -lt $r.Bottom)
}
function Get-DouyinNodes($Root) {
    if($null -eq $Root){$Root=Get-DouyinRoot}
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    if($all.Count -gt 10000){throw '控件树超出数量上限。'}
    return $all
}
function Find-DouyinNamed([string]$Name,$Root) {
    if($null -eq $Root){$Root=Get-DouyinRoot}
    $all=$Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)))
    return @($all | Where-Object {Test-UiaInBrowser $_})
}
function Assert-DouyinPage {
    $address=Get-UiaValue (Get-DouyinAddressElement)
    $null=ConvertTo-DouyinUri $address
    if($script:ExpectedVideoId){
        if((Get-DouyinVideoId $address) -ne $script:ExpectedVideoId){throw '视频已改变；禁止把草稿发到其他视频。'}
        $root=Get-DouyinRoot
        $documents=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)))
        $matching=@($documents | Where-Object {(Test-UiaInBrowser $_) -and (Get-DouyinVideoId (Get-UiaValue $_)) -eq $script:ExpectedVideoId})
        if($matching.Count -ne 1){throw '网页文档与地址栏的视频编号未同时通过校验。'}
    }
}
function Ensure-DouyinForeground {
    Assert-DouyinIdentity
    if([DingRpa]::GetForegroundWindow() -ne $script:BrowserHandle){
        if(-not $Config.Browser.AutoActivate){throw 'Chrome 失去焦点，自动切回未开启。'}
        $before=[DingRpa]::ReadWindow([DingRpa]::GetForegroundWindow())
        $method=[DingRpa]::ActivateTarget($script:BrowserHandle,$script:BrowserWindow.ProcessId)
        if([DingRpa]::GetForegroundWindow() -ne $script:BrowserHandle){
            Assert-DouyinIdentity
            $root=Get-DouyinRoot;$windowPattern=$null
            if($root.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern,[ref]$windowPattern)){
                $pattern=[System.Windows.Automation.WindowPattern]$windowPattern
                $originalState=$pattern.Current.WindowVisualState
                $pattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
                Wait-RpaDelay 0.25
                if($originalState -eq [System.Windows.Automation.WindowVisualState]::Maximized){$pattern.SetWindowVisualState($originalState);Wait-RpaDelay 0.15}
                if([DingRpa]::GetForegroundWindow() -eq $script:BrowserHandle){$method='UIAWindowRestore'}
            }
        }
        $entry=[ordered]@{Time=(Get-Date -Format o);Method=$method;Before=$before;After=[DingRpa]::ReadWindow([DingRpa]::GetForegroundWindow())}
        Add-Content -LiteralPath (Join-Path $script:RunDirectory 'focus.jsonl') -Value (ConvertTo-Json $entry -Compress -Depth 5) -Encoding UTF8
    }
    if([DingRpa]::GetForegroundWindow() -ne $script:BrowserHandle){throw '自动切回 Chrome 未成功，已停止输入。'}
    Assert-DouyinPage
}
function Invoke-DouyinClick($Element) {
    Ensure-DouyinForeground
    if(-not (Test-UiaInBrowser $Element)){throw '目标控件不可见或不可用。'}
    $b=$Element.Current.BoundingRectangle
    $window=New-Object DingRpa+Rect
    $null=[DingRpa]::GetWindowRect($script:BrowserHandle,[ref]$window)
    $left=[Math]::Max($b.Left,$window.Left+1);$right=[Math]::Min($b.Right,$window.Right-1)
    $top=[Math]::Max($b.Top,$window.Top+1);$bottom=[Math]::Min($b.Bottom,$window.Bottom-1)
    if($right -le $left -or $bottom -le $top){throw '控件不在窗口可点击范围。'}
    [DingRpa]::ClickPoint($script:BrowserHandle,[int](($left+$right)/2),[int](($top+$bottom)/2))
}
function Open-DouyinUrl([string]$Url) {
    $null=ConvertTo-DouyinUri $Url
    $script:ExpectedVideoId=$null
    Ensure-DouyinForeground
    $address=Get-DouyinAddressElement
    $address.SetFocus()
    Wait-RpaDelay 0.15
    if(-not $address.Current.HasKeyboardFocus -or [DingRpa]::GetForegroundWindow() -ne $script:BrowserHandle){throw '地址栏未获得焦点。'}
    ([System.Windows.Automation.ValuePattern]$address.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($Url)
    [DingRpa]::PressEnter($script:BrowserHandle)
    Wait-RpaDelay 1
    $wanted=ConvertTo-DouyinUri $Url
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        $current=ConvertTo-DouyinUri (Get-UiaValue (Get-DouyinAddressElement))
        if([Uri]::UnescapeDataString($current.PathAndQuery) -eq [Uri]::UnescapeDataString($wanted.PathAndQuery)){
            $roots=@(Get-DouyinNodes $null | Where-Object {$_.Current.AutomationId -eq 'RootWebArea' -and (Get-UiaValue $_) -and [Uri]::UnescapeDataString((ConvertTo-DouyinUri (Get-UiaValue $_)).PathAndQuery) -eq [Uri]::UnescapeDataString($wanted.PathAndQuery)})
            if($roots.Count -eq 1){return}
        }
        Wait-RpaDelay 0.5
    }while($timer.Elapsed.TotalSeconds -lt $Config.Timing.PageWaitSeconds)
    throw '抖音目标页面加载超时。'
}
function Get-DouyinChallenge {
    $markers=@('接收短信验证码','安全验证','请完成下方验证','请完成验证','请输入验证码')
    foreach($node in @(Get-DouyinNodes $null)){
        if((Test-UiaInBrowser $node) -and $node.Current.Name -in $markers){return $node.Current.Name}
    }
    return $null
}
function Save-DouyinEvidence([string]$Stage) {
    $items=@(foreach($element in @(Get-DouyinNodes $null)){
        if(Test-UiaInBrowser $element){$c=$element.Current; [pscustomobject]@{Name=$c.Name;Type=$c.ControlType.ProgrammaticName;Class=$c.ClassName;AutomationId=$c.AutomationId;Value=(Get-UiaValue $element);Bounds=$c.BoundingRectangle.ToString()}}
    })
    Write-RpaStateJson $items (Join-Path $script:VideoEvidence ($Stage+'-controls.json'))
    if([DingRpa]::GetForegroundWindow() -eq $script:BrowserHandle){
        $resultDir=$script:VideoEvidence
        Save-TargetImage $script:BrowserHandle ($Stage+'.png')
    }
}
