function Get-RpaLayout([string]$SkillRoot) {
    $SkillRoot=[IO.Path]::GetFullPath($SkillRoot)
    $shared=[IO.Path]::GetFullPath($PSScriptRoot)
    $name=(Split-Path $SkillRoot -Leaf)
    $manifestPath=Join-Path $SkillRoot 'bundle.json'
    $packaged=(Test-Path -LiteralPath (Join-Path $SkillRoot 'shared\Runtime.ps1') -PathType Leaf)
    if($packaged){
        if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw '独立包缺少 bundle.json。'}
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        $name=$manifest.Name
        $repository=$null
        $versionPath=Join-Path $SkillRoot 'VERSION'
        $dataRoot=Join-Path $SkillRoot 'data'
        $legacyRoot=Join-Path $dataRoot 'legacy'
    }else{
        $skillsRoot=Split-Path $SkillRoot -Parent
        $repository=Split-Path $skillsRoot -Parent
        if((Split-Path $skillsRoot -Leaf) -ne 'skills' -or $shared -ne (Join-Path $repository 'shared')){throw 'Skill 必须位于项目 skills 目录，或使用包含 shared 的独立包。'}
        $versionPath=Join-Path $repository 'VERSION'
        $dataRoot=Join-Path $repository ('data\'+$name)
        $legacyRoot=Join-Path $repository 'data\legacy'
    }
    if($name -notin @('douyin-rpa','douyin-reply-rpa','dingtalk-rpa')){throw '未知的 RPA Skill。'}
    $dependencies=@($versionPath,(Join-Path $shared 'native\DingRpa.cs'),(Join-Path $shared 'core\Screenshot.ps1'))
    if($name -in @('douyin-rpa','douyin-reply-rpa')){
        foreach($relative in @('douyin\Urls.ps1','douyin\Browser.ps1','douyin\Comments.ps1')){$dependencies+=Join-Path $shared $relative}
    }
    foreach($required in $dependencies){
        if(-not (Test-Path -LiteralPath $required -PathType Leaf)){throw ('运行依赖缺失：'+$required)}
    }
    return [pscustomobject]@{Name=$name;SkillRoot=$SkillRoot;SharedRoot=$shared;RepositoryRoot=$repository;VersionPath=$versionPath;DataRoot=$dataRoot;StateRoot=(Join-Path $dataRoot 'state');RunsRoot=(Join-Path $dataRoot 'runs');LegacyRoot=$legacyRoot;Packaged=$packaged}
}
