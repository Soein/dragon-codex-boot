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

    /// Checks the complete bundle before opening it. Revalidate if its on-disk contents may have changed.
    public static func validateApplication(at url: URL) throws {
        let applicationURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier else {
            throw TrustedApplicationError("目标应用身份不是官方 Codex：\(url.path)")
        }
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

public struct TrustedApplicationError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
