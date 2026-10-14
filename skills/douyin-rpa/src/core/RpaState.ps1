function Write-RpaStateJson($Value,[string]$Path) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 12),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}
function Get-RpaLedgerPath([string]$VideoId) {
    if($VideoId -notmatch '^\d{19}$'){throw '视频编号格式错误。'}
    return Join-Path $script:RpaStateRoot ('videos\'+$VideoId+'.json')
}
function New-RpaSubmissionClaim($Video,[string]$Comment) {
    $path=Get-RpaLedgerPath $Video.VideoId
    $record=[ordered]@{VideoId=$Video.VideoId;Url=$Video.Url;Title=$Video.Title;Topic=$Video.Topic;Comment=$Comment;Status='Submitting';Time=(Get-Date -Format o);AutomaticRetryAllowed=$false}
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $record -Depth 8))
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    return $record
}
function Set-RpaSubmissionStatus([string]$VideoId,[string]$Status,[string]$Reason) {
    $path=Get-RpaLedgerPath $VideoId
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $record.Status=$Status
    $record | Add-Member NoteProperty UpdatedAt (Get-Date -Format o) -Force
    $record | Add-Member NoteProperty Reason $Reason -Force
    Write-RpaStateJson $record $path
}
function Initialize-RpaState([string]$StateRoot,[string]$LegacyEvidenceRoot) {
    $script:RpaStateRoot=$StateRoot
    $null=New-Item -ItemType Directory -Path (Join-Path $StateRoot 'videos') -Force
    $script:RpaControlRoot=Join-Path $StateRoot 'control'
    $null=New-Item -ItemType Directory -Path $script:RpaControlRoot -Force
    # Process handle lock is released even when the runner crashes. Do not remove another runner's lock.
    $script:RpaRunLock=[IO.File]::Open((Join-Path $StateRoot 'runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    # Import the one-off validation runs so the new runner cannot repeat earlier submissions.
    foreach($directory in @(Get-ChildItem -LiteralPath $LegacyEvidenceRoot -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^douyin-\d{19}$'})){
        $attemptPath=Join-Path $directory.FullName 'submission-attempt.json'
        if(-not (Test-Path -LiteralPath $attemptPath)){continue}
        $videoId=$directory.Name.Substring(7)
        $destination=Get-RpaLedgerPath $videoId
        if(Test-Path -LiteralPath $destination){continue}
        $attempt=Get-Content -LiteralPath $attemptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status='NeedsVisualReview';$resultPath=Join-Path $directory.FullName 'result.json'
        if(Test-Path -LiteralPath $resultPath){$prior=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json; if($prior.Status -eq 'Passed'){$status='Submitted'}}
        Write-RpaStateJson ([ordered]@{VideoId=$videoId;Url=$attempt.Url;Comment=$attempt.Comment;Status=$status;Time=$attempt.Time;Imported=$true;AutomaticRetryAllowed=$false}) $destination
    }
}
function Assert-RpaRunning {
    if(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'stop')){throw [OperationCanceledException]::new('已收到停止指令。')}
    if(([DingRpa]::GetAsyncKeyState(0x1b) -band 0x8000) -ne 0){throw [OperationCanceledException]::new('检测到 Escape，已停止。')}
    Update-RpaHeartbeat
}
function Update-RpaHeartbeat {
    if(-not $script:RunReport -or -not $script:RunDirectory){return}
    $now=[DateTimeOffset]::Now
    if($script:RunReport.HeartbeatAt -and ($now-[DateTimeOffset]::Parse($script:RunReport.HeartbeatAt)).TotalSeconds -lt 2){return}
    $script:RunReport['HeartbeatAt']=$now.ToString('o')
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
}
function Set-RpaProgress([string]$Stage) {
    if(-not $script:RunReport -or -not $script:RunDirectory){return}
    $script:RunReport.Stage=$Stage;$script:RunReport.UpdatedAt=Get-Date -Format o
    $script:RunReport['HeartbeatAt']=Get-Date -Format o
    Write-RpaStateJson $script:RunReport (Join-Path $script:RunDirectory 'result.json')
}
function Wait-RpaDelay([double]$Seconds) {
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-RpaRunning
        while(Test-Path -LiteralPath (Join-Path $script:RpaControlRoot 'pause')){
            Assert-RpaRunning
            if($script:RunReport -and -not $script:RunReport.Paused){$script:RunReport.Paused=$true;Set-RpaProgress $script:RunReport.Stage}
            Start-Sleep -Milliseconds 250
        }
        if($script:RunReport -and $script:RunReport.Paused){$script:RunReport.Paused=$false;Set-RpaProgress $script:RunReport.Stage}
        if([DateTime]::UtcNow -ge $until){break}
        Start-Sleep -Milliseconds 200
    } while($true)
}
