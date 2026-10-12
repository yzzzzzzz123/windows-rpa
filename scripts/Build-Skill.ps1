[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(-not $OutputRoot){$OutputRoot=Join-Path $projectRoot 'dist'}
$OutputRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$null=New-Item -ItemType Directory -Path $OutputRoot -Force
$buildRoot=Join-Path $OutputRoot ('build-'+[Guid]::NewGuid().ToString('N'))
$bundle=Join-Path $buildRoot 'windows-rpa'
$null=New-Item -ItemType Directory -Path $bundle -Force
foreach($relative in @('SKILL.md','agents\openai.yaml','references\operations.md','scripts\Skill.Core.ps1','scripts\Invoke-DouyinSkill.ps1','scripts\Invoke-RpaWorker.ps1','scripts\Watch-DouyinRpa.ps1','Monitor-RPA.cmd','scripts\Build-Skill.ps1','scripts\Register-Skill.ps1','config\task.preview.json')){
    $target=Join-Path $bundle $relative
    $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $target
}
$runtime=$bundle
$files=@(
    'VERSION','config\douyin.json','scripts\Invoke-DouyinRpa.ps1',
    'src\core\Douyin.Configuration.ps1','src\core\RpaState.ps1','src\core\Browser.ps1','src\core\Desktop.ps1',
    'src\workflows\Douyin.Comment.ps1','src\native\DingRpa.cs'
)
foreach($relative in $files){
    $target=Join-Path $runtime $relative
    $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination $target
}
$manifest=[ordered]@{Name='windows-rpa';Version=(Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim();Files=@()}
foreach($file in Get-ChildItem -LiteralPath $bundle -File -Recurse){
    $manifest.Files+=@{Path=$file.FullName.Substring($bundle.Length+1).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
}
[IO.File]::WriteAllText((Join-Path $bundle 'bundle.json'),(ConvertTo-Json $manifest -Depth 8),(New-Object Text.UTF8Encoding($false)))
$zip=Join-Path $OutputRoot ('windows-rpa-'+$manifest.Version+'.zip')
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -Force
[pscustomobject]@{Status='Built';SkillRoot=$bundle;ZipPath=$zip;Version=$manifest.Version;Files=$manifest.Files.Count}
