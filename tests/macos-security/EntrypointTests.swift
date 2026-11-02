@main
@MainActor
private struct SecurityEntrypointTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
        fflush(stdout)
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { print("PASS: \(message)") }
    }

    static func main() throws {
        let testRoot = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try checkConfiguredVideoIsReadOnly()
        try checkRuntimeResources(in: testRoot)
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
        let discoveryLink = testRoot.appendingPathComponent("DiscoveredCodex.app")
        try FileManager.default.createSymbolicLink(at: discoveryLink, withDestinationURL: URL(fileURLWithPath: officialPath))
        configuration.appPath = discoveryLink.path
        let physical = try BootController.resolveApplication(for: configuration)
        check(physical.url == URL(fileURLWithPath: officialPath).resolvingSymlinksInPath(), "resolver retains the validated physical launch URL")
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

    private static func checkConfiguredVideoIsReadOnly() throws {
        let fileManager = FileManager.default
        let testRoot = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let resourceRoot = Bundle.main.resourceURL!
        check(resourceRoot.resolvingSymlinksInPath() == testRoot.resolvingSymlinksInPath(), "resource regression runs only inside its private test directory")
        let source = resourceRoot.appendingPathComponent("security-probe.json")
        let supportRoot = testRoot.appendingPathComponent("read-only-video", isDirectory: true)
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        try Data("private fixture".utf8).write(to: source)
        defer { try? fileManager.removeItem(at: source) }
        let runtime = RuntimeConfiguration(configuration: LauncherConfiguration(video: source.lastPathComponent), root: supportRoot)
        try runtime.installTestVideo(resourceRoot: resourceRoot)
        check(!fileManager.fileExists(atPath: supportRoot.appendingPathComponent(source.lastPathComponent).path), "custom Video is read-only and cannot copy bundled files")
    }

    private static func checkRuntimeResources(in testRoot: URL) throws {
        let files = FileManager.default
        func directory(_ name: String) throws -> URL {
            let url = testRoot.appendingPathComponent(name, isDirectory: true)
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return url
        }
        let resources = try directory("resources/media").deletingLastPathComponent()
        let template = resources.appendingPathComponent("launcher.macos.example.json")
        let video = resources.appendingPathComponent("media/startup.mp4")
        let originalConfiguration = try JSONEncoder().encode(LauncherConfiguration())
        let originalVideo = Data("bundled startup video fixture".utf8)
        try originalConfiguration.write(to: template)
        try originalVideo.write(to: video)

        let support = testRoot.appendingPathComponent("support")
        _ = try RuntimeConfiguration.load(supportRoot: support, resourceRoot: resources)
        check(try Data(contentsOf: support.appendingPathComponent("launcher.json")) == originalConfiguration, "first launch copies the fixed default configuration")
        check(try Data(contentsOf: support.appendingPathComponent("media/startup.mp4")) == originalVideo, "first launch copies only the fixed startup video")
        let permissions = try files.attributesOfItem(atPath: support.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o700, "new application support directory is private")

        let preserved = Data("user video remains unchanged".utf8)
        try preserved.write(to: support.appendingPathComponent("media/startup.mp4"))
        var customizedConfiguration = LauncherConfiguration()
        customizedConfiguration.displayName = "User configuration"
        let customizedData = try JSONEncoder().encode(customizedConfiguration)
        try customizedData.write(to: support.appendingPathComponent("launcher.json"))
        try files.setAttributes([.posixPermissions: 0o750], ofItemAtPath: support.path)
        _ = try RuntimeConfiguration.load(supportRoot: support, resourceRoot: resources)
        check(try Data(contentsOf: support.appendingPathComponent("launcher.json")) == customizedData, "existing configuration is never overwritten")
        check(try Data(contentsOf: support.appendingPathComponent("media/startup.mp4")) == preserved, "existing videos are never overwritten")
        let retainedPermissions = try files.attributesOfItem(atPath: support.path)[.posixPermissions] as? NSNumber
        check(retainedPermissions?.intValue == 0o750, "existing directory permissions are preserved")

        let outside = try directory("outside")
        let outsideFile = outside.appendingPathComponent("configuration.json")
        try originalConfiguration.write(to: outsideFile)
        for (index, configuredPath) in ["../outside/copied.json", outside.appendingPathComponent("absolute.mp4").path].enumerated() {
            let root = try directory("custom-video-\(index)")
            let runtime = RuntimeConfiguration(configuration: LauncherConfiguration(video: configuredPath), root: root)
            try runtime.installTestVideo(resourceRoot: resources)
            check(try files.contentsOfDirectory(atPath: root.path).isEmpty, "custom Video path \(index) creates no destination")
        }

        let linkedSupport = testRoot.appendingPathComponent("linked-support")
        try files.createSymbolicLink(at: linkedSupport, withDestinationURL: outside)
        rejects("support directory symlink cannot redirect default configuration writes") {
            _ = try RuntimeConfiguration.load(supportRoot: linkedSupport, resourceRoot: resources)
        }
        let linkedConfigRoot = try directory("linked-config")
        try files.createSymbolicLink(at: linkedConfigRoot.appendingPathComponent("launcher.json"), withDestinationURL: outsideFile)
        rejects("configuration destination symlink is rejected") {
            _ = try RuntimeConfiguration.load(supportRoot: linkedConfigRoot, resourceRoot: resources)
        }
        let linkedTemplateRoot = try directory("linked-template")
        try files.createSymbolicLink(at: linkedTemplateRoot.appendingPathComponent(template.lastPathComponent), withDestinationURL: outsideFile)
        rejects("bundled configuration source symlink is rejected") {
            _ = try RuntimeConfiguration.load(supportRoot: testRoot.appendingPathComponent("template-target"), resourceRoot: linkedTemplateRoot)
        }
        let linkedResourceRoot = testRoot.appendingPathComponent("linked-resources")
        try files.createSymbolicLink(at: linkedResourceRoot, withDestinationURL: resources)
        rejects("bundled configuration source parent symlink is rejected") {
            _ = try RuntimeConfiguration.load(supportRoot: testRoot.appendingPathComponent("resource-target"), resourceRoot: linkedResourceRoot)
        }

        let linkedMediaRoot = try directory("linked-media")
        try files.createSymbolicLink(at: linkedMediaRoot.appendingPathComponent("media"), withDestinationURL: outside)
        rejects("video destination parent symlink cannot redirect writes") {
            try RuntimeConfiguration(configuration: LauncherConfiguration(), root: linkedMediaRoot).installTestVideo(resourceRoot: resources)
        }
        check(!files.fileExists(atPath: outside.appendingPathComponent("startup.mp4").path), "rejected video parent leaves the external directory unchanged")
        let linkedVideoRoot = try directory("linked-video/media").deletingLastPathComponent()
        try files.createSymbolicLink(at: linkedVideoRoot.appendingPathComponent("media/startup.mp4"), withDestinationURL: outsideFile)
        rejects("video destination leaf symlink cannot overwrite a file") {
            try RuntimeConfiguration(configuration: LauncherConfiguration(), root: linkedVideoRoot).installTestVideo(resourceRoot: resources)
        }
        let linkedSource = try directory("linked-video-source/media").deletingLastPathComponent()
        try files.createSymbolicLink(at: linkedSource.appendingPathComponent("media/startup.mp4"), withDestinationURL: outsideFile)
        rejects("bundled video source leaf symlink is rejected") {
            try RuntimeConfiguration(configuration: LauncherConfiguration(), root: try directory("video-source-target")).installTestVideo(resourceRoot: linkedSource)
        }
        let linkedSourceParent = try directory("linked-video-parent")
        try files.createSymbolicLink(at: linkedSourceParent.appendingPathComponent("media"), withDestinationURL: resources.appendingPathComponent("media"))
        rejects("bundled video source parent symlink is rejected") {
            try RuntimeConfiguration(configuration: LauncherConfiguration(), root: try directory("video-parent-target")).installTestVideo(resourceRoot: linkedSourceParent)
        }
        check(try Data(contentsOf: outsideFile) == originalConfiguration, "all rejected copies preserve the external file")

        var largeConfiguration = LauncherConfiguration()
        largeConfiguration.displayName = String(repeating: "startup", count: 300_000)
        let expectedDisplayName = largeConfiguration.displayName
        try JSONEncoder().encode(largeConfiguration).write(to: template)
        let concurrentRoot = testRoot.appendingPathComponent("concurrent-support")
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let runtime = try RuntimeConfiguration.load(supportRoot: concurrentRoot, resourceRoot: resources)
                guard runtime.configuration.displayName == expectedDisplayName else { throw POSIXError(.EIO) }
            } catch {
                lock.lock()
                failures.append(error.localizedDescription)
                lock.unlock()
            }
        }
        check(failures.isEmpty, "concurrent first launches only observe a complete configuration: \(failures)")
        check(try Data(contentsOf: concurrentRoot.appendingPathComponent("media/startup.mp4")) == originalVideo, "concurrent first launches preserve the complete video")
        check(try !files.contentsOfDirectory(atPath: concurrentRoot.path).contains { $0.hasPrefix(".dragon-copy-") }, "completed copies remove their private staging files")
    }
}

private extension RuntimeConfiguration {
    func installTestVideo(resourceRoot: URL? = Bundle.main.resourceURL) throws {
        try copyBundledVideoIfNeeded(resourceRoot: resourceRoot)
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
