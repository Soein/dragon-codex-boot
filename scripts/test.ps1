$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $PSScriptRoot 'build.ps1')
$outputRoot=Join-Path $repoRoot 'build/DragonCodexBoot'
$exe=Join-Path $outputRoot 'DragonCodexBoot.exe'
$process=Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) {
    $selfTestError=Join-Path $outputRoot 'self-test-error.txt'
    if (Test-Path -LiteralPath $selfTestError -PathType Leaf) { Get-Content -LiteralPath $selfTestError -Encoding UTF8 -Raw }
    else { Write-Output ('Self-test exited with code '+$process.ExitCode+' without an error file.') }
    # Probe only the existing local test configuration while retaining the production metadata guard.
    $mediaGuard=$null
    try {
        $assembly=[Reflection.Assembly]::LoadFrom($exe)
        $policy=$assembly.GetType('DragonCodexBoot.LocalMediaPath',$true)
        $staticFlags=[Reflection.BindingFlags]'Static,NonPublic'
        $instanceFlags=[Reflection.BindingFlags]'Instance,NonPublic'
        [object[]]$guardArguments=@(([string]$outputRoot),([string]'launcher.json'))
        $mediaGuard=$policy.GetMethod('OpenFile',$staticFlags).Invoke($null,$guardArguments)
        $probePath=$mediaGuard.GetType().GetField('Path',$instanceFlags).GetValue($mediaGuard)
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class LocalReOpenProbe {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)]
 private static extern SafeFileHandle ReOpenFile(SafeFileHandle file,uint access,uint share,uint flags);
 public static string Run(string path,uint originalAccess,uint originalFlags,uint flags) {
  using(SafeFileHandle original=CreateFile(path,originalAccess,1,IntPtr.Zero,3,originalFlags,IntPtr.Zero)) {
   if(original.IsInvalid) {
    int error=Marshal.GetLastWin32Error();
    return String.Format("REOPEN PROBE originalAccess=0x{0:X}, originalFlags=0x{1:X}: CreateFile Win32 {2}: {3}",originalAccess,originalFlags,error,new Win32Exception(error).Message);
   }
   using(SafeFileHandle reopened=ReOpenFile(original,0x80000000,1,flags)) {
    int error=reopened.IsInvalid?Marshal.GetLastWin32Error():0;
    return String.Format("REOPEN PROBE originalAccess=0x{0:X}, originalFlags=0x{1:X}, flags=0x{2:X}: Win32 {3}: {4}",originalAccess,originalFlags,flags,error,new Win32Exception(error).Message);
   }
  }
 }
}
'@
        foreach ($originalAccess in @([uint32]128,[uint32]2147483648)) {
            foreach ($originalFlags in @([uint32]0x02000000,[uint32]0x02300000)) {
                foreach ($flags in @([uint32]0,[uint32]0x00200000,[uint32]0x00100000,[uint32]0x00300000)) {
                    [LocalReOpenProbe]::Run($probePath,$originalAccess,$originalFlags,$flags)
                }
            }
        }
    } catch { Write-Output ('Local ReOpen diagnostic failed: '+$_.Exception.ToString()) }
    finally { if ($mediaGuard) { ([IDisposable]$mediaGuard).Dispose() } }
    throw 'Launcher self-test failed. See build/DragonCodexBoot/self-test-error.txt.'
}
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
# The interoperability positive case must use an activatable main package, matching the production HEAD filter.
$otherPackage=Get-AppxPackage -PackageTypeFilter Main | Where-Object { $_.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0' } | Select-Object -First 1
& (Join-Path $outputRoot 'WindowsSecurityTests.exe') $repoRoot $securityFixture $otherPackage.PackageFullName
if ($LASTEXITCODE -ne 0) { throw 'Windows process identity or system-tool security tests failed.' }
Get-Content -LiteralPath (Join-Path $outputRoot 'qa/windows-security-tests.json') -Raw
& (Join-Path $repoRoot 'tests/ImportAnimationTests.ps1')
Get-Content -LiteralPath (Join-Path $outputRoot 'qa/import-animation-tests.json') -Raw
& (Join-Path $repoRoot 'tests/EntrypointTests.ps1')
Get-Content -LiteralPath (Join-Path $outputRoot 'qa/self-test.json') -Raw
