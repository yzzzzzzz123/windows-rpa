[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Reply.Core.ps1')
$request=Read-ReplyJson $RequestFile
$environment=Get-ReplyEnvironment $request.DataRoot
if($request.LaunchId -cnotmatch '^[a-f0-9]{32}$'){throw '交互启动编号无效。'}
$directory=Join-Path $environment.DataRoot ('launches\'+$request.LaunchId)
if([IO.Path]::GetFullPath($RequestFile) -ne (Join-Path $directory 'request.json') -or $request.RuntimeRoot -ne $environment.RuntimeRoot){throw '交互启动请求路径或 Skill 身份不匹配。'}
foreach($path in @($directory,$RequestFile,(Join-Path $directory 'task.json'))){
    if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '交互启动请求不能使用目录或文件链接。'}
}
$result=$null
try{
    if((Get-ReplyCallerSessionId) -le 0 -or (Get-ReplyCallerSessionId) -ne $request.SessionId -or (Get-ReplyCallerSid) -cne $request.UserSid){throw '启动桥接没有进入指定账号的交互会话。'}
    $entry=Join-Path $environment.RuntimeRoot 'scripts\Invoke-DouyinReplySkill.ps1'
    # The canonical controller still owns validation, dispatch locking and PID identity.
    $json=& $entry -Action Start -TaskFile (Join-Path $directory 'task.json') -DataRoot $environment.DataRoot -LaunchMode Local
    $result=$json|ConvertFrom-Json
}catch{
    $result=[pscustomobject]@{Ok=$false;Action='Start';Error=$_.Exception.Message}
}finally{
    Write-ReplyJson ([ordered]@{LaunchId=$request.LaunchId;Result=$result;SessionId=(Get-ReplyCallerSessionId);FinishedAt=(Get-Date -Format o)}) (Join-Path $directory 'receipt.json')
}
