private final class ForbiddenActivation: NSRunningApplication, @unchecked Sendable {
    let fixturePID: pid_t
    init(processIdentifier: pid_t) { fixturePID = processIdentifier; super.init() }
    override var processIdentifier: pid_t { fixturePID }
    override var isTerminated: Bool { false }
    override func activate(options: NSApplication.ActivationOptions = []) -> Bool {
        fputs("FAIL: standalone handoff activated an untrusted PID\n", stderr)
        exit(2)
    }
}

@main
private struct StandaloneSecurityTests {
    static func main() {
        let launcher = Launcher()
        if CommandLine.arguments.contains("--launch-rejection") {
            launcher.targetURL = URL(fileURLWithPath: CommandLine.arguments[2])
            launcher.launchTarget()
            fputs("FAIL: standalone launch returned without rejecting an ordinary file\n", stderr)
            exit(3)
        }
        launcher.target = ForbiddenActivation(processIdentifier: pid_t(CommandLine.arguments[1])!)
        launcher.handoff()
        fputs("FAIL: standalone handoff returned without rejecting the untrusted PID\n", stderr)
        exit(3)
    }
}
