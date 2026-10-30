$ErrorActionPreference='Stop'
if (!$env:GITHUB_ENV) { throw 'This script requires a GitHub Actions environment file.' }
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$localData=[Environment]::GetFolderPath('LocalApplicationData')
if (!$localData -or !(Test-Path -LiteralPath $localData -PathType Container)) {
    throw 'The current Windows account must have an existing local application data directory.'
}
if (!(Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)) {
    throw 'The Windows CI workspace requires a complete checkout with a .git directory.'
}
. (Join-Path $PSScriptRoot 'entrypoint-safety.ps1')
$workspace=Join-Path $localData ('DragonCodexBoot-ci-'+[Guid]::NewGuid().ToString('N'))
try {
    # Only this newly created task directory receives an ACL; existing ancestors remain unchanged.
    $null=New-Item -ItemType Directory -Path $workspace
    $privateAcl=New-Object Security.AccessControl.DirectorySecurity
    $privateAcl.SetOwner($entrypointUserSid)
    $privateAcl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @($entrypointUserSid.Value,'S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $privateAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $workspace -AclObject $privateAcl
    Assert-EntrypointPath $workspace -Directory
    Get-ChildItem -LiteralPath $repoRoot -Force | Copy-Item -Destination $workspace -Recurse -Force
    # Elevated runners can otherwise create .git with Administrators as its owner.
    Set-EntrypointGeneratedOwner (Join-Path $workspace '.git')
    $sourceHead=& git -C $repoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the checked-out Git revision.' }
    $copiedHead=& git -C $workspace rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $copiedHead -ne $sourceHead) { throw 'The private workspace Git revision does not match the checkout.' }
    Assert-EntrypointPath $workspace -Directory
    ('DRAGON_CI_WORKSPACE='+$workspace) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Output ('Prepared private Windows CI workspace: '+$workspace+'; revision: '+$copiedHead)
} catch {
    $current=$workspace
    while ($current) {
        if (Test-Path -LiteralPath $current -PathType Container) {
            try {
                $acl=Get-Acl -LiteralPath $current
                Write-Warning ('Windows CI directory ACL: '+$current+'; owner='+$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value+'; SDDL='+$acl.Sddl)
            } catch { Write-Warning ('Could not read Windows CI directory ACL: '+$current) }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if (!$parent -or $parent -eq $current) { break }
        $current=$parent
    }
    throw
}
