[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('douyin-rpa','douyin-reply-rpa','dingtalk-rpa')][string]$Skill,
    [string]$OutputRoot,
    [switch]$KeepExpanded
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$source=Join-Path $projectRoot ('skills\'+$Skill)
if(-not $OutputRoot){$OutputRoot=Join-Path $projectRoot 'artifacts\dist'}
$OutputRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$null=New-Item -ItemType Directory -Path $OutputRoot -Force
$buildRoot=Join-Path $OutputRoot ('build-'+[Guid]::NewGuid().ToString('N'))
$bundle=Join-Path $buildRoot $Skill
$null=New-Item -ItemType Directory -Path $bundle -Force
try {
    foreach($relative in @('SKILL.md','agents','references','scripts','config','launchers')){
        $path=Join-Path $source $relative
        if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $bundle $relative) -Recurse}
    }
    Copy-Item -LiteralPath (Join-Path $source 'src') -Destination (Join-Path $bundle 'src') -Recurse
    $sharedBundle=Join-Path $bundle 'shared'
    $null=New-Item -ItemType Directory -Path $sharedBundle -Force
    $sharedResources=@('Runtime.ps1','native','core')
    if($Skill -in @('douyin-rpa','douyin-reply-rpa')){$sharedResources+='douyin'}
    foreach($relative in $sharedResources){
        Copy-Item -LiteralPath (Join-Path $projectRoot ('shared\'+$relative)) -Destination (Join-Path $sharedBundle $relative) -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'VERSION') -Destination (Join-Path $bundle 'VERSION')
    $manifest=[ordered]@{Name=$Skill;Version=(Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim();Files=@()}
    foreach($file in Get-ChildItem -LiteralPath $bundle -File -Recurse){
        $manifest.Files+=@{Path=$file.FullName.Substring($bundle.Length+1).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
    }
    [IO.File]::WriteAllText((Join-Path $bundle 'bundle.json'),(ConvertTo-Json $manifest -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $zip=Join-Path $OutputRoot ($Skill+'-'+$manifest.Version+'.zip')
    Compress-Archive -LiteralPath $bundle -DestinationPath $zip -Force
    [pscustomobject]@{Status='Built';Skill=$Skill;SkillRoot=$(if($KeepExpanded){$bundle}else{$null});ZipPath=$zip;Version=$manifest.Version;Files=$manifest.Files.Count}
}finally{
    if(-not $KeepExpanded -and (Test-Path -LiteralPath $buildRoot)){
        $resolved=[IO.Path]::GetFullPath($buildRoot);$boundary=[IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^build-[a-f0-9]{32}$'){throw '拒绝清理未确认的构建目录。'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
