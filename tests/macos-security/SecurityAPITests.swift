import AppKit
import Foundation
import Security

@main
private struct SecurityAPITests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { print("PASS: \(message)") }
    }

    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixturePID = pid_t(CommandLine.arguments[2])!
        var staticCode: SecStaticCode?
        check(SecStaticCodeCreateWithPath(fixture as CFURL, [], &staticCode) == errSecSuccess, "fixture has a real Security static code object")
        check(SecStaticCodeCheckValidity(staticCode!, [], nil) == errSecSuccess, "fixture ad-hoc signature is valid without publisher requirements")
        var information: CFDictionary?
        check(SecCodeCopySigningInformation(staticCode!, [], &information) == errSecSuccess, "fixture signing identity is readable")
        check((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String == "com.openai.codex", "fixture uses the official signing identifier")
        rejects("static gate rejects same-ID ad-hoc publisher") { try TrustedApplication.validateApplication(at: fixture) }

        let attributes = [kSecGuestAttributePid as String: NSNumber(value: fixturePID)] as CFDictionary
        var dynamicCode: SecCode?
        check(SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode) == errSecSuccess, "fixture PID resolves to a real dynamic code object")
        check(SecCodeCheckValidity(dynamicCode!, [], nil) == errSecSuccess, "running fixture is valid ad-hoc code before publisher policy")
        rejects("dynamic gate rejects same-ID ad-hoc PID") { try TrustedApplication.validateProcess(fixturePID) }
        rejects("PID zero cannot select the root of trust") { try TrustedApplication.validateProcess(0) }
        rejects("negative PID is rejected") { try TrustedApplication.validateProcess(-1) }
        rejects("unrelated Apple-signed application is rejected") {
            try TrustedApplication.validateApplication(at: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        }
        rejects("configuration cannot select another product") { _ = try TrustedApplication.validateBundleIdentifier("com.apple.TextEdit") }
        check(try TrustedApplication.validateBundleIdentifier("") == "com.openai.codex", "empty identity preserves official Codex")

        if let path = ProcessInfo.processInfo.environment["DRAGON_CODEX_SECURITY_OFFICIAL_APP"] {
            try TrustedApplication.validateApplication(at: URL(fileURLWithPath: path))
            print("PASS: official Codex bundle is accepted")
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            check(!applications.isEmpty, "an existing official Codex PID is available without launching it")
            for application in applications {
                try TrustedApplication.validateProcess(application.processIdentifier)
                print("PASS: official Codex PID \(application.processIdentifier) is accepted")
            }
        } else {
            print("SKIP: official bundle/PID positive cases (set DRAGON_CODEX_SECURITY_OFFICIAL_APP)")
        }
    }
}
