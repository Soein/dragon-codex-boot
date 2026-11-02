$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture=Join-Path $repoRoot ('.local/import-animation-tests-'+[Guid]::NewGuid().ToString('N'))
$appRoot=Join-Path $fixture ('local app & spaces! '+[char]0x672c+[char]0x5730)
New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
$script:checks=0
function Check([bool]$Ok,[string]$Message) { if (!$Ok) { throw $Message };$script:checks++ }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$import=Join-Path $repoRoot 'scripts/Import-Animation.ps1'
# An invalid destination EXE proves the script loads policy from its own trusted build, not AppRoot.
[IO.File]::WriteAllBytes((Join-Path $appRoot 'DragonCodexBoot.exe'),[byte[]]@(42))
$configPath=Join-Path $appRoot 'launcher.json'
@{Video='previous.mp4';PreservedSetting='keep this'} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$originalConfig=Hash $configPath
$source=Join-Path $fixture 'source #100%.mp4'
[IO.File]::WriteAllBytes($source,[byte[]]@(1,2,3,4))
$null=& $import -VideoPath $source -AppRoot $appRoot
$destination=Join-Path $appRoot 'media/startup.mp4'
Check ((Hash $destination) -eq (Hash $source)) 'Normal local MP4 import must preserve bytes.'
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($config.Video -eq 'media/startup.mp4' -and $config.PreservedSetting -eq 'keep this') 'Import must update Video and retain unrelated settings.'
$backups=@(Get-ChildItem -LiteralPath $appRoot -Filter 'launcher.json.backup-*')
Check ($backups.Count -eq 1 -and (Hash $backups[0].FullName) -eq $originalConfig) 'Configuration backup must preserve original bytes.'
$beforeVideo=Hash $destination
[IO.File]::WriteAllBytes($source,[byte[]]@(5,6,7,8))
Push-Location $fixture
try { $null=& $import -VideoPath ([IO.Path]::GetFileName($source)) -AppRoot $appRoot } finally { Pop-Location }
Check ((Hash $destination) -eq (Hash $source)) 'Relative local MP4 input must remain supported.'
$mediaBackups=@(Get-ChildItem -LiteralPath (Join-Path $appRoot 'media') -Filter 'startup-backup-*.mp4')
Check ($mediaBackups.Count -eq 1 -and (Hash $mediaBackups[0].FullName) -eq $beforeVideo) 'Replacing media must keep a verified backup.'
$beforeVideo=Hash $destination;$beforeConfig=Hash $configPath
$configBackupCount=@(Get-ChildItem -LiteralPath $appRoot -Filter 'launcher.json.backup-*').Count
$mediaBackupCount=$mediaBackups.Count
$heldLock=[IO.File]::Open((Join-Path $appRoot '.dragon-media-import.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$conflict=$false
try { $null=& $import -VideoPath $source -AppRoot $appRoot }
catch { $conflict=$_.Exception.ToString() -match 'Win32 32:' }
finally { $heldLock.Dispose() }
Check ($conflict -and (Hash $destination) -eq $beforeVideo -and (Hash $configPath) -eq $beforeConfig) 'An active import lock must reject a competing import without changing media or configuration.'
Check (@(Get-ChildItem -LiteralPath $appRoot -Filter 'launcher.json.backup-*').Count -eq $configBackupCount -and @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'media') -Filter 'startup-backup-*.mp4').Count -eq $mediaBackupCount) 'A rejected concurrent import must not create backups before acquiring its lock.'
$beforeVideo=Hash $destination;$beforeConfig=Hash $configPath
[IO.File]::WriteAllBytes($source,[byte[]]@(9,10,11,12))
[IO.File]::SetAttributes($configPath,[IO.FileAttributes]::ReadOnly)
$rejected=$false
try { $null=& $import -VideoPath $source -AppRoot $appRoot } catch { $rejected=$true }
finally { [IO.File]::SetAttributes($configPath,[IO.FileAttributes]::Normal) }
Check ($rejected -and (Hash $destination) -eq $beforeVideo -and (Hash $configPath) -eq $beforeConfig) 'A configuration commit failure must preserve configuration and restore previous media.'
Check (@(Get-ChildItem -LiteralPath $appRoot -Filter '.dragon-media-*.tmp' -Recurse -Force).Count -eq 0) 'Failed imports must remove their own temporary files.'
$null=& $import -VideoPath $destination -AppRoot $appRoot
Check ((Hash $destination) -eq $beforeVideo) 'Importing the existing destination must preserve its bytes.'
@{ok=$true;checks=$checks;scope='Only local isolated MP4 byte copies and import recovery; no media decoder, remote share or user entrypoint accessed.'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repoRoot 'build/DragonCodexBoot/qa/import-animation-tests.json') -Encoding UTF8
Write-Output ('PASS: '+$checks+' isolated media import assertions.')
