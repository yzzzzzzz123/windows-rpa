[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$work=Join-Path $root 'artifacts\work'
$testRoot=Join-Path $work ('layout-test-'+[Guid]::NewGuid().ToString('N'))
$links=Join-Path $testRoot 'discovery'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Assert-Layout([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
$packageChecks=0
try {
    foreach($legacy in @('SKILL.md','agents','references','config','src','Run-Douyin-RPA.cmd','Run-DingTalk-RPA.cmd','scripts\Invoke-Rpa.ps1')){
        Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $root $legacy))) ('根目录仍有旧业务文件：'+$legacy)
    }
    $null=New-Item -ItemType Directory -Path $testRoot -Force
    # Registration is idempotent and retires only the exact legacy project junction.
    $null=New-Item -ItemType Directory -Path $links -Force
    $null=New-Item -ItemType Junction -Path (Join-Path $links 'windows-rpa') -Value $root
    $null=& (Join-Path $root 'scripts\Register-Skill.ps1') -SkillsRoot $links
    $null=& (Join-Path $root 'scripts\Register-Skill.ps1') -SkillsRoot $links
    Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $links 'windows-rpa'))) '旧根目录发现链接未退役。'
    $direct=& (Join-Path $root 'skills\douyin-rpa\scripts\Invoke-DouyinSkill.ps1') -Action Describe|ConvertFrom-Json
    $linked=& (Join-Path $links 'douyin-rpa\scripts\Invoke-DouyinSkill.ps1') -Action Describe|ConvertFrom-Json
    Assert-Layout ($direct.Ok -and $linked.Ok -and $direct.Paths.DataRoot -ceq $linked.Paths.DataRoot -and $direct.Paths.StateRoot -ceq $linked.Paths.StateRoot -and $direct.Paths.RuntimeRoot -ceq $linked.Paths.RuntimeRoot) '发现链接改变了抖音运行或数据身份。'
    Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $links 'douyin-reply-rpa'))) '旧注册工具默认不应注册新回复 Skill。'
    $replyDirect=& (Join-Path $root 'skills\douyin-reply-rpa\scripts\Invoke-DouyinReplySkill.ps1') -Action Describe|ConvertFrom-Json
    Assert-Layout ($replyDirect.Ok -and $replyDirect.Paths.DataRoot -ceq (Join-Path $root 'data\douyin-reply-rpa') -and $replyDirect.Paths.StateRoot -ceq (Join-Path $root 'data\douyin-reply-rpa\state')) '回复 Skill 未使用独立任务与回复状态目录。'
    $skillConfigs=@{'douyin-rpa'='douyin.json';'douyin-reply-rpa'='reply.json';'dingtalk-rpa'='dingtalk.json'}
    foreach($skill in @('douyin-rpa','douyin-reply-rpa','dingtalk-rpa')){
        $build=& (Join-Path $root 'scripts\Build-Skill.ps1') -Skill $skill -OutputRoot (Join-Path $testRoot 'packages')
        Assert-Layout ($build.Status -eq 'Built' -and $null -eq $build.SkillRoot) '默认构建应只保留 ZIP。'
        $expanded=Join-Path $testRoot ($skill+' 解包''s & $')
        Expand-Archive -LiteralPath $build.ZipPath -DestinationPath $expanded
        $bundle=Join-Path $expanded $skill
        $manifest=Get-Content -LiteralPath (Join-Path $bundle 'bundle.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Layout ($manifest.Name -eq $skill) '包身份错误。'
        foreach($file in $manifest.Files){Assert-Layout ((Get-FileHash -LiteralPath (Join-Path $bundle $file.Path)).Hash -ceq $file.SHA256) ('包哈希错误：'+$file.Path)}
        Assert-Layout ((Get-FileHash -LiteralPath (Join-Path $bundle 'shared\native\DingRpa.cs')).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $root 'shared\native\DingRpa.cs')).Hash) '共享代码与源码不一致。'
        foreach($forbidden in @('data','tests','artifacts','AGENTS.md')){Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $bundle $forbidden))) ('包夹带了非运行内容：'+$forbidden)}
        foreach($otherSkill in @($skillConfigs.Keys | Where-Object {$_ -ne $skill})){
            Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $bundle ('config\'+$skillConfigs[$otherSkill])))) '包夹带另一个 Skill 配置。'
        }
        if($skill -eq 'dingtalk-rpa'){
            Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $bundle 'shared\douyin'))) '钉钉包夹带了抖音共享代码。'
        }else{
            foreach($relative in @('Urls.ps1','Browser.ps1','Comments.ps1')){
                Assert-Layout ((Get-FileHash -LiteralPath (Join-Path $bundle ('shared\douyin\'+$relative))).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $root ('shared\douyin\'+$relative))).Hash) ('抖音共享代码缺失或与源码不一致：'+$relative)
            }
        }
        # Rename to ensure package identity is not inferred from the installation folder name.
        $renamed=Join-Path $expanded '任意安装目录'
        $source=[IO.Path]::GetFullPath($bundle);$target=[IO.Path]::GetFullPath($renamed);$boundary=[IO.Path]::GetFullPath($testRoot)+'\'
        if(-not $source.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or -not $target.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw '拒绝移动测试边界外路径。'}
        Move-Item -LiteralPath $source -Destination $target
        if($skill -eq 'douyin-reply-rpa'){
            # Describe is read-only. Discover/Preview/Publish would operate the real desktop.
            $description=& (Join-Path $renamed 'scripts\Invoke-DouyinReplySkill.ps1') -Action Describe|ConvertFrom-Json
            Assert-Layout ($description.Ok -and $description.Paths.DataRoot -ceq (Join-Path $renamed 'data') -and $description.Paths.StateRoot -ceq (Join-Path $renamed 'data\state') -and $description.Paths.RuntimeRoot -ceq $renamed -and $description.Paths.SkillRoot -ceq $renamed) '回复独立包仍依赖项目路径或误用安装目录名作为身份。'
            Assert-Layout (-not (Test-Path -LiteralPath (Join-Path $renamed 'data'))) '回复 Describe 不应创建任务数据或触发执行。'
            $packageChecks++
            continue
        }elseif($skill -eq 'douyin-rpa'){
            $description=& (Join-Path $renamed 'scripts\Invoke-DouyinSkill.ps1') -Action Describe|ConvertFrom-Json
            Assert-Layout ($description.Ok -and $description.Paths.DataRoot -ceq (Join-Path $renamed 'data')) '独立包仍依赖项目数据目录。'
            $output=& $powershell -NoProfile -File (Join-Path $renamed 'scripts\Invoke-DouyinRpa.ps1') -SelfTest
        }else{
            $output=& $powershell -NoProfile -File (Join-Path $renamed 'scripts\Invoke-DingTalkRpa.ps1') -Mode Check
        }
        Assert-Layout ($LASTEXITCODE -eq 0) ('独立包自检失败：'+$skill+' '+($output -join ' '))
        $reports=@(Get-ChildItem -LiteralPath (Join-Path $renamed 'data\runs') -Filter result.json -File -Recurse)
        Assert-Layout ($reports.Count -eq 1) '独立包证据目录错误。'
        $report=Get-Content -LiteralPath $reports[0].FullName -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-Layout ($report.Status -eq 'SelfTestPassed' -and $report.DesktopInputPerformed -eq $false) '独立包自检触发桌面或未通过。'
        $packageChecks++
    }
    [pscustomobject]@{Status='Passed';IndependentPackages=$packageChecks;ManifestHashes=$true;SourceAndDiscoverySameState=$true;RegistrationIdempotent=$true;LegacyLinkRetired=$true;RenamedUnicodePackages=$true;DesktopActions=0}
}finally{
    if(Test-Path -LiteralPath $links){foreach($link in Get-ChildItem -LiteralPath $links -Force){if($link.Attributes -band [IO.FileAttributes]::ReparsePoint){[IO.Directory]::Delete($link.FullName)}}}
    $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath($work)+'\'
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^layout-test-[a-f0-9]{32}$'){throw '拒绝清理未确认的结构测试目录。'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
