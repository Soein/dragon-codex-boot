$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'scripts/entrypoint-safety.ps1')
$fixture=Join-Path $repoRoot ('.local/entrypoint-tests-'+[Guid]::NewGuid().ToString('N'))
$appRoot=Join-Path $fixture 'app'
$linksRoot=Join-Path $fixture 'shortcuts'
$nested=Join-Path $linksRoot 'nested'
New-Item -ItemType Directory -Path $appRoot,$linksRoot,$nested -Force | Out-Null
# Only the generated fixture receives a private ACL; existing repository/system ACLs are untouched.
$privateAcl=New-Object Security.AccessControl.DirectorySecurity
$privateAcl.SetOwner($entrypointUserSid)
$privateAcl.SetAccessRuleProtection($true,$false)
foreach ($sid in @($entrypointUserSid.Value,'S-1-5-18','S-1-5-32-544')) {
    $identity=New-Object Security.Principal.SecurityIdentifier($sid)
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $privateAcl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $fixture -AclObject $privateAcl
foreach ($path in @($appRoot,$linksRoot,$nested)) { Set-EntrypointGeneratedOwner $path }
Copy-Item -LiteralPath (Join-Path $repoRoot 'build/DragonCodexBoot/DragonCodexBoot.exe') -Destination $appRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'config/launcher.example.json') -Destination (Join-Path $appRoot 'launcher.json')
$official=Join-Path $fixture 'OfficialClient.exe'
$other=Join-Path $fixture 'Other.exe'
[IO.File]::WriteAllBytes($official,[byte[]]@(1));[IO.File]::WriteAllBytes($other,[byte[]]@(2))
foreach ($path in @($official,$other,(Join-Path $appRoot 'DragonCodexBoot.exe'),(Join-Path $appRoot 'launcher.json'))) { Set-EntrypointGeneratedOwner $path }
$shell=New-Object -ComObject WScript.Shell
$script:checks=0
function Check([bool]$Ok,[string]$Message) { if (!$Ok) { throw $Message };$script:checks++ }
function Reject([scriptblock]$Operation,[string]$Message) {
    $rejected=$false
    try { $null=& $Operation } catch { $rejected=$true }
    Check $rejected $Message
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash }
function Make-Link([string]$Name,[string]$Target,[string]$Arguments='') {
    $path=Join-Path $linksRoot $Name
    $link=$shell.CreateShortcut($path);$link.TargetPath=$Target;$link.Arguments=$Arguments
    $link.IconLocation=$other+',0';$link.WorkingDirectory=$fixture;$link.Description='Original description';$link.Save()
    Set-EntrypointGeneratedOwner $path
    return $path
}
function Run([string]$Action) {
    # Every operation is confined to fixtures. No actual Desktop, Start or taskbar folder is scanned.
    $null=& (Join-Path $repoRoot 'scripts/integrate-entrypoints.ps1') -Action $Action -AppRoot $appRoot -SearchRoots $linksRoot -OfficialExecutablePaths $official -NoCreateDefaultLinks
    Get-Content -LiteralPath (Join-Path $appRoot '.integration/report.json') -Encoding UTF8 -Raw | ConvertFrom-Json
}
$direct=Make-Link 'renamed official.lnk' $official
$apps=Make-Link 'nested/appsfolder.lnk' (Join-Path $env:WINDIR 'explorer.exe') 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
$sameName=Make-Link 'ChatGPT.lnk' $other
$wrongApp=Make-Link 'wrong-package.lnk' (Join-Path $env:WINDIR 'explorer.exe') 'shell:AppsFolder\Other.App_123!App'
$withArgs=Make-Link 'command-arguments.lnk' (Join-Path $env:WINDIR 'explorer.exe') 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App extra'
$url=Join-Path $linksRoot 'ChatGPT.url';Set-Content -LiteralPath $url -Encoding ASCII -Value "[InternetShortcut]`r`nURL=https://chatgpt.com/"
Set-EntrypointGeneratedOwner $url
$all=@($direct,$apps,$sameName,$wrongApp,$withArgs,$url)
$hashes=@{};foreach ($path in $all) { $hashes[$path]=Hash $path }
$cfg=Get-Content -LiteralPath (Join-Path $appRoot 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg.ScanAllLocalDrives=$true
$cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $appRoot 'launcher.json') -Encoding UTF8
$defaults=@(Get-EntrypointDefaultRoots)
$expectedDefaults=@(@([Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('Programs')) | Where-Object { $_ })
$userAppData=[Environment]::GetFolderPath('ApplicationData')
if ($userAppData) { $expectedDefaults+=@(Join-Path $userAppData 'Microsoft/Internet Explorer/Quick Launch') }
Check ($defaults.Count -eq $expectedDefaults.Count -and @($defaults | Where-Object { $expectedDefaults -notcontains $_ }).Count -eq 0) 'Default roots must contain only the available current user Desktop, Programs and Quick Launch.'
$install=Run 'Auto'
Check ($install.Replaced -eq 2 -and $install.Errors.Count -eq 0 -and $install.FoldersInspected -eq 2) 'Official and AppsFolder links must be found recursively.'
Check ($install.IgnoredLegacyScanAllLocalDrives -and $install.SearchScope -eq 'CurrentUserOnly' -and $install.SearchRoots.Count -eq 1 -and $install.SearchRoots[0] -ieq $linksRoot) 'Legacy full-drive settings must not expand the scan scope.'
foreach ($path in @($direct,$apps)) {
    $link=$shell.CreateShortcut($path)
    Check ($link.TargetPath -ieq (Join-Path $appRoot 'DragonCodexBoot.exe')) 'Target must be launcher.'
    Check ($link.Arguments -eq '' -and $link.WorkingDirectory -ieq $appRoot) 'Launcher must have clean args and its own working directory.'
    Check ($link.IconLocation -ieq $other+',0') 'Original icon must be preserved.'
}
foreach ($path in @($sameName,$wrongApp,$withArgs,$url)) { Check ((Hash $path) -eq $hashes[$path]) 'Unrelated links and web URLs must remain byte-identical.' }
$statePath=Join-Path $appRoot '.integration/entrypoints-state.json'
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($state.Entries.Count -eq 2 -and $state.AutoAttempted) 'Exactly two backup records expected.'
foreach ($record in $state.Entries) { Check ((Hash $record.OriginalBackup) -eq $hashes[$record.Path]) 'Backups must match original bytes.' }
$savedState=Hash $statePath
$firstReport=Hash (Join-Path $appRoot '.integration/report.json')
$null=Run 'Auto'
Check ((Hash $statePath) -eq $savedState -and (Hash (Join-Path $appRoot '.integration/report.json')) -eq $firstReport) 'Later Auto must not rescan or erase first-run report.'
$again=Run 'Install'
Check ($again.Replaced -eq 0 -and $again.AlreadyOwned -eq 2) 'Explicit rescan is idempotent.'
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($state.Entries.Count -eq 2) 'Rescan must not replace original backups.'
$verify=Run 'Verify';Check ($verify.AlreadyOwned -eq 2) 'Installed links must verify.'
$changed=$shell.CreateShortcut($direct);$changed.Description='User changed shortcut';$changed.Save()
$changedHash=Hash $direct
$hardlinkPeer=Join-Path $fixture 'restore-hardlink-peer.lnk'
$null=New-Item -ItemType HardLink -Path $hardlinkPeer -Value $apps
$peerHash=Hash $hardlinkPeer
$restore=Run 'Restore'
Check ($restore.Restored -eq 1 -and $restore.Preserved.Count -eq 1) 'Restore must preserve subsequent user edits.'
Check ((Hash $apps) -eq $hashes[$apps]) 'Original shortcut must be restored exactly.'
Check ((Hash $direct) -eq $changedHash) 'Changed shortcut must be preserved exactly.'
Check ((Hash $hardlinkPeer) -eq $peerHash) 'Restoring a shortcut must replace its directory entry without modifying another hard link.'
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($state.Restored -and $state.AutoAttempted) 'Restore must suppress automatic reinstallation.'
$restoreReport=Hash (Join-Path $appRoot '.integration/report.json')
$null=Run 'Auto'
Check ((Hash (Join-Path $appRoot '.integration/report.json')) -eq $restoreReport) 'Startup after restore must not reinstall.'
foreach ($path in @($sameName,$wrongApp,$withArgs,$url)) { Check ((Hash $path) -eq $hashes[$path]) 'Unrelated assets must remain unchanged after restore.' }
$second=Run 'Install';Check ($second.Replaced -eq 1 -and $second.Preserved.Count -eq 1) 'Explicit reinstall must still preserve modified previously owned links.'
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$record=@($state.Entries | Where-Object { $_.Path -eq $apps -and !$_.Restored })[0]
[IO.File]::WriteAllBytes($record.OriginalBackup,[byte[]]@(9))
$installedHash=Hash $apps
$corrupt=Run 'Restore'
Check ($corrupt.Errors.Count -eq 1 -and (Hash $apps) -eq $installedHash) 'Corrupted backup must never be restored.'
# A record for a new link is exercised separately; deletion is only permitted after ownership hash verification.
$created=Make-Link 'created-fixture.lnk' (Join-Path $appRoot 'DragonCodexBoot.exe')
$link=$shell.CreateShortcut($created);$link.WorkingDirectory=$appRoot;$link.Arguments='';$link.Save()
$state.Entries=@([pscustomobject]@{Path=$created;OriginalExists=$false;OriginalBackup=$null;OriginalSHA256=$null;InstalledSHA256=(Hash $created);Restored=$false})
$state.Restored=$false;$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
$deleted=Run 'Restore';Check ($deleted.Restored -eq 1 -and !(Test-Path -LiteralPath $created)) 'Only a verified project-created shortcut may be removed.'
$cfg=Get-Content -LiteralPath (Join-Path $appRoot 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg.AutoReplaceEntrypoints=$false;$cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $appRoot 'launcher.json') -Encoding UTF8
$state.AutoAttempted=$false;$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
$disabled=Run 'Auto';Check ($disabled.Status -eq 'Disabled') 'Explicit opt-out must prevent integration.'
# A sharing violation must leave the original intact and retain a valid backup for recovery.
$lockedLink=Make-Link 'locked-fixture.lnk' $official
$lockedOriginal=Hash $lockedLink
$lock=[IO.File]::Open($lockedLink,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $lockedReport=Run 'Install'
    Check ($lockedReport.Errors.Count -ge 1 -and (Hash $lockedLink) -eq $lockedOriginal) 'Write failure must preserve original bytes.'
} finally { $lock.Dispose() }
$unwritten=Run 'Restore'
Check ((Hash $lockedLink) -eq $lockedOriginal) 'Restore must accept an unchanged original after a failed write.'
# Rejected explicit roots must never become an alternate shared or system integration mode.
$integration=Join-Path $repoRoot 'scripts/integrate-entrypoints.ps1'
$startMenu=Join-Path $repoRoot 'scripts/install-start-menu.ps1'
$publicDesktop=[Environment]::GetFolderPath('CommonDesktopDirectory')
$savedState=Hash $statePath
foreach ($unsafe in @($publicDesktop,[Environment]::GetFolderPath('CommonPrograms'),[IO.Path]::GetPathRoot($fixture),'\\localhost\invalid-entrypoint-share')) {
    Reject { & $integration -Action Install -AppRoot $appRoot -SearchRoots $unsafe -OfficialExecutablePaths $official -NoCreateDefaultLinks } 'Shared, drive-root and UNC search roots must be rejected.'
}
Check ((Hash $statePath) -eq $savedState) 'Rejected roots must not mutate saved integration state.'
$aclRoot=Join-Path $fixture 'acl-cases'
New-EntrypointDirectory $aclRoot
$authenticated=New-Object Security.Principal.SecurityIdentifier('S-1-5-11')
$acl=Get-Acl -LiteralPath $aclRoot
$readRule=New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'ReadAndExecute','Allow')
$acl.AddAccessRule($readRule);Set-Acl -LiteralPath $aclRoot -AclObject $acl
Assert-EntrypointPath $aclRoot -Directory
Check $true 'Read-only Authenticated Users access must remain supported.'
$writeRule=New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'Write','Allow')
$acl.AddAccessRule($writeRule);Set-Acl -LiteralPath $aclRoot -AclObject $acl
Reject { & $integration -Action Install -AppRoot $appRoot -SearchRoots $aclRoot -NoCreateDefaultLinks } 'Directories writable by other ordinary accounts must be rejected.'
Reject { & $startMenu -Action Restore -AppRoot $aclRoot } 'Start-menu restoration must reject a shared-writable installation before using its state.'
Set-Acl -LiteralPath $aclRoot -AclObject $privateAcl
$child=Join-Path $aclRoot 'private-child'
New-EntrypointDirectory $child
$acl=Get-Acl -LiteralPath $aclRoot
$createRule=New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'CreateFiles,CreateDirectories','Allow')
$acl.AddAccessRule($createRule);Set-Acl -LiteralPath $aclRoot -AclObject $acl
Assert-EntrypointPath $child -Directory
Check $true 'Ancestor permission to create siblings must not be treated as permission to replace existing children.'
$deleteChildRule=New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'DeleteSubdirectoriesAndFiles','Allow')
$acl.AddAccessRule($deleteChildRule);Set-Acl -LiteralPath $aclRoot -AclObject $acl
Reject { Assert-EntrypointPath $child -Directory } 'Ancestor permission to delete existing children must be rejected.'
Set-Acl -LiteralPath $aclRoot -AclObject $privateAcl
$junction=Join-Path $fixture 'junction'
$null=New-Item -ItemType Junction -Path $junction -Value $linksRoot
Reject { & $integration -Action Install -AppRoot $appRoot -SearchRoots $junction -NoCreateDefaultLinks } 'Explicit reparse roots must be rejected.'
$stateApp=Join-Path $fixture 'reparse-state-app'
$foreignState=Join-Path $fixture 'foreign-state'
New-EntrypointDirectory $stateApp
New-EntrypointDirectory $foreignState
$null=New-Item -ItemType Junction -Path (Join-Path $stateApp '.integration') -Value $foreignState
Reject { & $integration -Action Restore -AppRoot $stateApp -SearchRoots $linksRoot } 'Integration must reject a redirected state directory before writing through it.'
Reject { & $startMenu -Action Restore -AppRoot $stateApp } 'Start-menu restoration must reject redirected state.'
Check (!(Test-Path -LiteralPath (Join-Path $foreignState 'backups')) -and !(Test-Path -LiteralPath (Join-Path $foreignState 'report.json'))) 'Rejected state directories must not receive generated backups or reports.'
$shortAlias=(New-Object -ComObject Scripting.FileSystemObject).GetFolder($linksRoot).ShortPath
$aliasChecked=$false
if ($shortAlias -ine $linksRoot) {
    $aliasDiagnostic=[ordered]@{
        original=$shortAlias
        expected=$linksRoot
        fullPath=[IO.Path]::GetFullPath($shortAlias)
        entrypointPath=Get-EntrypointPath $shortAlias
        resolvedShort=[DragonCodexBoot.EntrypointNativePath]::Resolve($shortAlias)
        resolvedLong=[DragonCodexBoot.EntrypointNativePath]::Resolve($linksRoot)
    }
    Write-Output ('Entrypoint short-name diagnostic: '+($aliasDiagnostic | ConvertTo-Json -Compress))
    Reject { Assert-EntrypointPath $shortAlias -Directory } 'Short-name aliases must not bypass the physical path boundary.'
    $aliasChecked=$true
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $ownerAcl=Get-Acl -LiteralPath $aclRoot
    $ownerAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $aclRoot -AclObject $ownerAcl
    Reject { Assert-EntrypointPath $aclRoot -Directory } 'Even an elevated process must reject paths owned by a different SID.'
    Set-Acl -LiteralPath $aclRoot -AclObject $privateAcl
}
# Legacy or tampered state is data, never authority to write arbitrary paths.
$safe=Make-Link 'restore-boundary.lnk' (Join-Path $appRoot 'DragonCodexBoot.exe')
$safeHash=Hash $safe
$escapedBackup=Join-Path $fixture 'escaped-backup.lnk'
Copy-Item -LiteralPath $safe -Destination $escapedBackup;Set-EntrypointGeneratedOwner $escapedBackup
$nestedRestore=Make-Link 'restore-reparse-backup.lnk' (Join-Path $appRoot 'DragonCodexBoot.exe')
$nestedHash=Hash $nestedRestore
$backupJunction=Join-Path $appRoot '.integration/backups/redirect'
$null=New-Item -ItemType Junction -Path $backupJunction -Value $fixture
$badShared=Join-Path $publicDesktop ('DragonCodexBoot-test-'+[Guid]::NewGuid().ToString('N')+'.lnk')
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$state.Entries=@(
    [pscustomobject]@{Path=$badShared;OriginalExists=$false;OriginalBackup=$null;OriginalSHA256=$null;InstalledSHA256='unused';Restored=$false},
    [pscustomobject]@{Path=$official;OriginalExists=$false;OriginalBackup=$null;OriginalSHA256=$null;InstalledSHA256=(Hash $official);Restored=$false},
    [pscustomobject]@{Path=$safe;OriginalExists=$true;OriginalBackup=$escapedBackup;OriginalSHA256=(Hash $escapedBackup);InstalledSHA256=$safeHash;Restored=$false},
    [pscustomobject]@{Path=$nestedRestore;OriginalExists=$true;OriginalBackup=(Join-Path $backupJunction 'escaped-backup.lnk');OriginalSHA256=(Hash $escapedBackup);InstalledSHA256=$nestedHash;Restored=$false}
)
# Make the backup distinguishable so the unchanged-original shortcut optimization cannot hide the boundary check.
$backupLink=$shell.CreateShortcut($escapedBackup);$backupLink.Description='Escaped backup';$backupLink.Save()
$state.Entries[2].OriginalSHA256=Hash $escapedBackup
$state.Entries[3].OriginalSHA256=Hash $escapedBackup
$state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
$boundary=Run 'Restore'
Check ($boundary.Errors.Count -eq 4 -and $boundary.Restored -eq 0) 'Restore must reject legacy shared targets, non-shortcuts and escaped or redirected backups.'
Check ((Hash $safe) -eq $safeHash -and (Hash $nestedRestore) -eq $nestedHash -and (Test-Path -LiteralPath $official)) 'Rejected restore records must not replace or remove their targets.'
$verified=Run 'Verify'
Check ($verified.Status -eq 'VerifiedWithRejectedPaths' -and $verified.Errors.Count -eq 2) 'Verification must report unsafe state paths without treating them as verified.'
@{ok=$true;checks=$checks;shortNameAliasExercised=$aliasChecked;scope='Isolated .lnk file metadata and backup/restore only; no actual user entrypoints changed.'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repoRoot 'build/DragonCodexBoot/qa/entrypoint-tests.json') -Encoding UTF8
Write-Output ('PASS: '+$checks+' isolated entrypoint assertions. No desktop UI or actual shortcuts changed.')
