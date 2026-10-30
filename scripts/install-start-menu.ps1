[CmdletBinding()]
param([ValidateSet('Install','Verify','Restore')][string]$Action='Install',[string]$AppRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'entrypoint-safety.ps1')
if (!$AppRoot) {
    $parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    if (Test-Path -LiteralPath (Join-Path $parent 'DragonCodexBoot.exe')) { $AppRoot=$parent }
    else { $AppRoot=Join-Path $parent 'build/DragonCodexBoot' }
}
$AppRoot=Get-EntrypointPath $AppRoot
Assert-EntrypointPath $AppRoot -Directory
$exePath=Join-Path $AppRoot 'DragonCodexBoot.exe'
$programs=[Environment]::GetFolderPath('Programs')
if ([string]::IsNullOrWhiteSpace($programs)) { throw 'User Start menu folder unavailable.' }
$shortcutPath=Join-Path $programs 'Dragon Codex Boot.lnk'
$stateRoot=Join-Path $AppRoot '.integration'
$statePath=Join-Path $stateRoot 'start-menu-state.json'
Assert-EntrypointPath $programs -AllowMissing -Directory
Assert-EntrypointLink $shortcutPath -AllowMissing
Assert-EntrypointPath $stateRoot -AllowMissing -Directory
Assert-EntrypointPath $statePath -AllowMissing
$shell=New-Object -ComObject WScript.Shell
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Save-State($Value) {
    Assert-EntrypointPath $statePath -AllowMissing
    $temp=$statePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
        Set-EntrypointGeneratedOwner $temp
        Assert-EntrypointPath $statePath -AllowMissing
        Move-Item -LiteralPath $temp -Destination $statePath -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
function Verify {
    Assert-EntrypointLink $shortcutPath
    if (!(Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw 'Shortcut missing.' }
    $link=$shell.CreateShortcut($shortcutPath)
    if (![string]::Equals($link.TargetPath,$exePath,[StringComparison]::OrdinalIgnoreCase) -or $link.Arguments -ne '' -or
        ![string]::Equals($link.IconLocation,$exePath+',0',[StringComparison]::OrdinalIgnoreCase) -or
        ![string]::Equals($link.WorkingDirectory,$AppRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Shortcut properties differ.' }
    [pscustomobject]@{Shortcut=$shortcutPath;Target=$link.TargetPath;Verified=$true;Pinned=$null}
}
if ($Action -eq 'Verify') { Verify; return }
$previous=$null
if (Test-Path -LiteralPath $statePath) { $previous=Get-Content -LiteralPath $statePath -Encoding UTF8 -Raw | ConvertFrom-Json }
if ($Action -eq 'Restore') {
    if (!$previous -or $previous.Restored) { Write-Output 'Nothing to restore.'; return }
    if (![string]::Equals($previous.Shortcut,$shortcutPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'State path mismatch.' }
    if ((Test-Path -LiteralPath $shortcutPath) -and (Hash $shortcutPath) -ne $previous.InstalledSHA256) { throw 'Shortcut changed; preserved.' }
    if ($previous.OriginalExists) {
        Assert-EntrypointBackup $previous.OriginalBackup $stateRoot
        if ([IO.Path]::GetFileName($previous.OriginalBackup) -notmatch '^backup-[a-f0-9]{32}\.lnk$' -or
            (Hash $previous.OriginalBackup) -ne $previous.OriginalSHA256) { throw 'Backup verification failed.' }
        $temp=Join-Path $programs ('DragonCodexBoot-'+[Guid]::NewGuid().ToString('N')+'.lnk')
        try {
            Copy-Item -LiteralPath $previous.OriginalBackup -Destination $temp
            Set-EntrypointGeneratedOwner $temp
            if ((Hash $temp) -ne $previous.OriginalSHA256) { throw 'Restore copy verification failed.' }
            Assert-EntrypointLink $shortcutPath -AllowMissing
            if ((Test-Path -LiteralPath $shortcutPath) -and (Hash $shortcutPath) -ne $previous.InstalledSHA256) { throw 'Shortcut changed; preserved.' }
            Move-Item -LiteralPath $temp -Destination $shortcutPath -Force
            if ((Hash $shortcutPath) -ne $previous.OriginalSHA256) { throw 'Restore verification failed.' }
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
    } elseif (Test-Path -LiteralPath $shortcutPath) {
        # Remove only the exact task-owned shortcut after its checksum has been verified.
        Remove-Item -LiteralPath $shortcutPath
    }
    $previous.Restored=$true
    Save-State $previous
    Write-Output 'Shortcut restored. Unpin the launcher separately in Start if it was pinned.'
    return
}
if (!(Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Build or extract the launcher first.' }
Assert-EntrypointPath $exePath
New-EntrypointDirectory $stateRoot
New-EntrypointDirectory $programs
$owned=$previous -and !$previous.Restored -and (Test-Path -LiteralPath $shortcutPath) -and
    [string]::Equals($previous.Shortcut,$shortcutPath,[StringComparison]::OrdinalIgnoreCase) -and (Hash $shortcutPath) -eq $previous.InstalledSHA256
$originalExists=$false;$originalBackup=$null;$originalHash=$null
if ($owned) {
    $originalExists=$previous.OriginalExists;$originalBackup=$previous.OriginalBackup;$originalHash=$previous.OriginalSHA256
} elseif (Test-Path -LiteralPath $shortcutPath) {
    $originalExists=$true
    $originalBackup=Join-Path $stateRoot ('backup-'+[Guid]::NewGuid().ToString('N')+'.lnk')
    Copy-Item -LiteralPath $shortcutPath -Destination $originalBackup
    Set-EntrypointGeneratedOwner $originalBackup
    $originalHash=Hash $shortcutPath
    if ((Hash $originalBackup) -ne $originalHash) { throw 'Backup mismatch.' }
}
$beforeHash=if (Test-Path -LiteralPath $shortcutPath) { Hash $shortcutPath } else { $null }
$temp=Join-Path $programs ('DragonCodexBoot-'+[Guid]::NewGuid().ToString('N')+'.lnk')
try {
    $link=$shell.CreateShortcut($temp)
    $link.TargetPath=$exePath;$link.Arguments='';$link.WorkingDirectory=$AppRoot;$link.IconLocation=$exePath+',0'
    $link.Description='Play a custom startup animation, then hand off to the Codex desktop client.'
    $link.Save()
    Set-EntrypointGeneratedOwner $temp
    Assert-EntrypointLink $shortcutPath -AllowMissing
    if ($beforeHash) {
        if (!(Test-Path -LiteralPath $shortcutPath) -or (Hash $shortcutPath) -ne $beforeHash) { throw 'Shortcut changed; preserved.' }
    } elseif (Test-Path -LiteralPath $shortcutPath) { throw 'A shortcut appeared; preserved.' }
    Move-Item -LiteralPath $temp -Destination $shortcutPath -Force
} finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
$report=Verify
Save-State @{Shortcut=$shortcutPath;InstalledSHA256=(Hash $shortcutPath);OriginalExists=$originalExists;OriginalBackup=$originalBackup;OriginalSHA256=$originalHash;Restored=$false}
$report
Write-Output 'Right-click DragonCodexBoot.exe in Explorer and choose Pin to Start. This script registers the shortcut only.'
