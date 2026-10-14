function Get-DouyinKeywordHash([string]$Text) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToUpperInvariant())))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function ConvertTo-DouyinKeyword([string]$Text) {
    if(-not $Text -or $Text.Length -gt 240 -or $Text -match '[\p{C}]'){return $null}
    $term=([regex]::Replace($Text.Normalize([Text.NormalizationForm]::FormKC),'\s+',' ')).Trim()
    if($term.Length -lt 2 -or $term.Length -gt 60 -or $term -notmatch '^[\p{L}\p{N} ._+()（）-]+$'){return $null}
    if($term -match '(?i)(https?|ftp|file)\s*[:/]|www\.|\b(?:powershell|pwsh|cmd|bash|sh|curl|wget|Invoke-Expression|Invoke-WebRequest|Start-Process|Remove-Item)\b|\b(?:rm|del|rmdir|node|python)\s+[-/]'){return $null}
    return $term
}
function Invoke-DouyinKeywordCheckpoint {
    if($script:DouyinKeywordPool.CancellationCheck){$null=& $script:DouyinKeywordPool.CancellationCheck;return}
    if(Get-Command Assert-RpaRunning -ErrorAction SilentlyContinue){Assert-RpaRunning}
}
function Write-DouyinKeywordJson($Value,[string]$Path) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 8),(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Read-DouyinKeywordJson([string]$Path) {
    if((New-Object IO.FileInfo($Path)).Length -gt 16384){throw '关键词池记录过大，已停止读取。'}
    return ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Assert-DouyinKeywordCounts($Counts) {
    if($Counts.SchemaVersion -ne 1){throw '关键词池计数版本无效。'}
    foreach($name in @('Total','Pending','Completed')){
        $value=$Counts.$name
        if($value -isnot [ValueType] -or $value -is [bool] -or [decimal]$value -lt 0 -or [decimal]$value -ne [Math]::Truncate([decimal]$value)){throw '关键词池计数无效。'}
    }
    if([decimal]$Counts.Total -ne ([decimal]$Counts.Pending+[decimal]$Counts.Completed)){throw '关键词池计数不一致。'}
}
function Assert-DouyinKeywordRecord($Record,[string]$Id) {
    if($Id -notmatch '^[a-f0-9]{64}$' -or $Record.SchemaVersion -ne 1 -or $Record.Id -cne $Id){throw '关键词池记录身份无效。'}
    $term=ConvertTo-DouyinKeyword ([string]$Record.Term)
    if(-not $term -or $term -cne [string]$Record.Term -or (Get-DouyinKeywordHash $term) -cne $Id){throw '关键词池记录内容无效。'}
}
function Repair-DouyinKeywordTransaction {
    $pool=$script:DouyinKeywordPool
    if(-not [IO.File]::Exists($pool.TransactionPath)){return}
    Invoke-DouyinKeywordCheckpoint
    $transaction=Read-DouyinKeywordJson $pool.TransactionPath
    if($transaction.SchemaVersion -ne 1 -or $transaction.Action -notin @('Add','Complete')){throw '关键词池事务无效。'}
    $id=[string]$transaction.Record.Id
    Assert-DouyinKeywordRecord $transaction.Record $id
    Assert-DouyinKeywordCounts $transaction.Counts
    $pendingPath=Join-Path $pool.PendingPath ($id+'.json')
    $donePath=Join-Path $pool.DonePath ($id+'.json')
    if($transaction.Action -eq 'Add'){
        if([IO.File]::Exists($donePath)){throw '关键词池新增事务与已搜索记录冲突。'}
        Write-DouyinKeywordJson $transaction.Record $pendingPath
    }else{
        Write-DouyinKeywordJson $transaction.Record $donePath
        if([IO.File]::Exists($pendingPath)){[IO.File]::Delete($pendingPath)}
    }
    Write-DouyinKeywordJson $transaction.Counts $pool.MetaPath
    [IO.File]::Delete($pool.TransactionPath)
    $pool.Counts=$transaction.Counts
}
function Add-DouyinKeywordTerm([string]$Term,[string]$Source) {
    Invoke-DouyinKeywordCheckpoint
    $term=ConvertTo-DouyinKeyword $Term
    if(-not $term){return $false}
    $pool=$script:DouyinKeywordPool
    Repair-DouyinKeywordTransaction
    $id=Get-DouyinKeywordHash $term
    if([IO.File]::Exists((Join-Path $pool.PendingPath ($id+'.json'))) -or [IO.File]::Exists((Join-Path $pool.DonePath ($id+'.json')))){return $false}
    $record=[ordered]@{SchemaVersion=1;Id=$id;Term=$term;Source=$Source;AddedAt=[DateTimeOffset]::Now.ToString('o')}
    $counts=[ordered]@{SchemaVersion=1;Total=([long]$pool.Counts.Total+1);Pending=([long]$pool.Counts.Pending+1);Completed=[long]$pool.Counts.Completed}
    Write-DouyinKeywordJson ([ordered]@{SchemaVersion=1;Action='Add';Record=$record;Counts=$counts}) $pool.TransactionPath
    Repair-DouyinKeywordTransaction
    return $true
}
function Initialize-DouyinKeywordPool {
    [CmdletBinding()]
    param([string]$StateRoot=$script:RpaStateRoot,[string[]]$SearchTerms=$Config.SearchTerms,[string[]]$MatchAny=$Config.MatchAny,[scriptblock]$CancellationCheck)
    if(-not $StateRoot -or -not $SearchTerms -or -not $MatchAny){throw '初始化关键词池需要状态目录、种子词和主题过滤词。'}
    if($MatchAny.Count -gt 20){throw '关键词池最多接受 20 个主题过滤词。'}
    # The workflow owns the existing StateRoot runner.lock for the full lifetime of this pool.
    $seedTerms=New-Object 'Collections.Generic.List[string]'
    $seedIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($seed in $SearchTerms){
        if($CancellationCheck){$null=& $CancellationCheck}elseif(Get-Command Assert-RpaRunning -ErrorAction SilentlyContinue){Assert-RpaRunning}
        $clean=ConvertTo-DouyinKeyword $seed
        if(-not $clean){throw '关键词种子含不支持的字符或长度。'}
        if($seedIds.Add($clean)){$seedTerms.Add($clean)}
    }
    $matchTerms=New-Object 'Collections.Generic.List[string]'
    foreach($match in $MatchAny){if(-not $match -or -not $match.Trim() -or $match.Length -gt 60 -or $match -match '[\p{C}]'){throw '关键词主题过滤词无效。'};$matchTerms.Add($match.Trim())}
    $scopeHash=Get-DouyinKeywordHash ((@($matchTerms | ForEach-Object {$_.ToUpperInvariant()} | Sort-Object -Unique)) -join "`n")
    $root=Join-Path ([IO.Path]::GetFullPath($StateRoot)) ('keyword-pool\'+$scopeHash)
    if($script:DouyinKeywordPool -and $script:DouyinKeywordPool.PendingEnumerator){$script:DouyinKeywordPool.PendingEnumerator.Dispose()}
    $script:DouyinKeywordPool=[pscustomobject]@{Root=$root;PendingPath=(Join-Path $root 'pending');DonePath=(Join-Path $root 'done');MetaPath=(Join-Path $root 'counts.json');TransactionPath=(Join-Path $root 'transaction.json');Seeds=$seedTerms.ToArray();MatchAny=$matchTerms.ToArray();CancellationCheck=$CancellationCheck;Counts=$null;FallbackOffset=0;PendingEnumerator=$null}
    $pool=$script:DouyinKeywordPool
    Invoke-DouyinKeywordCheckpoint
    $null=[IO.Directory]::CreateDirectory($pool.PendingPath)
    $null=[IO.Directory]::CreateDirectory($pool.DonePath)
    Repair-DouyinKeywordTransaction
    if([IO.File]::Exists($pool.MetaPath)){$pool.Counts=Read-DouyinKeywordJson $pool.MetaPath;Assert-DouyinKeywordCounts $pool.Counts}else{
        # A missing counter beside existing records is corruption, not a new empty pool.
        foreach($directory in @($pool.PendingPath,$pool.DonePath)){
            $enumerator=[IO.Directory]::EnumerateFiles($directory,'*.json').GetEnumerator()
            try{if($enumerator.MoveNext()){throw '关键词池已有记录但缺少计数，不能静默重置。'}}finally{$enumerator.Dispose()}
        }
        $pool.Counts=[pscustomobject]@{SchemaVersion=1;Total=0;Pending=0;Completed=0}
        Write-DouyinKeywordJson $pool.Counts $pool.MetaPath
    }
    foreach($seed in $pool.Seeds){$null=Add-DouyinKeywordTerm $seed 'Seed'}
}
function Test-DouyinKeywordTheme([string]$Term) {
    foreach($match in $script:DouyinKeywordPool.MatchAny){if($Term.IndexOf($match,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}}
    return $false
}
function Add-DouyinKeywordObservations {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Title)
    if(-not $script:DouyinKeywordPool){throw '关键词池尚未初始化。'}
    Invoke-DouyinKeywordCheckpoint
    # Page text remains untrusted data. Never evaluate it or interpolate it into a command.
    if(-not $Title -or $Title.Length -gt 4096){return 0}
    $Title=$Title.Normalize([Text.NormalizationForm]::FormKC)
    # Reject URL/command-bearing observations before punctuation splitting can hide a dangerous fragment.
    if($Title -match '[\p{C}-[\r\n\t]]' -or $Title -match '[\$`&<>\\]' -or $Title -match '(?i)(?:https?|ftp|file)\s*:\s*[/\\]|www\.|\b(?:powershell|pwsh|cmd|bash|curl|wget|Invoke-Expression|Invoke-WebRequest|Start-Process|Remove-Item)\b|\b(?:rm|del|rmdir|node|python)\s+[-/]'){return 0}
    $candidates=New-Object 'Collections.Generic.List[string]'
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $matches=[regex]::Matches($Title,'[#＃]([\p{L}\p{N}_+\-]+)')
    for($index=0;$index -lt [Math]::Min(24,$matches.Count);$index++){$candidates.Add($matches[$index].Groups[1].Value)}
    $phrases=[regex]::Split($Title,'[，,。.!！？?；;、|｜:：#＃\r\n\t]')
    for($index=0;$index -lt [Math]::Min(24,$phrases.Length);$index++){$candidates.Add($phrases[$index])}
    $added=0
    foreach($candidate in $candidates){
        Invoke-DouyinKeywordCheckpoint
        $term=ConvertTo-DouyinKeyword $candidate
        if(-not $term -or -not $seen.Add($term) -or -not (Test-DouyinKeywordTheme $term)){continue}
        if(Add-DouyinKeywordTerm $term 'ObservedTitle'){$added++}
        if($added -ge 12){break}
    }
    return $added
}
function Get-DouyinSearchBatch {
    [CmdletBinding()]
    param([ValidateRange(1,12)][int]$MaxTerms=12)
    if(-not $script:DouyinKeywordPool){throw '关键词池尚未初始化。'}
    Repair-DouyinKeywordTransaction
    $pool=$script:DouyinKeywordPool
    $batch=New-Object 'Collections.Generic.List[string]'
    # Keep a lazy cursor across batches: failed searches must not monopolize the directory's first entries.
    if(-not $pool.PendingEnumerator){$pool.PendingEnumerator=[IO.Directory]::EnumerateFiles($pool.PendingPath,'*.json').GetEnumerator()}
    $examined=0
    $restarted=$false
    try{
        while($batch.Count -lt $MaxTerms -and $examined -lt 96){
            Invoke-DouyinKeywordCheckpoint
            if(-not $pool.PendingEnumerator.MoveNext()){
                $pool.PendingEnumerator.Dispose();$pool.PendingEnumerator=$null
                if($batch.Count -eq 0 -and -not $restarted -and [long]$pool.Counts.Pending -gt 0){
                    $restarted=$true
                    $pool.PendingEnumerator=[IO.Directory]::EnumerateFiles($pool.PendingPath,'*.json').GetEnumerator()
                    continue
                }
                break
            }
            $examined++
            $path=$pool.PendingEnumerator.Current
            # The enumerator may have buffered a path completed/deleted between two batches.
            if(-not [IO.File]::Exists($path)){continue}
            $record=Read-DouyinKeywordJson $path
            Assert-DouyinKeywordRecord $record ([IO.Path]::GetFileNameWithoutExtension($path))
            $batch.Add([string]$record.Term)
        }
    }catch{
        if($pool.PendingEnumerator){$pool.PendingEnumerator.Dispose();$pool.PendingEnumerator=$null}
        throw
    }
    if($batch.Count -gt 0){return $batch.ToArray()}
    # No fabricated suffixes: revisit real user-provided seeds and learn only from new page observations.
    $count=[Math]::Min($MaxTerms,$pool.Seeds.Count)
    for($index=0;$index -lt $count;$index++){Invoke-DouyinKeywordCheckpoint;$batch.Add($pool.Seeds[($pool.FallbackOffset+$index)%$pool.Seeds.Count])}
    $pool.FallbackOffset=($pool.FallbackOffset+$count)%$pool.Seeds.Count
    return $batch.ToArray()
}
function Complete-DouyinSearchTerm {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Term)
    if(-not $script:DouyinKeywordPool){throw '关键词池尚未初始化。'}
    Invoke-DouyinKeywordCheckpoint
    Repair-DouyinKeywordTransaction
    $pool=$script:DouyinKeywordPool
    $term=ConvertTo-DouyinKeyword $Term
    if(-not $term){throw '完成搜索的关键词无效。'}
    $id=Get-DouyinKeywordHash $term
    $path=Join-Path $pool.PendingPath ($id+'.json')
    if(-not [IO.File]::Exists($path)){return}
    $record=Read-DouyinKeywordJson $path
    Assert-DouyinKeywordRecord $record $id
    $record | Add-Member NoteProperty CompletedAt ([DateTimeOffset]::Now.ToString('o')) -Force
    $counts=[ordered]@{SchemaVersion=1;Total=[long]$pool.Counts.Total;Pending=([long]$pool.Counts.Pending-1);Completed=([long]$pool.Counts.Completed+1)}
    Write-DouyinKeywordJson ([ordered]@{SchemaVersion=1;Action='Complete';Record=$record;Counts=$counts}) $pool.TransactionPath
    Repair-DouyinKeywordTransaction
}
function Get-DouyinKeywordStats {
    [CmdletBinding()]
    param()
    if(-not $script:DouyinKeywordPool){throw '关键词池尚未初始化。'}
    Repair-DouyinKeywordTransaction
    $counts=$script:DouyinKeywordPool.Counts
    return [pscustomobject]@{Total=[long]$counts.Total;Pending=[long]$counts.Pending;Completed=[long]$counts.Completed;ExpansionSource='ObservedTitles';BatchLimit=12;CumulativeLimit=$null}
}
