function Read-RpaConfiguration([string]$Path){
    $configuration=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($configuration.SchemaVersion -ne 1){throw '不支持的配置版本。'}
    if($configuration.ApplicationCenter.AutomationId -ne 'navigator_view.AppCenter' -or $configuration.ApplicationCenter.Name -ne '应用中心' -or $configuration.LowCode.Name -ne '低代码平台'){
        throw '当前流程仅支持已验证的钉钉应用中心与低代码平台选择器。'
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
