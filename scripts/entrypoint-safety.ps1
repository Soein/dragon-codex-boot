$script:entrypointUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
if (!('DragonCodexBoot.EntrypointNativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace DragonCodexBoot {
 public static class EntrypointNativePath {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
  public static string Resolve(string path) {
   // Resolve the actual object before trusting lexical path boundaries.
   // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
   using(SafeFileHandle handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
    if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
    StringBuilder result=new StringBuilder(32768);
    uint length=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,0);
    if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error());
    if(length>=result.Capacity)throw new InvalidOperationException("Entrypoint path is too long.");
    string full=result.ToString();
    if(!full.StartsWith(@"\\?\",StringComparison.Ordinal))throw new InvalidOperationException("Unsupported entrypoint device path.");
    return full.Substring(4);
   }
  }
 }
}
'@
}
$script:entrypointTrustedSids=@($entrypointUserSid.Value,'S-1-5-18','S-1-5-32-544',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') # TrustedInstaller
$script:entrypointSharedRoots=@(
    foreach ($folder in @('CommonDesktopDirectory','CommonStartMenu','CommonPrograms','CommonApplicationData',
        'CommonDocuments','CommonMusic','CommonPictures','CommonVideos','Windows','ProgramFiles','ProgramFilesX86')) {
        $path=[Environment]::GetFolderPath($folder)
        if ($path) { $path }
    }
    $publicDesktop=[Environment]::GetFolderPath('CommonDesktopDirectory')
    if ($publicDesktop) { [IO.Path]::GetDirectoryName($publicDesktop) }
)
function Get-EntrypointPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) {
        throw 'Entrypoint paths must be local, fully qualified drive paths without alternate data streams.'
    }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full=$full.TrimEnd('\','/') }
    foreach ($part in $full.Substring(3).Split([char[]]@('\','/'))) {
        if ($part -ne $part.TrimEnd(' ','.')) { throw 'Entrypoint paths cannot contain trailing-dot or trailing-space aliases.' }
    }
    return $full
}
function Test-EntrypointWithin([string]$Path,[string]$Root) {
    [string]::Equals($Path,$Root,[StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\','/')+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-EntrypointPath([string]$Path,[switch]$AllowMissing,[switch]$Directory) {
    $full=Get-EntrypointPath $Path
    foreach ($shared in $script:entrypointSharedRoots) {
        $shared=Get-EntrypointPath $shared
        if ((Test-EntrypointWithin $full $shared) -or (Test-EntrypointWithin $shared $full)) {
            throw ('Shared or system entrypoint locations are unsupported: '+$full+'. Use a private directory owned by the current Windows account.')
        }
    }
    $exists=Test-Path -LiteralPath $full
    if (!$exists -and !$AllowMissing) { throw ('Entrypoint path does not exist: '+$full) }
    if ($exists -and $Directory -and !(Test-Path -LiteralPath $full -PathType Container)) { throw ('Directory required: '+$full) }
    $current=$full
    $leaf=$true
    while ($current) {
        $attributes=$null
        try { $attributes=[IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] {}
        catch [IO.DirectoryNotFoundException] {}
        if ($null -ne $attributes) {
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Reparse points are unsupported in entrypoint paths: '+$current)
            }
            if ($leaf) {
                $resolved=Get-EntrypointPath ([DragonCodexBoot.EntrypointNativePath]::Resolve($current))
                if (![string]::Equals($resolved,$current,[StringComparison]::OrdinalIgnoreCase)) {
                    throw ('Entrypoint path aliases are unsupported: '+$current+'. Use its real local path: '+$resolved)
                }
            }
            $acl=Get-Acl -LiteralPath $current
            $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if (($leaf -and $owner -ne $script:entrypointUserSid.Value) -or (!$leaf -and $script:entrypointTrustedSids -notcontains $owner)) {
                throw ('Entrypoint path ownership is not private to the current Windows account: '+$current+'. Extract into a directory owned by this account; do not run another user''s installation.')
            }
            $descriptor=New-Object Security.AccessControl.RawSecurityDescriptor($acl.Sddl)
            if ($null -eq $descriptor.DiscretionaryAcl) { throw ('Unrestricted access control is unsupported: '+$current) }
            # Creating a sibling on an ancestor does not grant replacement of this path.
            # Deleting its children, changing its ACL or replacing the ancestor does.
            $rights=[Security.AccessControl.FileSystemRights]'Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership,WriteAttributes,WriteExtendedAttributes'
            if ($leaf) { $rights=$rights -bor [Security.AccessControl.FileSystemRights]::Write }
            foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                    ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                if (($rule.FileSystemRights -band $rights) -ne 0 -and $script:entrypointTrustedSids -notcontains $rule.IdentityReference.Value) {
                    throw ('Another account can modify this entrypoint path: '+$current+'. Use a private directory without shared write permissions.')
                }
            }
            $leaf=$false
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if (!$parent -or $parent -eq $current) { break }
        $current=$parent
    }
}
function Assert-EntrypointLink([string]$Path,[switch]$AllowMissing) {
    if ([IO.Path]::GetExtension($Path) -ine '.lnk') { throw 'Only .lnk entrypoint paths are supported.' }
    Assert-EntrypointPath $Path -AllowMissing:$AllowMissing
    if ((Test-Path -LiteralPath $Path) -and !(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Shortcut path must be a file.' }
}
function Assert-EntrypointBackup([string]$Path,[string]$Root) {
    $full=Get-EntrypointPath $Path
    if (![string]::Equals([IO.Path]::GetDirectoryName($full),(Get-EntrypointPath $Root),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup must be a direct child of this installation''s backup directory.'
    }
    Assert-EntrypointLink $full
}
function Set-EntrypointGeneratedOwner([string]$Path) {
    # Call only for an object just created in an already validated private directory.
    # Elevated tokens can otherwise assign Administrators as the default owner.
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetOwner($script:entrypointUserSid)
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-EntrypointPath $Path
}
function New-EntrypointDirectory([string]$Path) {
    Assert-EntrypointPath $Path -AllowMissing -Directory
    if (!(Test-Path -LiteralPath $Path)) {
        $parent=[IO.Path]::GetDirectoryName((Get-EntrypointPath $Path))
        if (!(Test-Path -LiteralPath $parent)) { New-EntrypointDirectory $parent }
        $null=New-Item -ItemType Directory -Path $Path
        Set-EntrypointGeneratedOwner $Path
    }
}
function Get-EntrypointDefaultRoots {
    foreach ($folder in @('DesktopDirectory','Programs')) {
        $path=[Environment]::GetFolderPath($folder)
        if ($path) { $path }
    }
    $appData=[Environment]::GetFolderPath('ApplicationData')
    if ($appData) { Join-Path $appData 'Microsoft/Internet Explorer/Quick Launch' }
}
