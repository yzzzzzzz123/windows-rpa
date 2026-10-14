[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$testWorkspace=Join-Path $repositoryRoot 'artifacts\work'
. (Join-Path $projectRoot 'src\core\Douyin.Keywords.ps1')
$testRoot=Join-Path $testWorkspace ('keyword-tests-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$script:KeywordCheckpoints=0
$check={ $script:KeywordCheckpoints++ }
function Assert-KeywordTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('AI视频剪辑','AI分镜创作','AI无限画布') -MatchAny @('剪辑','分镜','无限画布') -CancellationCheck $check
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -eq 3) '初始种子计数不正确。'
    $first=@(Get-DouyinSearchBatch)
    Assert-KeywordTest ($first.Count -eq 3) '初始待搜词没有返回。'
    foreach($term in $first){Complete-DouyinSearchTerm -Term $term}
    Complete-DouyinSearchTerm -Term $first[0]
    Assert-KeywordTest ((Get-DouyinKeywordStats).Pending -eq 0 -and (Get-DouyinKeywordStats).Completed -eq 3) '搜索完成重复记账。'
    $fallback=@(Get-DouyinSearchBatch -MaxTerms 2)
    Assert-KeywordTest ($fallback.Count -eq 2 -and $fallback[0] -in $first -and $fallback[1] -in $first) '待搜池耗尽后没有回退真实种子。'
    $added=Add-DouyinKeywordObservations -Title 'AI分镜批量生成，#AI剪辑教程 #AI无限画布技巧 #无关宠物'
    Assert-KeywordTest ($added -eq 3) '标题和话题的相关词扩展不正确。'
    $newBatch=@(Get-DouyinSearchBatch)
    Assert-KeywordTest ($newBatch.Count -eq 3 -and '无关宠物' -notin $newBatch -and 'AI剪辑教程' -in $newBatch) '主题过滤或待搜新词优先失败。'
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title '#ai剪辑教程') -eq 0) '大小写去重失败。'
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title ('#AI剪辑'+('长'*80))) -eq 0) '超长词被接收。'
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title ('AI剪辑'+[char]0+'异常')) -eq 0) '控制字符被接收。'
    foreach($bad in @('AI剪辑 $(Get-Process)','AI剪辑 & powershell','AI剪辑 https://evil.invalid/','AI剪辑 cmd /c calc','AI剪辑 www.example.com','AI剪辑 | Remove-Item','AI剪辑 rm -rf','AI剪辑 node -e')){
        $candidate=ConvertTo-DouyinKeyword $bad
        Assert-KeywordTest (-not $candidate) '命令片段或链接被当作搜索词。'
        Assert-KeywordTest ((Add-DouyinKeywordObservations -Title $bad) -eq 0) '标题切分绕过了命令或链接过滤。'
    }
    $originalRoot=$script:DouyinKeywordPool.Root
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('AI视频剪辑','AI分镜创作','AI无限画布') -MatchAny @('无限画布','分镜','剪辑') -CancellationCheck $check
    Assert-KeywordTest ($script:DouyinKeywordPool.Root -eq $originalRoot -and (Get-DouyinKeywordStats).Total -eq 6 -and (Get-DouyinKeywordStats).Pending -eq 3) '同主题跨运行或主题次序变化丢失关键词池。'
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title "#AI剪辑换行话题`n#AI分镜换行话题") -eq 2) '标题中的换行阻止了独立且安全的话题提取。'
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title 'AI剪辑 https：／／example.test') -eq 0) '全角 URL 绕过了链接过滤。'
    for($round=0;$round -lt 8;$round++){
        $title=((0..23 | ForEach-Object { '#AI剪辑实测'+($round*24+$_) }) -join ' ')
        $count=Add-DouyinKeywordObservations -Title $title
        Assert-KeywordTest ($count -le 12 -and $count -gt 0) '每次新增没有明确边界。'
    }
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -gt 20 -and @(Get-DouyinSearchBatch).Count -eq 12) '累计池被种子配置数量限制或搜索批次没有界限。'
    $pool=$script:DouyinKeywordPool
    $recordId=Get-DouyinKeywordHash 'AI剪辑事务恢复'
    $record=[ordered]@{SchemaVersion=1;Id=$recordId;Term='AI剪辑事务恢复';Source='ObservedTitle';AddedAt=[DateTimeOffset]::Now.ToString('o')}
    $expected=[long]$pool.Counts.Total+1
    $counts=[ordered]@{SchemaVersion=1;Total=$expected;Pending=([long]$pool.Counts.Pending+1);Completed=[long]$pool.Counts.Completed}
    Write-DouyinKeywordJson ([ordered]@{SchemaVersion=1;Action='Add';Record=$record;Counts=$counts}) $pool.TransactionPath
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('AI视频剪辑') -MatchAny @('剪辑','分镜','无限画布') -CancellationCheck $check
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -eq $expected -and -not [IO.File]::Exists($pool.TransactionPath)) '中断的单词事务不能恢复。'
    Complete-DouyinSearchTerm 'AI剪辑事务恢复'
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -eq $expected) '完成搜索改变了累计计数。'
    # Simulate a crash after the done record was written but before pending/counters were committed.
    $unfinished=@(Get-DouyinSearchBatch -MaxTerms 1)[0]
    $pool=$script:DouyinKeywordPool
    $id=Get-DouyinKeywordHash $unfinished
    $record=Read-DouyinKeywordJson (Join-Path $pool.PendingPath ($id+'.json'))
    $counts=[ordered]@{SchemaVersion=1;Total=[long]$pool.Counts.Total;Pending=([long]$pool.Counts.Pending-1);Completed=([long]$pool.Counts.Completed+1)}
    Write-DouyinKeywordJson ([ordered]@{SchemaVersion=1;Action='Complete';Record=$record;Counts=$counts}) $pool.TransactionPath
    Write-DouyinKeywordJson $record (Join-Path $pool.DonePath ($id+'.json'))
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('AI视频剪辑') -MatchAny @('剪辑','分镜','无限画布') -CancellationCheck $check
    Assert-KeywordTest ((Get-DouyinKeywordStats).Completed -eq $counts.Completed -and -not [IO.File]::Exists((Join-Path $pool.PendingPath ($id+'.json')))) '部分完成事务没有幂等恢复。'
    $manySeeds=@(1..25 | ForEach-Object {'AI画布种子测试'+$_})
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms $manySeeds -MatchAny @('画布种子') -CancellationCheck $check
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -eq 25) '种子数量仍受 20 项硬限制。'
    $pendingFirst=@(Get-DouyinSearchBatch)
    $pendingSecond=@(Get-DouyinSearchBatch)
    Assert-KeywordTest ($pendingFirst.Count -eq 12 -and $pendingSecond.Count -eq 12 -and @($pendingSecond | Where-Object {$_ -in $pendingFirst}).Count -eq 0) '未完成的前 12 个词阻挡了下一批待搜词。'
    $pendingTail=@(Get-DouyinSearchBatch)
    Assert-KeywordTest ($pendingTail.Count -eq 1 -and $pendingTail[0] -notin $pendingFirst -and $pendingTail[0] -notin $pendingSecond) '待搜游标没有推进至末尾。'
    # Delete records that the live cursor may already have buffered, then add newly observed terms.
    $pendingFirst=@(Get-DouyinSearchBatch)
    $completedAhead=@($manySeeds | Where-Object {$_ -notin $pendingFirst} | Select-Object -First 4)
    foreach($term in $completedAhead){Complete-DouyinSearchTerm $term}
    Assert-KeywordTest ((Add-DouyinKeywordObservations -Title '#AI画布种子新增观察甲 #AI画布种子新增观察乙') -eq 2) '观察新增词未写入进行中的池。'
    $seenLater=New-Object 'Collections.Generic.HashSet[string]'
    for($round=0;$round -lt 8;$round++){
        foreach($term in @(Get-DouyinSearchBatch)){
            Assert-KeywordTest ($term -notin $completedAhead) '待搜枚举器返回了已完成删除的记录。'
            $null=$seenLater.Add($term)
        }
        if($seenLater.Contains('AI画布种子新增观察甲') -and $seenLater.Contains('AI画布种子新增观察乙')){break}
    }
    Assert-KeywordTest ($seenLater.Contains('AI画布种子新增观察甲') -and $seenLater.Contains('AI画布种子新增观察乙')) '跨批游标始终看不到后续新增词。'
    foreach($term in $manySeeds){Complete-DouyinSearchTerm $term}
    Complete-DouyinSearchTerm 'AI画布种子新增观察甲'
    Complete-DouyinSearchTerm 'AI画布种子新增观察乙'
    $revisited=New-Object 'Collections.Generic.HashSet[string]'
    for($round=0;$round -lt 3;$round++){foreach($term in @(Get-DouyinSearchBatch)){$null=$revisited.Add($term)}}
    Assert-KeywordTest ($revisited.Count -eq 25) '耗尽待搜词后没有轮转回访全部种子。'
    $cancelledInitialization=$false
    try{Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms $manySeeds -MatchAny @('画布种子') -CancellationCheck {throw [OperationCanceledException]::new('初始化取消')}}catch [OperationCanceledException]{$cancelledInitialization=$true}
    Assert-KeywordTest $cancelledInitialization '种子初始化不能响应取消。'
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('AI分镜尾部种子') -MatchAny @('分镜尾部') -CancellationCheck $check
    Complete-DouyinSearchTerm 'AI分镜尾部种子'
    $null=Add-DouyinKeywordObservations -Title ((1..12 | ForEach-Object {'#AI分镜尾部观察'+$_}) -join ' ')
    $boundaryFirst=@(Get-DouyinSearchBatch)
    $boundaryNext=@(Get-DouyinSearchBatch)
    Assert-KeywordTest ($boundaryFirst.Count -eq 12 -and $boundaryNext.Count -eq 12 -and 'AI分镜尾部种子' -notin $boundaryNext) '枚举器恰好到批次边界时错误回访种子，忽略仍待搜的新词。'
    Initialize-DouyinKeywordPool -StateRoot $testRoot -SearchTerms @('宠物训练') -MatchAny @('宠物') -CancellationCheck $check
    Assert-KeywordTest ((Get-DouyinKeywordStats).Total -eq 1 -and @(Get-DouyinSearchBatch)[0] -eq '宠物训练') '换主题沿用了其他主题关键词。'
    $script:DouyinKeywordPool.CancellationCheck={throw [OperationCanceledException]::new('离线停止检查')}
    $cancelled=$false
    try{$null=Get-DouyinSearchBatch}catch [OperationCanceledException]{$cancelled=$true}
    Assert-KeywordTest $cancelled '读取关键词批次时不能响应取消。'
    $script:DouyinKeywordPool.CancellationCheck=$check
    $oversize=Add-DouyinKeywordObservations -Title ('AI剪辑'*2000)
    Assert-KeywordTest ($oversize -eq 0) '超大标题没有有界拒绝。'
    [pscustomobject]@{Status='Passed';Persistence=$true;TopicScope=$true;ObservedTitleExpansion=$true;NoCumulativeHardLimit=$true;SeedsBeyond20=$true;FallbackRotates=$true;PendingBatchFairness=$true;DeletedPendingSkipped=$true;NewPendingVisible=$true;BatchLimit=12;TransactionRecovery=$true;Cancellation=$true;Checkpoints=$script:KeywordCheckpoints;DesktopActions=0}
}finally{
    if($script:DouyinKeywordPool -and $script:DouyinKeywordPool.PendingEnumerator){$script:DouyinKeywordPool.PendingEnumerator.Dispose();$script:DouyinKeywordPool.PendingEnumerator=$null}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $work=[IO.Path]::GetFullPath($testWorkspace)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($work,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^keyword-tests-[a-f0-9]{32}$'){throw '拒绝清理未确认的关键词测试目录。'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
