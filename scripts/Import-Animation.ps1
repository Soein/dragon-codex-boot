[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VideoPath,[string]$AppRoot)
$ErrorActionPreference='Stop'
$parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
# Load policy only from the script's own release or repository build, never from the caller's AppRoot.
$validator=Join-Path $parent 'DragonCodexBoot.exe'
if (!(Test-Path -LiteralPath $validator -PathType Leaf)) { $validator=Join-Path $parent 'build/DragonCodexBoot/DragonCodexBoot.exe' }
if (!(Test-Path -LiteralPath $validator -PathType Leaf)) { throw 'Build or extract the complete launcher before importing media.' }
[void][Reflection.Assembly]::LoadFrom($validator)
if (!$AppRoot) { $AppRoot=[IO.Path]::GetDirectoryName($validator) }
$currentDirectory=$ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
$destination=[DragonCodexBoot.Entry]::ImportAnimation($VideoPath,$AppRoot,$currentDirectory)
Write-Output ('Imported: '+$destination)
Write-Output 'Adjust HoldAt, TransitionStart, TransitionEnd and ScreenFrames for your video. Run tests before launching.'
