using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace DragonCodexBoot {
 internal sealed class LocalMediaFile:IDisposable {
  private readonly List<SafeFileHandle> handles;
  private readonly SafeFileHandle file;
  private readonly bool createdForWrite;
  internal readonly string Path;
  internal readonly bool Exists;
  internal SafeFileHandle Handle { get { return file; } }
  internal LocalMediaFile(string path,bool exists,List<SafeFileHandle> owned,SafeFileHandle leaf,bool created) {
   Path=path;Exists=exists;handles=owned;file=leaf;createdForWrite=created;
  }
  internal FileStream Stream(bool write) {
   if(!Exists||file==null)throw new FileNotFoundException("Local file missing.",Path);
   if(write&&!createdForWrite)throw new InvalidOperationException("Writes require a new private temporary file.");
   SafeFileHandle data=file;
   if(!createdForWrite) {
    data=LocalMediaPath.ReOpenFile(file,write?0xC0000000:0x80000000,1,LocalMediaPath.NoFollowNoRecall);
    if(data.IsInvalid) { int error=Marshal.GetLastWin32Error();data.Dispose();throw NativeErrors.Create(error,"ReOpenFile(access=GENERIC_READ, share=READ, flags=0x00300000) cannot open the verified local file."); }
    handles.Add(data);
   }
   LocalMediaPath.CheckHandle(data,false);
   FileStream stream=new FileStream(data,write?FileAccess.ReadWrite:FileAccess.Read);
   return stream;
  }
  internal Uri MediaUri { get { return LocalMediaPath.FileUri(Path); } }
  public void Dispose() { for(int index=handles.Count-1;index>=0;index--)handles[index].Dispose();handles.Clear(); }
 }
 internal static class LocalMediaPath {
  internal const uint NoFollowNoRecall=0x00200000|0x00100000;
  private const uint MetadataFlags=NoFollowNoRecall|0x02000000;
  [StructLayout(LayoutKind.Sequential)] private struct FileInformation {
   internal uint Attributes,CreatedLow,CreatedHigh,AccessedLow,AccessedHigh,WrittenLow,WrittenHigh;
   internal uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
  }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct RenameInformation {
   internal uint Replace;
   internal IntPtr Directory;
   internal uint NameLength;
   internal char FirstCharacter;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint QueryDosDevice(string name,StringBuilder target,uint length);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] internal static extern SafeFileHandle ReOpenFile(SafeFileHandle original,uint access,uint share,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInformation information);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern uint GetFileType(SafeFileHandle file);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateDirectory(string path,IntPtr security);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,IntPtr information,uint size);
  private static ArgumentException UnsafePath() { return new ArgumentException("Only local disk paths without network, device, stream or reparse aliases are supported."); }
  internal static void ValidateReference(string reference) { ResolveReference(@"C:\",reference); }
  internal static string ResolveReference(string root,string reference) {
   if(String.IsNullOrWhiteSpace(reference))throw UnsafePath();
   string value=reference.Replace('/','\\');
   if(value.StartsWith("\\",StringComparison.Ordinal))throw UnsafePath();
   bool absolute=value.Length>=3&&Char.IsLetter(value[0])&&value[1]==':'&&value[2]=='\\';
   if(!absolute) {
    if(value.IndexOf(':')>=0||String.IsNullOrWhiteSpace(root)||!Regex.IsMatch(root,@"^[A-Za-z]:[\\/]"))throw UnsafePath();
    string basePath=ResolveReference(null,root);
    value=basePath.TrimEnd('\\')+"\\"+value;
   }
   if(value.Length<3||!((value[0]>='A'&&value[0]<='Z')||(value[0]>='a'&&value[0]<='z'))||value[1]!=':'||value[2]!='\\')throw UnsafePath();
   List<string> parts=new List<string>();
   foreach(string part in value.Substring(3).Split('\\')) {
    if(part.Length==0||part==".")continue;
    if(part=="..") { if(parts.Count>0)parts.RemoveAt(parts.Count-1);continue; }
    if(part.EndsWith(" ",StringComparison.Ordinal)||part.EndsWith(".",StringComparison.Ordinal))throw UnsafePath();
    foreach(char c in part)if(c<32||"<>:\"|?*".IndexOf(c)>=0)throw UnsafePath();
    if(Regex.IsMatch(part,@"^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\..*)?$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant))throw UnsafePath();
    parts.Add(part);
   }
   return Char.ToUpperInvariant(value[0])+@":\"+String.Join("\\",parts.ToArray());
  }
  internal static bool IsLocalDevice(string target) {
   return target!=null&&Regex.IsMatch(target,@"^\\Device\\(HarddiskVolume[0-9]+|CdRom[0-9]+|Floppy[0-9]+)$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant);
  }
  internal static bool SafeAttributes(uint attributes) {
   return (attributes&(0x00000400|0x00001000|0x00040000|0x00400000))==0;
  }
  internal static void CheckHandle(SafeFileHandle file,bool directory) {
   FileInformation information;
   if(!GetFileInformationByHandle(file,out information))throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Cannot inspect the verified file handle.");
   if(GetFileType(file)!=1||!SafeAttributes(information.Attributes)||((information.Attributes&0x10)!=0)!=directory)throw UnsafePath();
  }
  // QueryDosDevice only inspects the local DOS-device namespace. Inspect each component with
  // OPEN_REPARSE_POINT/OPEN_NO_RECALL before accessing any descendant or opening media data.
  // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-querydosdevicew
  // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew
  private static LocalMediaFile Walk(string root,string reference,bool directory,bool create) {
   string path=ResolveReference(root,reference);
   StringBuilder target=new StringBuilder(32768);
   if(QueryDosDevice(path.Substring(0,2),target,(uint)target.Capacity)==0)throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Cannot verify that the drive is local.");
   if(!IsLocalDevice(target.ToString()))throw UnsafePath();
   List<SafeFileHandle> handles=new List<SafeFileHandle>();
   try {
    string[] parts=path.Substring(3).Split(new char[] {'\\'},StringSplitOptions.RemoveEmptyEntries);
    string current=path.Substring(0,3);
    for(int index=0;index<=parts.Length;index++) {
     if(index>0)current=current.TrimEnd('\\')+"\\"+parts[index-1];
     bool leaf=index==parts.Length,asDirectory=!leaf||directory;
     SafeFileHandle node=CreateFile(current,asDirectory?0xA0u:0x80u,1,IntPtr.Zero,3,MetadataFlags,IntPtr.Zero);
     if(node.IsInvalid) {
      int error=Marshal.GetLastWin32Error();node.Dispose();
      if(error!=2&&error!=3)throw NativeErrors.Create(error,"Cannot inspect the local path: "+current);
      if(create&&asDirectory) {
       if(!CreateDirectory(current,IntPtr.Zero))throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Cannot create the local directory.");
       node=CreateFile(current,0xA0,1,IntPtr.Zero,3,MetadataFlags,IntPtr.Zero);
      } else return new LocalMediaFile(path,false,handles,null,false);
      if(node.IsInvalid) { error=Marshal.GetLastWin32Error();node.Dispose();throw NativeErrors.Create(error,"Cannot open the new local directory."); }
     }
     handles.Add(node);CheckHandle(node,asDirectory);
     if(leaf)return new LocalMediaFile(path,true,handles,node,false);
    }
    throw UnsafePath();
   } catch { for(int index=handles.Count-1;index>=0;index--)handles[index].Dispose();throw; }
  }
  internal static LocalMediaFile OpenFile(string root,string reference) { return Walk(root,reference,false,false); }
  internal static LocalMediaFile OpenDirectory(string root,string reference) { return Walk(root,reference,true,false); }
  internal static void EnsureDirectory(string root,string reference) { using(LocalMediaFile folder=Walk(root,reference,true,true)) {} }
  internal static Uri FileUri(string path) {
   string full=ResolveReference(null,path);
   string[] parts=full.Substring(3).Split('\\');
   for(int index=0;index<parts.Length;index++)parts[index]=Uri.EscapeDataString(parts[index]);
   Uri uri=new Uri("file:///"+full.Substring(0,2)+"/"+String.Join("/",parts),UriKind.Absolute);
   if(!uri.IsFile||uri.IsUnc||!String.Equals(uri.LocalPath,full,StringComparison.OrdinalIgnoreCase))throw UnsafePath();
   return uri;
  }
  internal static string ReadAllText(string root,string reference) {
   using(LocalMediaFile file=OpenFile(root,reference))using(StreamReader reader=new StreamReader(file.Stream(false),Encoding.UTF8,true))return reader.ReadToEnd();
  }
  internal static void WriteAllText(string root,string reference,string text) {
   AtomicWrite(root,reference,delegate(FileStream stream) {
    using(StreamWriter writer=new StreamWriter(stream,new UTF8Encoding(true),1024,true))writer.Write(text);
   });
  }
  internal static void CopyFile(string root,string source,string destination) {
   string from=ResolveReference(root,source),to=ResolveReference(root,destination);
   if(String.Equals(from,to,StringComparison.OrdinalIgnoreCase))return;
   using(LocalMediaFile input=OpenFile(root,from))using(FileStream read=input.Stream(false))AtomicWrite(root,to,delegate(FileStream written) {
    read.CopyTo(written);written.Flush(true);read.Position=written.Position=0;
    using(SHA256 hash=SHA256.Create()) {
     string expected=Convert.ToBase64String(hash.ComputeHash(read));
     if(expected!=Convert.ToBase64String(hash.ComputeHash(written)))throw new IOException("Local copy checksum mismatch.");
    }
   });
  }
  private static void Rename(SafeFileHandle file,SafeFileHandle directory,string name) {
   byte[] text=Encoding.Unicode.GetBytes(name);
   int offset=(int)Marshal.OffsetOf(typeof(RenameInformation),"FirstCharacter"),size=offset+text.Length;
   IntPtr buffer=Marshal.AllocHGlobal(size);bool retained=false;
   try {
    directory.DangerousAddRef(ref retained);
    for(int index=0;index<size;index++)Marshal.WriteByte(buffer,index,0);
    Marshal.WriteInt32(buffer,1);
    Marshal.WriteIntPtr(buffer,(int)Marshal.OffsetOf(typeof(RenameInformation),"Directory"),directory.DangerousGetHandle());
    Marshal.WriteInt32(buffer,(int)Marshal.OffsetOf(typeof(RenameInformation),"NameLength"),text.Length);
    Marshal.Copy(text,0,IntPtr.Add(buffer,offset),text.Length);
    if(!SetFileInformationByHandle(file,3,buffer,(uint)size))throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Atomic local file replacement failed.");
   } finally { if(retained)directory.DangerousRelease();Marshal.FreeHGlobal(buffer); }
  }
  private static void AtomicWrite(string root,string reference,Action<FileStream> write) {
   string path=ResolveReference(root,reference);
   int split=path.LastIndexOf('\\');string parent=path.Substring(0,split+1),name=path.Substring(split+1);
   using(LocalMediaFile folder=OpenDirectory(root,parent)) {
    if(!folder.Exists)throw new DirectoryNotFoundException("Local destination directory missing.");
    using(LocalMediaFile destination=OpenFile(root,path)) {}
    string temporary=ResolveReference(parent,".dragon-media-"+Guid.NewGuid().ToString("N")+".tmp");
    SafeFileHandle handle=CreateFile(temporary,0xC0010000,1,IntPtr.Zero,1,MetadataFlags,IntPtr.Zero);
    if(handle.IsInvalid) { int error=Marshal.GetLastWin32Error();handle.Dispose();throw NativeErrors.Create(error,"Cannot create the local temporary file."); }
    using(LocalMediaFile file=new LocalMediaFile(temporary,true,new List<SafeFileHandle> {handle},handle,true)) {
     bool committed=false;FileStream stream=null;
     try { stream=file.Stream(true);write(stream);stream.Flush(true);Rename(handle,folder.Handle,name);committed=true; }
     finally {
      if(!committed) {
       IntPtr disposition=Marshal.AllocHGlobal(1);
       try { Marshal.WriteByte(disposition,1);SetFileInformationByHandle(handle,4,disposition,1); }
       finally { Marshal.FreeHGlobal(disposition); }
      }
      if(stream!=null)stream.Dispose();
     }
    }
   }
  }
 }
}
