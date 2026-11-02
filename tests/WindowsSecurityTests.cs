using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using DragonCodexBoot;
using Microsoft.Win32.SafeHandles;

internal static class WindowsSecurityTests {
 private static int checks;
 private static void Check(bool value,string message) { if(!value)throw new Exception(message);checks++; }
 private static void RejectMedia(Action operation,string message) {
  bool rejected=false;try { operation(); } catch(ArgumentException) { rejected=true; }
  Check(rejected,message);
 }
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string value);
 [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
 [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] private static extern SafeFileHandle OpenFixtureDirectory(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] private static extern bool DeviceIoControl(SafeFileHandle file,uint code,byte[] input,uint size,IntPtr output,uint outputSize,out uint returned,IntPtr overlapped);
 private static int SetLocalJunction(string directory,string target) {
  string substitute=@"\??\"+target;
  byte[] paths=System.Text.Encoding.Unicode.GetBytes(substitute+"\0"+target+"\0");
  byte[] buffer=new byte[16+paths.Length];
  Array.Copy(BitConverter.GetBytes(0xA0000003u),0,buffer,0,4);
  Array.Copy(BitConverter.GetBytes((ushort)(8+paths.Length)),0,buffer,4,2);
  Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length*2)),0,buffer,10,2);
  Array.Copy(BitConverter.GetBytes((ushort)((substitute.Length+1)*2)),0,buffer,12,2);
  Array.Copy(BitConverter.GetBytes((ushort)(target.Length*2)),0,buffer,14,2);
  Array.Copy(paths,0,buffer,16,paths.Length);
  using(SafeFileHandle handle=OpenFixtureDirectory(directory,0x40000000,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
   if(handle.IsInvalid)return Marshal.GetLastWin32Error();
   uint returned;return DeviceIoControl(handle,0x000900A4,buffer,(uint)buffer.Length,IntPtr.Zero,0,out returned,IntPtr.Zero)?0:Marshal.GetLastWin32Error();
  }
 }
 private static void Wait(Func<bool> condition,string message) {
  Stopwatch clock=Stopwatch.StartNew();
  while(!condition()) { if(clock.Elapsed.TotalSeconds>20)throw new Exception(message);Thread.Sleep(30); }
 }
 private static PackageIdentity Package(string family,uint origin,uint flags,string install,string image) {
  return new PackageIdentity(family,"policy-only-full-name",install,image,origin,flags);
 }
 private static void PolicyChecks(string fixture) {
  string install=Path.Combine(fixture,"signed-package");string image=Path.Combine(install,"app","Codex.exe");
  PackageIdentity official=Package(PackageTrust.OfficialFamily,PackageTrust.StoreOrigin,0,install,image);
  Check(PackageTrust.Accepts(0,official),"The pure policy accepts its supported Store identity.");
  Check(!PackageTrust.Accepts(5,official)&&!PackageTrust.Accepts(0,null),"API failure or missing identity must fail closed.");
  foreach(string family in new string[] {"Other.App_2p2nqsd0c76g0","OpenAI.Codex_otherpublisher","OpenAI.Codex_fake_2p2nqsd0c76g0"})
   Check(!PackageTrust.Accepts(0,Package(family,3,0,install,image)),"Another package family or publisher must be rejected.");
  foreach(uint origin in new uint[] {0,1,2,4,5,6,7})
   Check(!PackageTrust.Accepts(0,Package(PackageTrust.OfficialFamily,origin,0,install,image)),"A non-Store package source must be rejected.");
  PackageIdentity development=Package(PackageTrust.OfficialFamily,3,PackageTrust.DevelopmentMode,install,image);
  Check(!PackageTrust.Accepts(0,development),"A loose development registration cannot borrow a Store identity.");
  Check(!PackageTrust.Accepts(0,Package(PackageTrust.OfficialFamily,3,0,install,Path.Combine(install+"_fake","Codex.exe"))),"Package path prefixes must respect directory boundaries.");
  Check(!PackageTrust.Accepts(0,Package(PackageTrust.OfficialFamily,3,0,install,Path.Combine(install,"..","Codex.exe"))),"An external or sparse-package executable must not be accepted.");
  Check(!PackageTrust.AcceptsRegistrations(0,new PackageIdentity[0])&&!PackageTrust.AcceptsRegistrations(5,new PackageIdentity[] {official}),"Missing registrations and enumeration failure must reject activation.");
  Check(PackageTrust.AcceptsRegistrations(0,new PackageIdentity[] {official,official}),"Multiple supported Store versions do not widen the policy.");
  Check(!PackageTrust.AcceptsRegistrations(0,new PackageIdentity[] {official,development}),"One trusted old package cannot authorize a loose activation target.");
  Check(!PackageTrust.AcceptsRegistrations(0,new PackageIdentity[] {Package("Other.App_other",3,0,install,image)}),"Another registered family cannot authorize activation.");
  Check(PackageTrust.IsOfficialLaunch("shell:AppsFolder\\"+PackageTrust.OfficialFamily+"!App"),"Supported launch identity.");
  Check(!PackageTrust.IsOfficialLaunch("shell:AppsFolder\\Other.App_other!App")&&!PackageTrust.IsOfficialLaunch("shell:AppsFolder\\"+PackageTrust.OfficialFamily+"!App extra"),"Configuration cannot expand package trust or shell arguments.");
  IntPtr window=new IntPtr(123);
  Check(WindowBindingPolicy.Matches(window,10,20,window,10,20,true),"Stable process-window binding.");
  Check(!WindowBindingPolicy.Matches(window,10,20,window,11,20,true),"PID changes must invalidate a cached window.");
  Check(!WindowBindingPolicy.Matches(window,10,20,window,10,21,true),"Window thread changes must invalidate the binding.");
  Check(!WindowBindingPolicy.Matches(window,10,20,new IntPtr(124),10,20,true),"A different HWND must not reuse a binding.");
  Check(!WindowBindingPolicy.Matches(window,10,20,window,10,20,false),"An exited process must invalidate its window.");
 }
 private static int FakeWindow(string signal) {
  if(SetCurrentProcessExplicitAppUserModelID(PackageTrust.OfficialFamily+"!App")<0)return 2;
  using(Form first=new Form())using(Form second=new Form())using(ApplicationContext context=new ApplicationContext()) {
   first.ClientSize=new System.Drawing.Size(640,400);first.Text="Isolated security fixture";
   first.Show();IntPtr other=second.Handle;
   File.WriteAllText(signal+".tmp",first.Handle.ToInt64()+"|"+other.ToInt64());File.Move(signal+".tmp",signal);
   Application.Run(context);
  }
  return 0;
 }
 private static void ProcessChecks(string fixture,string executable,string otherPackage,out bool metadataChecked) {
  metadataChecked=false;
  PackageIdentity identity;
  int missing=WindowsPackageReader.ReadRegistration("DragonCodexBoot.SecurityFixture_1.0.0.0_x64__0000000000000",out identity);
  Check(missing!=0&&missing!=120&&missing!=126&&identity==null,"A real missing-package query must fail through Windows, not an unavailable API fallback.");
  IntPtr reference;
  int opened=PackageNative.OpenPackageInfoByFullName("DragonCodexBoot.SecurityFixture_1.0.0.0_x64__0000000000000",0,out reference);
  if(reference!=IntPtr.Zero)PackageNative.ClosePackageInfo(reference);
  Check(opened!=0,"The real package metadata API must reject a missing package.");
  PackageIdentity[] registered;int enumeration=WindowsPackageReader.ReadRegisteredHeads(out registered);
  Check(enumeration!=120&&enumeration!=126,"The registered-package enumeration API must be available.");
  if(enumeration!=0)Check(!PackageTrust.AcceptsRegistrations(enumeration,registered),"A failed real enumeration must not authorize launch.");
  if(!String.IsNullOrEmpty(otherPackage)) {
   int result=WindowsPackageReader.ReadRegistration(otherPackage,out identity);
   Console.WriteLine("METADATA selectedPackage={0}, ReadRegistration.result={1}, identityPresent={2}",otherPackage,result,identity!=null);
   Check(result==0&&identity!=null,"Read a real installed package to exercise metadata P/Invoke and structure layout.");
   Check(identity.Family!=PackageTrust.OfficialFamily&&!PackageTrust.AcceptsRegistration(result,identity),"A real installed unrelated package must remain unauthorized.");
   metadataChecked=true;
  } else Console.WriteLine("SKIP: no unrelated installed package available for metadata success interoperability.");
  string fakeDir=Path.Combine(fixture,"OpenAI.Codex_fake");Directory.CreateDirectory(fakeDir);
  string fake=Path.Combine(fakeDir,"Codex.exe");File.Copy(executable,fake);
  File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"DragonCodexBoot.exe"),Path.Combine(fakeDir,"DragonCodexBoot.exe"));
  string signal=Path.Combine(fakeDir,"windows.txt");
  using(Process process=Process.Start(new ProcessStartInfo(fake,"--fake-window \""+signal+"\"") {UseShellExecute=false,WorkingDirectory=fakeDir})) {
   try {
    Wait(delegate { return File.Exists(signal)||process.HasExited; },"Isolated process did not create its test windows.");
    Check(!process.HasExited&&File.Exists(signal),"Fake process started successfully.");
    string[] handles=File.ReadAllText(signal).Split('|');
    IntPtr first=new IntPtr(Int64.Parse(handles[0])),second=new IntPtr(Int64.Parse(handles[1]));
    using(ProcessWindowBinding binding=ProcessWindowBinding.Open(first)) {
     Check(binding!=null&&binding.IsCurrent(first),"Bind an actual live process and HWND.");
     uint length=0;
     Check(PackageNative.GetPackageFamilyName(binding.Process,ref length,null)==PackageNative.NoPackage,"A real unpackaged process must return APPMODEL_ERROR_NO_PACKAGE despite its claimed AUMID.");
     Check(WindowsPackageReader.Read(binding.Process,out identity)==PackageNative.NoPackage&&!PackageTrust.Accepts(PackageNative.NoPackage,identity),"The production reader must reject the fake process identity.");
     Config cfg=new Config {ProcessNames=new string[] {"Codex"},ProcessPathContains="OpenAI.Codex_fake"};
     Check(process.ProcessName=="Codex"&&process.MainModule.FileName.IndexOf(cfg.ProcessPathContains,StringComparison.OrdinalIgnoreCase)>=0,"The fake matches both vulnerable legacy process filters.");
     Bounds before=Native.ClientBounds(first);
     Check(before.Width>=450&&before.Height>=280&&Native.IsWindowVisible(first),"The fake has an eligible actual visible main window.");
     Check(Native.GetWindow(first,4)==IntPtr.Zero&&(Native.GetWindowLong(first,-20)&0x80)==0,"The fake must pass the legacy owner and tool-window exclusions.");
     int cloaked;
     Check(Native.DwmGetWindowAttribute(first,14,out cloaked,4)!=0||cloaked==0,"The fake must pass the legacy DWM cloaking exclusion.");
     using(TrustedAppWindow trusted=TrustedAppWindow.Open(first,cfg))Check(trusted==null,"A fake process cannot become a trusted window.");
     using(TrustedAppWindow found=Native.FindApp(cfg))Check(found==null,"Discovery must refuse the legacy-name/path forgery.");
     Bounds after=Native.ClientBounds(first);
     Check(before.Left==after.Left&&before.Top==after.Top&&before.Width==after.Width&&before.Height==after.Height,"Rejected discovery must not move or resize the fake window.");
     Check(!binding.IsCurrent(second),"Another actual HWND in the same process must not reuse the binding.");
     PostMessage(first,0x0010,IntPtr.Zero,IntPtr.Zero);
     Wait(delegate { return !Native.IsWindow(first); },"Fixture window did not close.");
     Check(!process.HasExited&&!binding.IsCurrent(first),"Destroyed HWNDs must be rejected while their process remains alive.");
    }
    using(ProcessWindowBinding binding=ProcessWindowBinding.Open(second)) {
     Check(binding!=null&&binding.IsCurrent(second),"Bind a second live test window.");
     process.Kill();process.WaitForExit();
     Check(PackageNative.WaitForSingleObject(binding.Process,0)==0&&!binding.IsCurrent(second),"A retained process handle must detect exit and refuse stale HWND/PID reuse.");
    }
   } finally { if(!process.HasExited) { process.Kill();process.WaitForExit(); } }
  }
 }
 private static void Run(ProcessStartInfo info) {
  info.UseShellExecute=false;info.CreateNoWindow=true;info.RedirectStandardInput=true;
  using(Process process=Process.Start(info)) {
   process.StandardInput.WriteLine();process.StandardInput.Close();
   if(!process.WaitForExit(30000)) { process.Kill();throw new Exception("Harmless system-tool test timed out."); }
   Check(process.ExitCode==0,"System-tool invocation must complete successfully.");
  }
 }
 private static void ToolChecks(string fixture,string executable,string repository) {
  string tools=Path.Combine(fixture,"tools & spaces! (isolated)");Directory.CreateDirectory(tools);Directory.CreateDirectory(Path.Combine(tools,"scripts"));
  foreach(string name in new string[] {"powershell.exe","explorer.exe"})File.Copy(executable,Path.Combine(tools,name));
  File.Copy(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"DragonCodexBoot.exe"),Path.Combine(tools,"DragonCodexBoot.exe"));
  foreach(string name in new string[] {"Restore-Original-Entrypoints.cmd","Rescan-Entrypoints.cmd"})File.Copy(Path.Combine(repository,name),Path.Combine(tools,name));
  File.WriteAllText(Path.Combine(tools,"scripts","integrate-entrypoints.ps1"),"param([string]$Action,[string]$AppRoot)\r\n[IO.File]::WriteAllText((Join-Path $AppRoot ('called-'+$Action+'.txt')),[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)\r\nexit 0\r\n");
  string cwd=Environment.CurrentDirectory,path=Environment.GetEnvironmentVariable("PATH"),windir=Environment.GetEnvironmentVariable("WINDIR"),systemRoot=Environment.GetEnvironmentVariable("SystemRoot");
  string windows=SystemExecutables.DirectoryPath(true),system=SystemExecutables.DirectoryPath(false);
  try {
   Environment.CurrentDirectory=tools;Environment.SetEnvironmentVariable("PATH",tools+";"+path);
   Environment.SetEnvironmentVariable("WINDIR",tools);Environment.SetEnvironmentVariable("SystemRoot",tools);
   ProcessStartInfo explorer=SystemExecutables.ExplorerStartInfo("shell:AppsFolder\\"+PackageTrust.OfficialFamily+"!App");
   Check(explorer.FileName==Path.Combine(windows,"explorer.exe")&&!explorer.UseShellExecute&&explorer.WorkingDirectory==windows,"Explorer must use the API-resolved full path and a system working directory.");
   Check(SystemExecutables.PowerShellPath==Path.Combine(system,"WindowsPowerShell","v1.0","powershell.exe"),"Environment variables, PATH and CWD must not replace the PowerShell binary.");
   Environment.SetEnvironmentVariable("WINDIR",windir);Environment.SetEnvironmentVariable("SystemRoot",systemRoot);
   Run(new ProcessStartInfo(SystemExecutables.PowerShellPath,"-NoProfile -NonInteractive -Command \"exit 0\"") {WorkingDirectory=tools});
   foreach(string command in new string[] {"Restore-Original-Entrypoints.cmd","Rescan-Entrypoints.cmd"})
    Run(new ProcessStartInfo(Path.Combine(system,"cmd.exe"),"/d /v:off /s /c \"\""+Path.Combine(tools,command)+"\"\"") {WorkingDirectory=tools});
   foreach(string action in new string[] {"Restore","Install"}) {
    string marker=Path.Combine(tools,"called-"+action+".txt");
    Check(File.Exists(marker)&&String.Equals(File.ReadAllText(marker),SystemExecutables.PowerShellPath,StringComparison.OrdinalIgnoreCase),"CMD entrypoints must route their correct action through the trusted system PowerShell.");
   }
   Check(!File.Exists(Path.Combine(tools,"hijack-ran.txt")),"No executable planted in CWD or PATH may run.");
  } finally {
   Environment.CurrentDirectory=cwd;Environment.SetEnvironmentVariable("PATH",path);Environment.SetEnvironmentVariable("WINDIR",windir);Environment.SetEnvironmentVariable("SystemRoot",systemRoot);
  }
 }
 private static void MediaChecks(string repository,string fixture) {
  string[] remoteReferences=new string[] {@"\\media.invalid\share\clip.mp4","//media.invalid/share/clip.mp4",@"\\?\UNC\media.invalid\share\clip.mp4",@"\\.\UNC\media.invalid\share\clip.mp4",@"\??\UNC\media.invalid\share\clip.mp4",@"\\?\GLOBALROOT\Device\Mup\media.invalid\share\clip.mp4","file://media.invalid/share/clip.mp4","https://media.invalid/clip.mp4",@"\clip.mp4",@"Z:clip.mp4",@"C:\clip.mp4:stream",@"C:\NUL.mp4",@"C:\trailing.\clip.mp4"};
  foreach(string reference in remoteReferences)RejectMedia(delegate { LocalMediaPath.ValidateReference(reference); },"Remote, namespace, stream and DOS-device video aliases must be rejected lexically.");
  Check(LocalMediaPath.ResolveReference(@"C:\base",@"Z:\SHORT~1\clip.mp4")==@"Z:\SHORT~1\clip.mp4","Path normalization must be purely lexical before a mapped drive is classified.");
  RejectMedia(delegate { LocalMediaPath.ResolveReference("relative-base","clip.mp4"); },"An invalid base directory must not recurse or probe a drive.");
  foreach(string device in new string[] {@"\Device\Mup\media.invalid\share",@"\Device\LanmanRedirector\;Z:0000\media.invalid\share",@"\Device\WebDavRedirector\media.invalid",@"\??\UNC\media.invalid\share",@"\??\C:\local-subst"})
   Check(!LocalMediaPath.IsLocalDevice(device),"Network mappings and DOS aliases must be rejected without opening the mapped path.");
  Check(LocalMediaPath.IsLocalDevice(@"\Device\HarddiskVolume123")&&LocalMediaPath.IsLocalDevice(@"\Device\CdRom0"),"Physical local media devices remain supported.");
  foreach(uint attributes in new uint[] {0x400,0x1000,0x40000,0x400000})Check(!LocalMediaPath.SafeAttributes(attributes),"Reparse, offline and recall attributes must be rejected before media data access.");
  string mediaRoot=Path.Combine(fixture,"media-paths");Directory.CreateDirectory(mediaRoot);
  string junctionTarget=Path.Combine(fixture,"junction-local-target");Directory.CreateDirectory(junctionTarget);
  string local=Path.Combine(mediaRoot,"literal %2e%2e #\u4f60\u597d.mp4");File.WriteAllBytes(local,new byte[] {1,2,3,4});
  using(LocalMediaFile file=LocalMediaPath.OpenFile(mediaRoot,Path.GetFileName(local))) {
   Check(file.Exists&&String.Equals(file.Path,local,StringComparison.OrdinalIgnoreCase),"A normal local relative video must open.");
   Check(String.Equals(file.MediaUri.LocalPath,local,StringComparison.OrdinalIgnoreCase)&&file.MediaUri.AbsoluteUri.Contains("%252e")&&file.MediaUri.AbsoluteUri.Contains("%23"),"Playback must preserve literal percent/hash filenames instead of decoding path aliases.");
   using(FileStream stream=file.Stream(false))Check(stream.ReadByte()==1,"Read media through the verified file handle.");
   bool locked=false;try { Directory.Move(mediaRoot,mediaRoot+"-moved"); } catch(IOException) { locked=true; }
   Check(locked,"Verified parent directories must remain protected from path replacement while media is in use.");
   locked=false;try { File.Move(local,local+"-moved"); } catch(IOException) { locked=true; }
   Check(locked,"A verified media file needs a real read sharing lease that prevents replacing its path during playback.");
   locked=false;try { File.Delete(local); } catch(IOException) { locked=true; }
   Check(locked,"A verified media file must not be deletable while its read sharing lease is held.");
   Check(SetLocalJunction(mediaRoot,junctionTarget)!=0,"A held media ancestor with a pinned child must not be convertible into a junction.");
  }
  Directory.Move(mediaRoot,mediaRoot+"-moved");Directory.Move(mediaRoot+"-moved",mediaRoot);
  Check(true,"Disposing media validation must release its directory handles.");
  File.Move(local,local+"-moved");File.Move(local+"-moved",local);Check(true,"Disposing media validation must release the leaf rename protection.");
  File.Delete(local);Check(!File.Exists(local),"Disposing media validation must release the leaf deletion protection.");File.WriteAllBytes(local,new byte[] {1,2,3,4});
  using(LocalMediaFile file=LocalMediaPath.OpenFile(mediaRoot,local))Check(file.Exists,"A normal local absolute video must open.");
  LocalMediaPath.EnsureDirectory(mediaRoot,"created/deep");
  LocalMediaPath.WriteAllText(mediaRoot,"created/deep/local.txt","local native create");
  Check(LocalMediaPath.ReadAllText(mediaRoot,"created/deep/local.txt")=="local native create","Handle-relative directory creation and atomic local writes must remain supported.");
  using(LocalMediaFile folder=LocalMediaPath.OpenDirectory(fixture,mediaRoot)) {
   using(SafeFileHandle child=LocalMediaPath.OpenChildFile(folder.Handle,Path.GetFileName(local)))Check(child!=null&&!child.IsInvalid,"A normal child file must open through its held parent handle.");
   RejectMedia(delegate { using(SafeFileHandle child=LocalMediaPath.OpenChildFile(folder.Handle,@"..\outside.mp4")) {} },"A relative handle open must accept one leaf, never an ancestor path.");
  }
  string mutable=Path.Combine(fixture,"mutable-media-parent");Directory.CreateDirectory(mutable);
  using(LocalMediaFile folder=LocalMediaPath.OpenDirectory(fixture,mutable)) {
   int junction=SetLocalJunction(mutable,mediaRoot);
   Check(junction==0,"The isolated empty-directory fixture must permit a junction change under the directory lease; Win32="+junction);
   RejectMedia(delegate { using(SafeFileHandle child=LocalMediaPath.OpenChildFile(folder.Handle,Path.GetFileName(local))) {} },"An empty parent changed after validation must be rejected before a child is opened; the junction target is only local.");
  }
  RejectMedia(delegate { LocalMediaPath.EnsureDirectory(fixture,"mutable-media-parent/must-not-create"); },"A handle-relative directory create must reject a reparse ancestor.");
  Check(!Directory.Exists(Path.Combine(mediaRoot,"must-not-create")),"A rejected directory create must not modify the local junction target.");
  using(LocalMediaFile file=LocalMediaPath.OpenFile(mediaRoot,"missing/video.mp4"))Check(!file.Exists,"Missing local media remains reportable without contacting a remote path.");
  Config config=new JavaScriptSerializer().Deserialize<Config>(File.ReadAllText(Path.Combine(repository,"config","launcher.example.json")));
  foreach(string reference in remoteReferences) {
   config.Video=reference;
   RejectMedia(delegate { Entry.ValidateConfig(config); },"Upstream configuration validation must reject unsafe video references without opening them.");
  }
  string configPath=Path.Combine(mediaRoot,"launcher.json");config.Video=remoteReferences[0];
  File.WriteAllText(configPath,new JavaScriptSerializer().Serialize(config));
  RejectMedia(delegate { Entry.ReadConfig(mediaRoot); },"Configuration must reject a remote Video before any existence or playback access.");
  string link=Path.Combine(fixture,"media-junction");
  Run(new ProcessStartInfo(Path.Combine(SystemExecutables.DirectoryPath(false),"cmd.exe"),"/d /c mklink /J \""+link+"\" \""+mediaRoot+"\""));
  RejectMedia(delegate { using(LocalMediaFile file=LocalMediaPath.OpenFile(fixture,Path.Combine(link,Path.GetFileName(local)))) {} },"A local reparse fixture must be rejected before traversing it; no remote junction is created for this test.");
  config.Video=Path.Combine(link,Path.GetFileName(local));File.WriteAllText(configPath,new JavaScriptSerializer().Serialize(config));
  RejectMedia(delegate { Entry.ReadConfig(mediaRoot); },"Configuration must reject reparse paths before File.Exists or media decoding.");
  RejectMedia(delegate { Entry.ImportAnimation(remoteReferences[0],mediaRoot,fixture); },"The compiled importer must reject UNC input before inspecting it.");
  RejectMedia(delegate { Entry.ImportAnimation(local,remoteReferences[0],fixture); },"The importer must reject a remote destination before accessing its configuration or media.");
 }
 [STAThread] public static int Main(string[] args) {
  try {
   string executable=Process.GetCurrentProcess().MainModule.FileName;
   string name=Path.GetFileNameWithoutExtension(executable);
   if(name.Equals("powershell",StringComparison.OrdinalIgnoreCase)||name.Equals("explorer",StringComparison.OrdinalIgnoreCase)) {
    File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"hijack-ran.txt"),name);return 73;
   }
   if(args.Length==2&&args[0]=="--fake-window")return FakeWindow(args[1]);
   string repository=args[0],fixture=args[1];Directory.CreateDirectory(fixture);
   PolicyChecks(fixture);bool metadata;
   ProcessChecks(fixture,executable,args.Length>2?args[2]:null,out metadata);
   ToolChecks(fixture,executable,repository);
   MediaChecks(repository,fixture);
   Directory.CreateDirectory(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"qa"));
   File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"qa","windows-security-tests.json"),new JavaScriptSerializer().Serialize(new {
    ok=true,checks=checks,realUnpackagedProcessChecked=true,unrelatedPackageMetadataChecked=metadata,
    officialStoreWindowChecked=false,localMediaPathsChecked=true,remoteMappingsCreated=false,remotePathTestsUseLexicalPolicy=true,scope="Pure trust/path policy, real isolated unpackaged windows and harmless system-tool/local file execution. No Codex activation, media playback or remote mapping is performed."
   }));
   Console.WriteLine("PASS: "+checks+" Windows identity and system-tool assertions; official Store window positive case remains untested.");return 0;
  } catch(Exception e) { Console.Error.WriteLine(e);return 1; }
 }
}
