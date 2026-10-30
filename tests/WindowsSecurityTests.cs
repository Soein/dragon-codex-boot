using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using DragonCodexBoot;

internal static class WindowsSecurityTests {
 private static int checks;
 private static void Check(bool value,string message) { if(!value)throw new Exception(message);checks++; }
 [DllImport("shell32.dll",CharSet=CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string value);
 [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
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
   Directory.CreateDirectory(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"qa"));
   File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"qa","windows-security-tests.json"),new JavaScriptSerializer().Serialize(new {
    ok=true,checks=checks,realUnpackagedProcessChecked=true,unrelatedPackageMetadataChecked=metadata,
    officialStoreWindowChecked=false,scope="Pure trust policy, real isolated unpackaged windows and harmless system-tool execution. No Codex activation or media playback."
   }));
   Console.WriteLine("PASS: "+checks+" Windows identity and system-tool assertions; official Store window positive case remains untested.");return 0;
  } catch(Exception e) { Console.Error.WriteLine(e);return 1; }
 }
}
