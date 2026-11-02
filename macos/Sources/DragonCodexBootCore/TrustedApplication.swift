import Darwin
import Darwin.membership
import Foundation
import Security

/// Trust is pinned to the official Codex Developer ID, independently of discovery or AppPath.
public enum TrustedApplication {
    public static let bundleIdentifier = "com.openai.codex"

    // Developer ID requirement syntax: Apple TN3127. The team is pinned, never read from a candidate.
    private static let signingRequirement: Result<SecRequirement, Error> = Result {
        let expression = #"identifier "com.openai.codex" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "2DC432GLL2""#
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw validationError("无法创建 Codex 签名策略", status: status)
        }
        return requirement
    }

    /// An empty configured identity uses Codex; a path cannot opt into another publisher or product.
    public static func validateBundleIdentifier(_ configuredIdentifier: String) throws -> String {
        let identifier = configuredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty || identifier == bundleIdentifier else {
            throw TrustedApplicationError("只允许官方 Codex（\(bundleIdentifier)），不能通过 AppBundleIdentifier 更改可信应用身份。")
        }
        return bundleIdentifier
    }

    /// Returns the physical URL to pass to Launch Services. Never reopen the discovery URL after validation.
    public static func validatedLaunchURL(at url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw TrustedApplicationError("目标应用必须位于本机。")
        }
        let applicationURL = try LocalPathSecurity.physicalURL(url)
        guard Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier else {
            throw TrustedApplicationError("目标应用身份不是官方 Codex：\(url.path)")
        }
        try LocalPathSecurity.validateBundleTree(at: applicationURL)
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw validationError("无法读取目标应用签名：\(url.path)", status: status)
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let validity = SecStaticCodeCheckValidity(code, flags, try signingRequirement.get())
        guard validity == errSecSuccess else {
            throw validationError("目标应用未通过官方 Codex 签名验证：\(url.path)", status: validity)
        }
        return applicationURL
    }

    /// Checks an application without launching it.
    public static func validateApplication(at url: URL) throws {
        _ = try validatedLaunchURL(at: url)
    }

    /// Checks the actual running code at a reuse, notification or activation boundary; PID alone is not trusted.
    public static func validateProcess(_ processIdentifier: pid_t) throws {
        guard processIdentifier > 0 else {
            throw TrustedApplicationError("目标 Codex 进程无效。")
        }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else {
            throw validationError("无法读取 Codex 进程签名（PID \(processIdentifier)）", status: status)
        }
        let validity = SecCodeCheckValidity(code, [], try signingRequirement.get())
        guard validity == errSecSuccess else {
            throw validationError("目标进程未通过官方 Codex 签名验证（PID \(processIdentifier)）", status: validity)
        }
    }

    private static func validationError(_ message: String, status: OSStatus) -> TrustedApplicationError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Security 错误 \(status)"
        return TrustedApplicationError("\(message)：\(detail)（\(status)）。已停止启动和切换。")
    }
}

/// Validates local paths that may be written only by the current user, root or a system administrator.
public enum LocalPathSecurity {
    private static let privilegedGroups = Set(["admin", "wheel"].compactMap { (name: String) in
        name.withCString { getgrnam($0)?.pointee.gr_gid }
    })
    private static let writePermissions = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        .reduce(acl_permset_mask_t(0)) { $0 | acl_permset_mask_t($1.rawValue) }

    static func physicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw unsafe(url.path) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func unsafe(_ path: String) -> TrustedApplicationError {
        TrustedApplicationError("路径不满足安全要求，请检查所在磁盘、目录所有者和写权限：\(path)")
    }

    private static func checkACL(_ path: String) throws {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return } // Darwin reports ENOENT for an existing node without an ACL.
            throw unsafe(path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var index = ACL_FIRST_ENTRY
        var entry: acl_entry_t?
        while acl_get_entry(acl, Int32(index.rawValue), &entry) == 0, let entry {
            index = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else { throw unsafe(path) }
            if tag == ACL_EXTENDED_DENY || (tag == ACL_EXTENDED_ALLOW && mask & writePermissions == 0) { continue }
            guard tag == ACL_EXTENDED_ALLOW, let qualifier = acl_get_qualifier(entry) else { throw unsafe(path) }
            defer { acl_free(qualifier) }
            var id: uid_t = 0
            var type: Int32 = 0
            guard mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &id, &type) == 0,
                  (type == ID_TYPE_UID && (id == 0 || id == geteuid())) ||
                  (type == ID_TYPE_GID && privilegedGroups.contains(id)) else { throw unsafe(path) }
        }
        guard errno == EINVAL else { throw unsafe(path) } // End of a valid Darwin ACL.
    }

    private static func checkNode(_ path: String, ancestor: Bool = false) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid() else { throw unsafe(path) }
        let type = info.st_mode & S_IFMT
        guard !ancestor || type == S_IFDIR else { throw unsafe(path) }
        // A sticky system temp directory cannot be used to replace a trusted user's existing child.
        let stickyAncestor = ancestor && info.st_uid == 0 && info.st_mode & S_ISVTX != 0
        if type != S_IFLNK && !stickyAncestor {
            guard info.st_mode & S_IWOTH == 0,
                  info.st_mode & S_IWGRP == 0 || privilegedGroups.contains(info.st_gid) else { throw unsafe(path) }
        }
        try checkACL(path)
        return info
    }

    private static func checkedDirectory(at url: URL) throws -> stat {
        var parent = "/"
        for component in url.pathComponents.dropFirst() {
            _ = try checkNode(parent, ancestor: true)
            parent = (parent as NSString).appendingPathComponent(component)
        }
        var volume = statfs()
        guard statfs(url.path, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              volume.f_owner == 0 || volume.f_owner == geteuid(),
              volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { throw unsafe(url.path) }
        let directory = try checkNode(url.path)
        guard directory.st_mode & S_IFMT == S_IFDIR else { throw unsafe(url.path) }
        return directory
    }

    /// Checks permissions without changing them; the caller writes using this same open directory.
    public static func validateUserDirectory(at url: URL, openedAs descriptor: Int32) throws {
        let directory = try checkedDirectory(at: url)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, directory.st_uid == geteuid(),
              directory.st_dev == opened.st_dev, directory.st_ino == opened.st_ino else { throw unsafe(url.path) }
    }

    static func validateBundleTree(at url: URL) throws {
        let root = url.path
        let bundle = try checkedDirectory(at: url)
        // A disk image can be replaced at its mount point even if its mode bits appear safe.
        var dataVolume = stat()
        var systemVolume = stat()
        guard stat("/Applications", &dataVolume) == 0, stat("/", &systemVolume) == 0,
              bundle.st_dev == dataVolume.st_dev || bundle.st_dev == systemVolume.st_dev else { throw unsafe(root) }
        let files = FileManager.default
        var directories = [root]
        while let directory = directories.popLast() {
            for name in try files.contentsOfDirectory(atPath: directory) {
                let path = (directory as NSString).appendingPathComponent(name)
                let node = try checkNode(path)
                guard node.st_dev == bundle.st_dev else { throw unsafe(path) }
                switch node.st_mode & S_IFMT {
                case S_IFDIR: directories.append(path)
                case S_IFREG: break
                case S_IFLNK:
                    // Framework and package-manager links may start with "..". Never follow a link
                    // through an external directory, even if its final destination is back inside.
                    let link = try files.destinationOfSymbolicLink(atPath: path)
                    let parts = link.split(separator: "/").filter { $0 != "." }
                    let climbs = parts.prefix(while: { $0 == ".." }).count
                    let depth = directory.dropFirst(root.count).split(separator: "/").count
                    guard !link.hasPrefix("/"), climbs <= depth, !parts.dropFirst(climbs).contains(".."),
                          try physicalURL(URL(fileURLWithPath: path)).path.hasPrefix(root + "/") else { throw unsafe(path) }
                default: throw unsafe(path)
                }
            }
        }
    }
}

public struct TrustedApplicationError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
