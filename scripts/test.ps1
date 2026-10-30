$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $PSScriptRoot 'build.ps1')
$outputRoot=Join-Path $repoRoot 'build/DragonCodexBoot'
$exe=Join-Path $outputRoot 'DragonCodexBoot.exe'
$process=Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) { throw 'Launcher self-test failed. See build/DragonCodexBoot/self-test-error.txt.' }
$framework=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$argsList=@('/nologo','/target:exe','/platform:x64',('/out:'+(Join-Path $outputRoot 'GeometryTests.exe')),('/reference:'+$exe),'/reference:System.Web.Extensions.dll',('/reference:'+(Join-Path $framework 'WPF/PresentationFramework.dll')),('/reference:'+(Join-Path $framework 'WPF/WindowsBase.dll')),(Join-Path $repoRoot 'tests/GeometryTests.cs'))
& (Join-Path $framework 'csc.exe') @argsList
if ($LASTEXITCODE -ne 0) { throw 'Test harness compilation failed.' }
& (Join-Path $outputRoot 'GeometryTests.exe') (Join-Path $repoRoot 'config/launcher.example.json')
if ($LASTEXITCODE -ne 0) { throw 'Geometry or configuration tests failed.' }
$securityArgs=@('/nologo','/target:exe','/platform:x64',('/out:'+(Join-Path $outputRoot 'WindowsSecurityTests.exe')),('/reference:'+$exe),'/reference:System.dll','/reference:System.Core.dll','/reference:System.Web.Extensions.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll',('/reference:'+(Join-Path $framework 'WPF/PresentationFramework.dll')),('/reference:'+(Join-Path $framework 'WPF/WindowsBase.dll')),(Join-Path $repoRoot 'tests/WindowsSecurityTests.cs'))
& (Join-Path $framework 'csc.exe') @securityArgs
if ($LASTEXITCODE -ne 0) { throw 'Windows security test harness compilation failed.' }
$securityFixture=Join-Path $repoRoot ('.local/windows-security-'+[Guid]::NewGuid().ToString('N'))
$otherPackage=Get-AppxPackage | Where-Object { $_.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0' } | Select-Object -First 1
& (Join-Path $outputRoot 'WindowsSecurityTests.exe') $repoRoot $securityFixture $otherPackage.PackageFullName
if ($LASTEXITCODE -ne 0) { throw 'Windows process identity or system-tool security tests failed.' }
Get-Content -LiteralPath (Join-Path $outputRoot 'qa/windows-security-tests.json') -Raw
& (Join-Path $repoRoot 'tests/EntrypointTests.ps1')
Get-Content -LiteralPath (Join-Path $outputRoot 'qa/self-test.json') -Raw
