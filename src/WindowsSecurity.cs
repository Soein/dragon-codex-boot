using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

[assembly: InternalsVisibleTo("WindowsSecurityTests")]

namespace DragonCodexBoot {
 internal static class SystemExecutables {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  private static extern uint GetSystemWindowsDirectory(StringBuilder path,uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  private static extern uint GetSystemDirectory(StringBuilder path,uint size);
  internal static string DirectoryPath(bool windows) {
   StringBuilder path=new StringBuilder(32768);
   uint length=windows?GetSystemWindowsDirectory(path,(uint)path.Capacity):GetSystemDirectory(path,(uint)path.Capacity);
   if(length==0||length>=path.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot resolve the Windows system directory.");
   return Path.GetFullPath(path.ToString());
  }
  internal static string PowerShellPath { get { return Path.Combine(DirectoryPath(false),"WindowsPowerShell","v1.0","powershell.exe"); } }
  internal static ProcessStartInfo ExplorerStartInfo(string application) {
   if(!PackageTrust.IsOfficialLaunch(application))throw new ArgumentException("Only the supported official Codex application can be launched.");
   string windows=DirectoryPath(true);
   return new ProcessStartInfo(Path.Combine(windows,"explorer.exe"),application) { UseShellExecute=false,WorkingDirectory=windows };
  }
 }
 internal sealed class PackageIdentity {
  internal readonly string Family,FullName,InstallPath,ImagePath;
  internal readonly uint Origin,Properties;
  internal PackageIdentity(string family,string fullName,string installPath,string imagePath,uint origin,uint properties) {
   Family=family;FullName=fullName;InstallPath=installPath;ImagePath=imagePath;Origin=origin;Properties=properties;
  }
 }
 internal static class PackageTrust {
  internal const string OfficialFamily="OpenAI.Codex_2p2nqsd0c76g0";
  internal const uint StoreOrigin=3,DevelopmentMode=0x00010000;
  internal static bool IsOfficialLaunch(string value) {
   string prefix="shell:AppsFolder\\"+OfficialFamily+"!";
   return value!=null&&value.StartsWith(prefix,StringComparison.Ordinal)
    &&System.Text.RegularExpressions.Regex.IsMatch(value.Substring(prefix.Length),@"^[A-Za-z0-9_.-]+$");
  }
  internal static bool Accepts(int error,PackageIdentity package) {
   if(!AcceptsRegistration(error,package))return false;
   try {
    if(!Path.IsPathRooted(package.InstallPath)||!Path.IsPathRooted(package.ImagePath))return false;
    string root=Path.GetFullPath(package.InstallPath).TrimEnd('\\','/')+Path.DirectorySeparatorChar;
    return Path.GetFullPath(package.ImagePath).StartsWith(root,StringComparison.OrdinalIgnoreCase);
   } catch(ArgumentException) { return false; } catch(NotSupportedException) { return false; } catch(PathTooLongException) { return false; }
  }
  internal static bool AcceptsRegistration(int error,PackageIdentity package) {
   if(error!=0||package==null||package.Family!=OfficialFamily||String.IsNullOrEmpty(package.FullName)
    ||package.Origin!=StoreOrigin||(package.Properties&DevelopmentMode)!=0||String.IsNullOrEmpty(package.InstallPath))return false;
   try { return Path.IsPathRooted(package.InstallPath)&&!String.IsNullOrEmpty(Path.GetFullPath(package.InstallPath)); }
   catch(ArgumentException) { return false; } catch(NotSupportedException) { return false; } catch(PathTooLongException) { return false; }
  }
  internal static bool AcceptsRegistrations(int error,PackageIdentity[] packages) {
   if(error!=0||packages==null||packages.Length==0)return false;
   foreach(PackageIdentity package in packages)if(!AcceptsRegistration(0,package))return false;
   return true;
  }
 }
 internal static class PackageNative {
  internal const uint QueryAndSynchronize=0x00101000,WaitTimeout=258;
  internal const int InsufficientBuffer=122,NoPackage=15700;
  [StructLayout(LayoutKind.Sequential)] internal struct PackageInfoHeader {
   internal uint Reserved,Flags;
   internal IntPtr Path,FullName,Family;
  }
  [DllImport("kernel32.dll",SetLastError=true)] internal static extern SafeProcessHandle OpenProcess(uint access,bool inherit,uint pid);
  [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(SafeProcessHandle process,uint milliseconds);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] internal static extern int GetPackageFamilyName(SafeProcessHandle process,ref uint length,StringBuilder name);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] internal static extern int GetPackageFullName(SafeProcessHandle process,ref uint length,StringBuilder name);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] internal static extern bool QueryFullProcessImageName(SafeProcessHandle process,uint flags,StringBuilder path,ref uint length);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] internal static extern int OpenPackageInfoByFullName(string fullName,uint reserved,out IntPtr reference);
  [DllImport("kernel32.dll")] internal static extern int GetPackageInfo(IntPtr reference,uint flags,ref uint length,IntPtr buffer,out uint count);
  [DllImport("kernel32.dll")] internal static extern int ClosePackageInfo(IntPtr reference);
  [DllImport("kernelbase.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] internal static extern int GetStagedPackageOrigin(string fullName,out uint origin);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)] internal static extern int FindPackagesByPackageFamily(string family,uint filters,ref uint count,IntPtr names,ref uint length,IntPtr buffer,IntPtr properties);
 }
 internal static class WindowsPackageReader {
  private static int ReadName(SafeProcessHandle process,bool family,out string value) {
   value=null;uint length=0;
   int error=family?PackageNative.GetPackageFamilyName(process,ref length,null):PackageNative.GetPackageFullName(process,ref length,null);
   if(error!=PackageNative.InsufficientBuffer)return error==0?13:error;
   if(length<2||length>512)return 13;
   StringBuilder name=new StringBuilder((int)length);
   error=family?PackageNative.GetPackageFamilyName(process,ref length,name):PackageNative.GetPackageFullName(process,ref length,name);
   if(error==0)value=name.ToString();
   return error;
  }
  // All identity and installation data comes from Windows, never from a process's AUMID or manifest text.
  // https://learn.microsoft.com/windows/win32/api/appmodel/nf-appmodel-getpackagefamilyname
  // https://learn.microsoft.com/windows/win32/api/appmodel/nf-appmodel-getstagedpackageorigin
  // https://learn.microsoft.com/windows/win32/appxpkg/package-constants
  internal static int Read(SafeProcessHandle process,out PackageIdentity identity) {
   identity=null;
   try {
    if(process==null||process.IsInvalid||process.IsClosed)return 6;
    string family,fullName;
    int error=ReadName(process,true,out family);if(error!=0)return error;
    error=ReadName(process,false,out fullName);if(error!=0)return error;
    PackageIdentity registration;
    error=ReadRegistration(fullName,out registration);if(error!=0)return error;
    if(registration.Family!=family||registration.FullName!=fullName)return 13;
    StringBuilder image=new StringBuilder(32768);uint imageLength=(uint)image.Capacity;
    if(!PackageNative.QueryFullProcessImageName(process,0,image,ref imageLength))return Marshal.GetLastWin32Error()==0?13:Marshal.GetLastWin32Error();
    identity=new PackageIdentity(family,fullName,registration.InstallPath,image.ToString(),registration.Origin,registration.Properties);
    return 0;
   } catch(Win32Exception e) { return e.NativeErrorCode==0?13:e.NativeErrorCode; }
   catch(EntryPointNotFoundException) { return 120; } catch(DllNotFoundException) { return 126; }
   catch(ArgumentException) { return 13; } catch(ObjectDisposedException) { return 6; }
  }
  internal static int ReadRegistration(string fullName,out PackageIdentity identity) {
   identity=null;IntPtr reference=IntPtr.Zero,buffer=IntPtr.Zero;
   try {
    uint origin;int error=PackageNative.GetStagedPackageOrigin(fullName,out origin);if(error!=0)return error;
    error=PackageNative.OpenPackageInfoByFullName(fullName,0,out reference);if(error!=0)return error;
    uint length=0,count;
    const uint head=0x00000010;
    error=PackageNative.GetPackageInfo(reference,head,ref length,IntPtr.Zero,out count);
    if(error!=PackageNative.InsufficientBuffer)return error==0?13:error;
    if(length<Marshal.SizeOf(typeof(PackageNative.PackageInfoHeader))||length>1024*1024)return 13;
    buffer=Marshal.AllocHGlobal((int)length);
    error=PackageNative.GetPackageInfo(reference,head,ref length,buffer,out count);
    if(error!=0||count!=1)return error==0?13:error;
    // Only the fixed PACKAGE_INFO prefix is needed; its trailing PACKAGE_ID is not marshalled.
    PackageNative.PackageInfoHeader package=(PackageNative.PackageInfoHeader)Marshal.PtrToStructure(buffer,typeof(PackageNative.PackageInfoHeader));
    if(Marshal.PtrToStringUni(package.FullName)!=fullName)return 13;
    identity=new PackageIdentity(Marshal.PtrToStringUni(package.Family),fullName,Marshal.PtrToStringUni(package.Path),null,origin,package.Flags);
    return 0;
   } catch(Win32Exception e) { return e.NativeErrorCode==0?13:e.NativeErrorCode; }
   catch(EntryPointNotFoundException) { return 120; } catch(DllNotFoundException) { return 126; }
   catch(ArgumentException) { return 13; } catch(ObjectDisposedException) { return 6; }
   finally {
    if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);
    if(reference!=IntPtr.Zero)PackageNative.ClosePackageInfo(reference);
   }
  }
  internal static int ReadRegisteredHeads(out PackageIdentity[] packages) {
   packages=null;IntPtr names=IntPtr.Zero,buffer=IntPtr.Zero;
   try {
    uint count=0,length=0;const uint head=0x00000010;
    int error=PackageNative.FindPackagesByPackageFamily(PackageTrust.OfficialFamily,head,ref count,IntPtr.Zero,ref length,IntPtr.Zero,IntPtr.Zero);
    if(error!=PackageNative.InsufficientBuffer)return error==0?PackageNative.NoPackage:error;
    if(count==0||count>128||length<2||length>65536)return 13;
    uint capacity=count;
    names=Marshal.AllocHGlobal(checked((int)count*IntPtr.Size));buffer=Marshal.AllocHGlobal(checked((int)length*2));
    error=PackageNative.FindPackagesByPackageFamily(PackageTrust.OfficialFamily,head,ref count,names,ref length,buffer,IntPtr.Zero);
    if(error!=0||count==0||count>capacity)return error==0?13:error;
    List<PackageIdentity> result=new List<PackageIdentity>();
    for(int index=0;index<count;index++) {
     string fullName=Marshal.PtrToStringUni(Marshal.ReadIntPtr(names,index*IntPtr.Size));
     PackageIdentity package;error=ReadRegistration(fullName,out package);if(error!=0)return error;
     result.Add(package);
    }
    packages=result.ToArray();return 0;
   } catch(Win32Exception e) { return e.NativeErrorCode==0?13:e.NativeErrorCode; }
   catch(EntryPointNotFoundException) { return 120; } catch(DllNotFoundException) { return 126; }
   catch(ArgumentException) { return 13; }
   finally { if(names!=IntPtr.Zero)Marshal.FreeHGlobal(names);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer); }
  }
 }
 internal static class WindowBindingPolicy {
  internal static bool Matches(IntPtr expectedWindow,uint expectedPid,uint expectedThread,IntPtr window,uint pid,uint thread,bool alive) {
   return alive&&expectedWindow!=IntPtr.Zero&&window==expectedWindow&&pid==expectedPid&&thread==expectedThread&&pid!=0&&thread!=0;
  }
 }
 internal sealed class ProcessWindowBinding:IDisposable {
  internal readonly IntPtr Window;
  internal readonly uint Pid,Thread;
  internal readonly SafeProcessHandle Process;
  private ProcessWindowBinding(IntPtr window,uint pid,uint thread,SafeProcessHandle process) {
   Window=window;Pid=pid;Thread=thread;Process=process;
  }
  internal static ProcessWindowBinding Open(IntPtr window) {
   uint pid;uint thread=Native.GetWindowThreadProcessId(window,out pid);
   if(window==IntPtr.Zero||thread==0||pid==0||!Native.IsWindow(window))return null;
   SafeProcessHandle process=PackageNative.OpenProcess(PackageNative.QueryAndSynchronize,false,pid);
   if(process==null||process.IsInvalid) { if(process!=null)process.Dispose();return null; }
   ProcessWindowBinding binding=new ProcessWindowBinding(window,pid,thread,process);
   if(!binding.IsCurrent(window)) { binding.Dispose();return null; }
   return binding;
  }
  internal bool IsCurrent(IntPtr window) {
   if(Process.IsClosed||Process.IsInvalid||PackageNative.WaitForSingleObject(Process,0)!=PackageNative.WaitTimeout||!Native.IsWindow(window))return false;
   uint pid;uint thread=Native.GetWindowThreadProcessId(window,out pid);
   return WindowBindingPolicy.Matches(Window,Pid,Thread,window,pid,thread,true);
  }
  public void Dispose() { Process.Dispose(); }
 }
 internal sealed class TrustedAppWindow:IDisposable {
  private readonly ProcessWindowBinding binding;
  internal IntPtr Handle { get { return binding.Window; } }
  internal bool IsCurrent { get { return binding.IsCurrent(binding.Window); } }
  private TrustedAppWindow(ProcessWindowBinding value) { binding=value; }
  internal static TrustedAppWindow Open(IntPtr window,Config config) {
   ProcessWindowBinding binding=ProcessWindowBinding.Open(window);
   if(binding==null)return null;
   try {
    PackageIdentity identity;
    int error=WindowsPackageReader.Read(binding.Process,out identity);
    if(!PackageTrust.Accepts(error,identity)||!binding.IsCurrent(window)||
     identity.ImagePath.IndexOf(config.ProcessPathContains,StringComparison.OrdinalIgnoreCase)<0)return null;
    TrustedAppWindow trusted=new TrustedAppWindow(binding);binding=null;return trusted;
   } finally { if(binding!=null)binding.Dispose(); }
  }
  public void Dispose() { binding.Dispose(); }
 }
}
