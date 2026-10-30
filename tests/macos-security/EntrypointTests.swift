@main
@MainActor
private struct SecurityEntrypointTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { print("PASS: \(message)") }
    }

    static func main() throws {
        var configuration = LauncherConfiguration()
        configuration.appPath = CommandLine.arguments[1]
        rejects("explicit AppPath rejects an ad-hoc app with the official Bundle ID") {
            _ = try BootController.resolveApplication(for: configuration)
        }
        configuration.appBundleIdentifier = ""
        rejects("empty configured identity cannot make AppPath trust an ad-hoc app") {
            _ = try BootController.resolveApplication(for: configuration)
        }
        configuration.appBundleIdentifier = "com.apple.TextEdit"
        configuration.appPath = "/System/Applications/TextEdit.app"
        rejects("AppPath cannot replace the expected product identity") {
            _ = try BootController.resolveApplication(for: configuration)
        }

        guard let officialPath = ProcessInfo.processInfo.environment["DRAGON_CODEX_SECURITY_OFFICIAL_APP"] else {
            print("SKIP: controller and monitor PID cases require the official installed bundle")
            return
        }
        configuration = LauncherConfiguration(video: CommandLine.arguments[1], appPath: officialPath)
        let resolved = try BootController.resolveApplication(for: configuration)
        check(resolved.bundleIdentifier == "com.openai.codex", "official explicit path retains the expected identity")
        let runtime = RuntimeConfiguration(configuration: configuration, root: URL(fileURLWithPath: "/"))
        let application = RunningApplicationSpy(processIdentifier: pid_t(CommandLine.arguments[2])!)
        rejects("controller rejects an untrusted supplied running instance") {
            _ = try BootController(runtime: runtime, targetApplication: application, watchMode: true)
        }
        let controller = try BootController(runtime: runtime, watchMode: true)
        try controller.checkUntrustedActivation(application)
        let monitor = try CodexLaunchMonitor(runtime: runtime)
        monitor.checkUntrustedNotification(application)
    }
}

private extension BootController {
    func checkUntrustedActivation(_ application: RunningApplicationSpy) throws {
        SecurityEntrypointTests.rejects("startup callback/reveal rejects the actual untrusted PID before activation") {
            try revealTargetBehindOverlay(application)
        }
        SecurityEntrypointTests.check(application.activationCount == 0 && application.unhideCount == 0, "reveal rejection has no AppKit side effects")
        targetApplication = application
        handOff()
        SecurityEntrypointTests.check(handedOff, "failed final handoff closes the overlay")
        SecurityEntrypointTests.check(application.activationCount == 0 && application.unhideCount == 0, "final handoff cannot activate or unhide the untrusted PID")
    }
}

private extension CodexLaunchMonitor {
    func checkUntrustedNotification(_ application: RunningApplicationSpy) {
        applicationDidLaunch(application)
        SecurityEntrypointTests.check(pendingApplication == nil && windowPollTimer == nil && activeController == nil, "same-ID untrusted launch notification cannot schedule an overlay")
        stopWaitingForWindow()
    }
}
