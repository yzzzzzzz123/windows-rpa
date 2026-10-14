function Read-RpaConfiguration([string]$Path){
    $configuration=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($configuration.SchemaVersion -ne 1){throw '不支持的配置版本。'}
    if($configuration.ApplicationCenter.AutomationId -ne 'navigator_view.AppCenter' -or $configuration.ApplicationCenter.Name -ne '应用中心' -or $configuration.LowCode.Name -ne '低代码平台'){
        throw '当前流程仅支持已验证的钉钉应用中心与低代码平台选择器。'
    }
    $moreExpected=[ordered]@{
        MoreAutomationId='navigator_view.internal__more'
        MoreName='更多'
        MoreWindowAutomationId='navigator_view.navigator_more_view'
        MoreItemAutomationId='navigator_view.navigator_more_view.scroll_area_.qt_scrollarea_viewport.content_widget_.AppCenter'
    }
    $morePresent=@($moreExpected.Keys|Where-Object {$null -ne $configuration.ApplicationCenter.PSObject.Properties[$_]})
    if($morePresent.Count -gt 0){
        if($morePresent.Count -ne $moreExpected.Count){throw '钉钉更多入口配置必须完整提供，不能猜测缺失选择器。'}
        foreach($name in $moreExpected.Keys){if($configuration.ApplicationCenter.$name -cne $moreExpected[$name]){throw ('钉钉更多入口选择器未经验证：'+$name)}}
    }
    if($null -ne $configuration.PSObject.Properties['SearchInput']){
        if($configuration.SearchInput.Name -cne '搜索想要的应用' -or $configuration.SearchInput.Text -cne 'test'){
            throw '当前钉钉输入步骤仅支持在应用市场搜索框输入 test。'
        }
    }
    $limits=@(
        @($configuration.Timing.PageLoadMilliseconds,500,15000),
        @($configuration.Timing.FocusWaitMilliseconds,0,15000),
        @($configuration.Timing.LabelAttempts,1,20),
        @($configuration.Timing.LabelWaitMilliseconds,100,3000),
        @($configuration.Scroll.MaxWheelRounds,1,60),
        @($configuration.Scroll.WheelWaitMilliseconds,100,3000),
        @($configuration.Scroll.UnchangedFrameLimit,2,10)
    )
    foreach($limit in $limits){
        $value=$limit[0]
        if($null -eq $value -or $value -isnot [ValueType] -or $value -is [bool] -or [double]$value -ne [Math]::Truncate([double]$value) -or $value -lt $limit[1] -or $value -gt $limit[2]){throw '配置中的等待或滚动参数缺失、不是整数或超出允许范围。'}
    }
    return $configuration
}
