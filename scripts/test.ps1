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
    # Temporary read-only parameter matrix: only the classified local physical root is opened.
    try {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
public static class LocalMediaRootProbe {
 [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { public ushort Length,MaximumLength;public IntPtr Buffer; }
 [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes { public uint Length;public IntPtr Directory,Name;public uint Attributes;public IntPtr Security,QualityOfService; }
 [StructLayout(LayoutKind.Sequential)] private struct IoStatusBlock { public IntPtr Status;public UIntPtr Information; }
 [StructLayout(LayoutKind.Sequential)] private struct FileInformation {
  public uint Attributes,CreatedLow,CreatedHigh,AccessedLow,AccessedHigh,WrittenLow,WrittenHigh,Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint QueryDosDevice(string drive,StringBuilder target,uint length);
 [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInformation information);
 [DllImport("kernel32.dll",SetLastError=true)] private static extern uint GetFileType(SafeFileHandle file);
 [DllImport("ntdll.dll")] private static extern int NtCreateFile(out SafeFileHandle file,uint access,ref ObjectAttributes attributes,out IoStatusBlock io,IntPtr allocation,uint fileAttributes,uint share,uint creation,uint options,IntPtr extended,uint extendedLength);
 [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
 public static void Run(string drive) {
  if(!Regex.IsMatch(drive,@"^[A-Za-z]:$"))throw new ArgumentException("Probe requires one local drive letter.");
  StringBuilder target=new StringBuilder(32768);
  if(QueryDosDevice(drive,target,(uint)target.Capacity)==0)throw new Win32Exception(Marshal.GetLastWin32Error());
  if(!Regex.IsMatch(target.ToString(),@"^\\Device\\HarddiskVolume[0-9]+$",RegexOptions.IgnoreCase))throw new ArgumentException("Probe refused an unclassified device.");
  string root=target.ToString()+"\\";
  IntPtr text=Marshal.StringToHGlobalUni(root),unicode=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
  try {
   UnicodeString value=new UnicodeString {Length=(ushort)(root.Length*2),MaximumLength=(ushort)(root.Length*2+2),Buffer=text};
   Marshal.StructureToPtr(value,unicode,false);
   ObjectAttributes attributes=new ObjectAttributes {Length=(uint)Marshal.SizeOf(typeof(ObjectAttributes)),Name=unicode,Attributes=0x1040};
   Console.WriteLine("ROOT_PROBE root={0}, access=0x001000A0, share=3, disposition=1, attrs=0x80, objattrs=0x1040, objectSize={1}, unicodeSize={2}, ioSize={3}",root,attributes.Length,Marshal.SizeOf(typeof(UnicodeString)),Marshal.SizeOf(typeof(IoStatusBlock)));
   foreach(uint directory in new uint[] {1,0})foreach(uint recall in new uint[] {0,0x200000,0x400000,0x600000})foreach(uint backup in new uint[] {0,0x4000}) {
    uint options=0x20|directory|recall|backup;IoStatusBlock io;SafeFileHandle file;
    int status=NtCreateFile(out file,0x001000A0,ref attributes,out io,IntPtr.Zero,0x80,3,1,options,IntPtr.Zero,0);
    try {
     string metadata="not-opened";
     if(status>=0) {
      FileInformation information;
      if(!GetFileInformationByHandle(file,out information))metadata="inspect-error="+Marshal.GetLastWin32Error();
      else metadata="attributes=0x"+information.Attributes.ToString("X8")+", type="+GetFileType(file)+", directory="+((information.Attributes&0x10)!=0);
     }
     uint error=RtlNtStatusToDosError(status);
     Console.WriteLine("ROOT_PROBE options=0x{0:X8}, dir={1}, noFollow={2}, noRecall={3}, backup={4}, NTSTATUS=0x{5:X8}, Win32={6} ({7}), {8}",options,directory!=0,(recall&0x200000)!=0,(recall&0x400000)!=0,backup!=0,unchecked((uint)status),error,new Win32Exception(unchecked((int)error)).Message,metadata);
    } finally { if(file!=null)file.Dispose(); }
   }
  } finally { Marshal.FreeHGlobal(unicode);Marshal.FreeHGlobal(text); }
 }
}
'@
        [LocalMediaRootProbe]::Run(([IO.Path]::GetPathRoot([string]$outputRoot)).Substring(0,2))
    } catch { Write-Output ('ROOT_PROBE_FAILED: '+$_.Exception.ToString()) }
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
