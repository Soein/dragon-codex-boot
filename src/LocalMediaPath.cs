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
  private readonly int originalHandleCount;
  internal readonly string Path;
  internal readonly bool Exists;
  internal SafeFileHandle Handle { get { return file; } }
  internal LocalMediaFile(string path,bool exists,List<SafeFileHandle> owned,SafeFileHandle leaf,bool created) {
   Path=path;Exists=exists;handles=owned;file=leaf;createdForWrite=created;originalHandleCount=owned.Count;
  }
  private void CheckLease() {
   if(!Exists||file==null)throw new FileNotFoundException("Local file missing.",Path);
   for(int index=0;index<originalHandleCount;index++)LocalMediaPath.CheckHandle(handles[index],index<originalHandleCount-1);
  }
  internal FileStream Stream(bool write) {
   CheckLease();
   if(write&&!createdForWrite)throw new InvalidOperationException("Writes require a new private temporary file.");
   SafeFileHandle data=file;
   if(!createdForWrite) {
    // Retain NO_RECALL on the metadata open; passing it to ReOpenFile returns error 87 on Windows.
    LocalMediaPath.CheckHandle(file,false);
    data=LocalMediaPath.ReOpenFile(file,0x80000000,1,0x00200000);
    if(data.IsInvalid) { int error=Marshal.GetLastWin32Error();data.Dispose();throw NativeErrors.Create(error,"ReOpenFile(access=GENERIC_READ, share=READ, flags=0x00200000) cannot open the verified local file."); }
    handles.Add(data);
   }
   LocalMediaPath.CheckHandle(data,false);
   FileStream stream=new FileStream(data,write?FileAccess.ReadWrite:FileAccess.Read);
   return stream;
  }
  internal Uri MediaUri { get { CheckLease();return LocalMediaPath.FileUri(Path); } }
  public void Dispose() { for(int index=handles.Count-1;index>=0;index--)handles[index].Dispose();handles.Clear(); }
 }
 internal static class LocalMediaPath {
  // Native NT options differ from the similarly named Win32 CreateFile flags.
  private const uint NativeNoFollowNoRecall=0x00200000|0x00400000;
  private const uint FileOpen=1,FileCreate=2,FileOpenIf=3;
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
  [StructLayout(LayoutKind.Sequential)] private struct IoStatusBlock {
   internal IntPtr Status;
   internal UIntPtr Information;
  }
  [StructLayout(LayoutKind.Sequential)] private struct UnicodeString {
   internal ushort Length,MaximumLength;
   internal IntPtr Buffer;
  }
  [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes {
   internal uint Length;
   internal IntPtr Directory,Name;
   internal uint Attributes;
   internal IntPtr Security,QualityOfService;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint QueryDosDevice(string name,StringBuilder target,uint length);
  [DllImport("kernel32.dll",SetLastError=true)] internal static extern SafeFileHandle ReOpenFile(SafeFileHandle original,uint access,uint share,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInformation information);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern uint GetFileType(SafeFileHandle file);
  [DllImport("kernel32.dll",SetLastError=true)] private static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,IntPtr information,uint size);
  [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle file,out IoStatusBlock status,IntPtr information,uint size,int kind);
  [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
  [DllImport("ntdll.dll")] private static extern int NtCreateFile(out SafeFileHandle file,uint access,ref ObjectAttributes attributes,out IoStatusBlock io,IntPtr allocation,uint fileAttributes,uint share,uint creation,uint options,IntPtr extendedAttributes,uint extendedLength);
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
  private static void ValidateLeaf(string name) {
   if(String.IsNullOrEmpty(name)||name.IndexOfAny(new char[] {'\\','/',':'})>=0||ResolveReference(@"C:\",name)!=@"C:\"+name)throw UnsafePath();
  }
  private static Exception NativeFailure(int status,string operation) {
   if(unchecked((uint)status)==0xC000050B)return UnsafePath(); // STATUS_REPARSE_POINT_ENCOUNTERED
   return NativeErrors.Create(unchecked((int)RtlNtStatusToDosError(status)),operation+" [NTSTATUS=0x"+unchecked((uint)status).ToString("X8")+"].");
  }
  private static bool Missing(int status) { return status==unchecked((int)0xC0000034)||status==unchecked((int)0xC000003A); }
  // Only the classified physical device root is absolute. Every child open/create is relative
  // to its held parent, so a directory changed into a junction cannot redirect the next open.
  // https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntcreatefile
  // https://learn.microsoft.com/windows/win32/api/ntdef/ns-ntdef-_object_attributes
  private static SafeFileHandle NativeOpen(SafeFileHandle parent,string name,bool directory,uint access,uint share,uint creation,out int status) {
   if(parent!=null) { ValidateLeaf(name);CheckHandle(parent,true); }
   else if(!name.EndsWith("\\",StringComparison.Ordinal)||!IsLocalDevice(name.Substring(0,name.Length-1)))throw UnsafePath();
   if(name.Length>32766)throw UnsafePath();
   IntPtr text=Marshal.StringToHGlobalUni(name),unicode=IntPtr.Zero;
   bool parentReference=false;
   try {
    UnicodeString value=new UnicodeString {Length=(ushort)(name.Length*2),MaximumLength=(ushort)(name.Length*2+2),Buffer=text};
    unicode=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));Marshal.StructureToPtr(value,unicode,false);
    if(parent!=null)parent.DangerousAddRef(ref parentReference);
    ObjectAttributes attributes=new ObjectAttributes {Length=(uint)Marshal.SizeOf(typeof(ObjectAttributes)),Directory=parent==null?IntPtr.Zero:parent.DangerousGetHandle(),Name=unicode,Attributes=0x1040}; // OBJ_DONT_REPARSE | OBJ_CASE_INSENSITIVE
    IoStatusBlock io;SafeFileHandle file;
    uint options=NativeNoFollowNoRecall|0x20u|(directory?1u:0x40u); // synchronous, directory/non-directory
    status=NtCreateFile(out file,access|0x00100000,ref attributes,out io,IntPtr.Zero,directory?0x10u:0x80u,share,creation,options,IntPtr.Zero,0);
    if(status<0) { if(file!=null)file.Dispose();return null; }
    try { CheckHandle(file,directory);if(parent!=null)CheckHandle(parent,true);return file; }
    catch { file.Dispose();throw; }
   } finally { if(parentReference)parent.DangerousRelease();if(unicode!=IntPtr.Zero)Marshal.FreeHGlobal(unicode);Marshal.FreeHGlobal(text); }
  }
  /// <summary>Checks one child's metadata, then pins the same file for reading without following reparses. Returns null when absent; the caller retains the parent lease.</summary>
  internal static SafeFileHandle OpenChildFile(SafeFileHandle directory,string name) {
   if(directory==null)throw UnsafePath();
   int status;
   using(SafeFileHandle metadata=NativeOpen(directory,name,false,0x80,1,FileOpen,out status)) {
    if(metadata==null) { if(Missing(status))return null;throw NativeFailure(status,"Cannot inspect the local child file"); }
    SafeFileHandle file=NativeOpen(directory,name,false,0x81,1,FileOpen,out status); // FILE_READ_DATA | FILE_READ_ATTRIBUTES establishes a real sharing lease.
    if(file==null)throw NativeFailure(status,"Cannot pin the verified local child file");
    try {
     FileInformation before,after;
     if(!GetFileInformationByHandle(metadata,out before)||!GetFileInformationByHandle(file,out after))throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Cannot compare the verified local file identity.");
     if(before.Volume!=after.Volume||before.IndexHigh!=after.IndexHigh||before.IndexLow!=after.IndexLow)throw new IOException("The local child file changed while acquiring its read lease.");
     return file;
    } catch { file.Dispose();throw; }
   }
  }
  private static LocalMediaFile Walk(string root,string reference,bool directory,bool create) {
   string path=ResolveReference(root,reference);
   StringBuilder target=new StringBuilder(32768);
   if(QueryDosDevice(path.Substring(0,2),target,(uint)target.Capacity)==0)throw NativeErrors.Create(Marshal.GetLastWin32Error(),"Cannot verify that the drive is local.");
   if(!IsLocalDevice(target.ToString()))throw UnsafePath();
   List<SafeFileHandle> handles=new List<SafeFileHandle>();
   try {
    string[] parts=path.Substring(3).Split(new char[] {'\\'},StringSplitOptions.RemoveEmptyEntries);
    if(parts.Length==0&&!directory)throw UnsafePath();
    for(int index=0;index<=parts.Length;index++) {
     bool leaf=index==parts.Length;
     SafeFileHandle node;
     if(leaf&&!directory) {
      node=OpenChildFile(handles[index-1],parts[index-1]);
      if(node==null)return new LocalMediaFile(path,false,handles,null,false);
     } else {
      int status;
      node=NativeOpen(index==0?null:handles[index-1],index==0?target.ToString()+"\\":parts[index-1],true,0xA0,3,create&&index>0?FileOpenIf:FileOpen,out status);
      if(node==null) {
       if(!Missing(status))throw NativeFailure(status,"Cannot inspect the local path: "+path);
       return new LocalMediaFile(path,false,handles,null,false);
      }
     }
     handles.Add(node);
     if(leaf) {
      for(int ancestor=0;ancestor<handles.Count;ancestor++)CheckHandle(handles[ancestor],ancestor<handles.Count-1||directory);
      return new LocalMediaFile(path,true,handles,node,false);
     }
    }
    throw UnsafePath();
   } catch { for(int index=handles.Count-1;index>=0;index--)handles[index].Dispose();throw; }
  }
  internal static LocalMediaFile OpenFile(string root,string reference) { return Walk(root,reference,false,false); }
  internal static LocalMediaFile OpenDirectory(string root,string reference) { return Walk(root,reference,true,false); }
  internal static void EnsureDirectory(string root,string reference) { using(LocalMediaFile folder=Walk(root,reference,true,true)) {} }
  internal static SafeFileHandle AcquireImportLock(LocalMediaFile root) {
   if(!root.Exists||root.Handle==null)throw new DirectoryNotFoundException("Local installation directory missing.");
   CheckHandle(root.Handle,true);
   int status;SafeFileHandle handle=NativeOpen(root.Handle,".dragon-media-import.lock",false,0xC0000000,0,FileOpenIf,out status);
   if(handle==null)throw NativeFailure(status,"Another media import is active or the local import lock is unavailable");
   return handle;
  }
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
   ValidateLeaf(name);
   CheckHandle(file,false);CheckHandle(directory,true);
   byte[] text=Encoding.Unicode.GetBytes(name);
   int offset=(int)Marshal.OffsetOf(typeof(RenameInformation),"FirstCharacter");
   int size=Marshal.SizeOf(typeof(RenameInformation))+text.Length+sizeof(char);
   IntPtr buffer=Marshal.AllocHGlobal(size);
   bool directoryReference=false;
   try {
    directory.DangerousAddRef(ref directoryReference);
    for(int index=0;index<size;index++)Marshal.WriteByte(buffer,index,0);
    Marshal.WriteInt32(buffer,1);
    Marshal.WriteIntPtr(buffer,(int)Marshal.OffsetOf(typeof(RenameInformation),"Directory"),directory.DangerousGetHandle());
    Marshal.WriteInt32(buffer,(int)Marshal.OffsetOf(typeof(RenameInformation),"NameLength"),text.Length);
    Marshal.Copy(text,0,IntPtr.Add(buffer,offset),text.Length);
    // Native FileRenameInformation accepts a checked directory handle and one leaf name.
    // The temporary handle was opened synchronously, so this call completes before the buffer is freed.
    // https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
    IoStatusBlock io;
    int status=NtSetInformationFile(file,out io,buffer,(uint)size,10);
    if(status<0)throw NativeErrors.Create(unchecked((int)RtlNtStatusToDosError(status)),"Atomic local file replacement failed (NtSetInformationFile, NTSTATUS=0x"+unchecked((uint)status).ToString("X8")+", nameBytes="+text.Length+", bufferSize="+size+").");
   } finally { Marshal.FreeHGlobal(buffer);if(directoryReference)directory.DangerousRelease(); }
  }
  private static void AtomicWrite(string root,string reference,Action<FileStream> write) {
   string path=ResolveReference(root,reference);
   int split=path.LastIndexOf('\\');string parent=path.Substring(0,split+1);
   using(LocalMediaFile folder=OpenDirectory(root,parent)) {
    if(!folder.Exists)throw new DirectoryNotFoundException("Local destination directory missing.");
    string name=path.Substring(split+1);
    using(SafeFileHandle destination=OpenChildFile(folder.Handle,name)) {}
    string temporaryName=".dragon-media-"+Guid.NewGuid().ToString("N")+".tmp",temporary=ResolveReference(parent,temporaryName);
    int status;SafeFileHandle handle=NativeOpen(folder.Handle,temporaryName,false,0xC0010000,1,FileCreate,out status);
    if(handle==null)throw NativeFailure(status,"Cannot create the local temporary file");
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
