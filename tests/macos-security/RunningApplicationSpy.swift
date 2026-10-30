// Only AppKit's activation side effects are replaced. Signature checks use a real fixture PID.
private final class RunningApplicationSpy: NSRunningApplication, @unchecked Sendable {
    let fixturePID: pid_t
    var activationCount = 0
    var unhideCount = 0

    init(processIdentifier: pid_t) {
        fixturePID = processIdentifier
        super.init()
    }

    override var processIdentifier: pid_t { fixturePID }
    override var bundleIdentifier: String? { "com.openai.codex" }
    override var isTerminated: Bool { false }
    override var isFinishedLaunching: Bool { true }
    override func unhide() -> Bool { unhideCount += 1; return true }
    override func activate(options: NSApplication.ActivationOptions = []) -> Bool {
        activationCount += 1
        return true
    }
}
