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
        launcher.target = ForbiddenActivation(processIdentifier: pid_t(CommandLine.arguments[1])!)
        launcher.handoff()
        fputs("FAIL: standalone handoff returned without rejecting the untrusted PID\n", stderr)
        exit(3)
    }
}
