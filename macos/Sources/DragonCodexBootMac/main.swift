import AppKit
import AVKit
import CoreGraphics
import Darwin
import Foundation
#if canImport(DragonCodexBootCore)
import DragonCodexBootCore
#endif

@MainActor
private func activateLauncher() {
    if #available(macOS 14.0, *) {
        NSApplication.shared.activate()
    } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private final class BootWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum LauncherError: LocalizedError {
    case missingConfig
    case missingVideo(URL)
    case missingApp(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "找不到 macOS 配置文件。请重新运行构建脚本。"
        case .missingVideo(let url):
            return "找不到启动视频：\n\(url.path)\n\n请把 MP4 放到该位置，或修改 launcher.json 中的 Video。"
        case .missingApp(let detail):
            return "找不到 Codex 桌面 App。\n\(detail)\n\n请安装官方 Codex，或在 launcher.json 中填写其 AppPath。"
        }
    }
}

private enum RuntimeFiles {
    static func directory(at url: URL, create: Bool) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        do {
            // Foundation standardization can turn /private/tmp back into the /tmp symlink.
            for component in url.pathComponents.dropFirst() {
                let child = try directory(named: component, in: descriptor, create: create)
                close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func directory(named name: String, in parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw failure() }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        return descriptor
    }

    static func containsRegularFile(_ name: String, in directory: Int32) throws -> Bool {
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw failure()
        }
        guard information.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        return true
    }

    static func regularFile(_ name: String, in directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let error = failure()
            close(descriptor)
            throw error
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw POSIXError(.EINVAL)
        }
        return descriptor
    }

    // Directory descriptors keep a renamed parent or a symlink swap from redirecting writes.
    static func copyIfMissing(from source: URL, to name: String, in directory: Int32) throws {
        guard try !containsRegularFile(name, in: directory) else { return }
        let sourceDirectory = try self.directory(at: source.deletingLastPathComponent(), create: false)
        defer { close(sourceDirectory) }
        let sourceDescriptor = try regularFile(source.lastPathComponent, in: sourceDirectory)
        defer { close(sourceDescriptor) }
        let temporaryName = ".dragon-copy-\(UUID().uuidString)"
        let targetDescriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard targetDescriptor >= 0 else { throw failure() }
        defer {
            close(targetDescriptor)
            unlinkat(directory, temporaryName, 0)
        }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: targetDescriptor, closeOnDealloc: false)
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try output.write(contentsOf: data)
        }
        guard fsync(targetDescriptor) == 0 else { throw failure() }
        // Publish only complete files; linkat never replaces an existing destination.
        if linkat(directory, temporaryName, directory, name, 0) != 0 {
            guard errno == EEXIST, try containsRegularFile(name, in: directory) else { throw failure() }
        }
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private struct RuntimeConfiguration {
    let configuration: LauncherConfiguration
    let root: URL

    static func load() throws -> RuntimeConfiguration {
        let fileManager = FileManager.default
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("DragonCodexBoot", isDirectory: true)
        return try load(supportRoot: supportRoot, resourceRoot: Bundle.main.resourceURL)
    }

    static func load(supportRoot: URL, resourceRoot: URL?) throws -> RuntimeConfiguration {
        let directory = try RuntimeFiles.directory(at: supportRoot, create: true)
        defer { close(directory) }
        try LocalPathSecurity.validateUserDirectory(at: supportRoot, openedAs: directory)
        if try !RuntimeFiles.containsRegularFile("launcher.json", in: directory) {
            guard let template = resourceRoot?.appendingPathComponent("launcher.macos.example.json") else {
                throw LauncherError.missingConfig
            }
            try RuntimeFiles.copyIfMissing(from: template, to: "launcher.json", in: directory)
        }
        let descriptor = try RuntimeFiles.regularFile("launcher.json", in: directory)
        defer { close(descriptor) }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let configuration = try LauncherConfiguration.decode(from: data)
        let runtime = RuntimeConfiguration(configuration: configuration, root: supportRoot)
        do { try runtime.copyBundledVideoIfNeeded(resourceRoot: resourceRoot) }
        catch { NSLog("Could not copy bundled startup video: %@", error.localizedDescription) }
        return runtime
    }

    private func copyBundledVideoIfNeeded(resourceRoot: URL? = Bundle.main.resourceURL) throws {
        guard configuration.video == "media/startup.mp4", let resourceRoot else { return }
        let directory = try RuntimeFiles.directory(at: root, create: false)
        defer { close(directory) }
        try LocalPathSecurity.validateUserDirectory(at: root, openedAs: directory)
        let mediaDirectory = try RuntimeFiles.directory(named: "media", in: directory, create: true)
        defer { close(mediaDirectory) }
        try LocalPathSecurity.validateUserDirectory(at: root.appendingPathComponent("media"), openedAs: mediaDirectory)
        try RuntimeFiles.copyIfMissing(
            from: resourceRoot.appendingPathComponent("media/startup.mp4"),
            to: "startup.mp4",
            in: mediaDirectory
        )
    }
}

@MainActor
private final class BootController: NSObject, NSWindowDelegate {
    private let configuration: LauncherConfiguration
    private let videoURL: URL
    private let appURL: URL
    private let targetBundleIdentifier: String
    private var targetApplication: NSRunningApplication?
    private var window: NSWindow?
    private var player: AVPlayer?
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var statusLabel: NSTextField?
    private var handedOff = false
    private var waitingAtHold = false
    private var elapsedBeforeWait: Double = 0
    private var startedAt = Date()
    private let watchMode: Bool
    private let onFinish: (@MainActor () -> Void)?

    init(
        runtime: RuntimeConfiguration,
        targetApplication: NSRunningApplication? = nil,
        watchMode: Bool = false,
        onFinish: (@MainActor () -> Void)? = nil
    ) throws {
        configuration = runtime.configuration
        videoURL = runtime.configuration.videoURL(relativeTo: runtime.root)
        let resolved = try Self.resolveApplication(for: runtime.configuration)
        appURL = resolved.url
        targetBundleIdentifier = resolved.bundleIdentifier
        if let targetApplication {
            try TrustedApplication.validateProcess(targetApplication.processIdentifier)
        }
        self.targetApplication = targetApplication
        self.watchMode = watchMode
        self.onFinish = onFinish
        super.init()
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LauncherError.missingVideo(videoURL)
        }
    }

    func start(matching targetFrame: CGRect? = nil) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(watchMode ? .accessory : .regular)
        if !watchMode { targetApplication = try runningTargetApplication() }
        if let targetApplication {
            try TrustedApplication.validateProcess(targetApplication.processIdentifier)
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame: NSRect
        if let targetFrame {
            frame = targetFrame
        } else if configuration.fullscreen, let screenFrame = screen?.frame {
            frame = screenFrame
        } else {
            frame = NSRect(
                x: visibleFrame.midX - CGFloat(configuration.playerWidth) / 2,
                y: visibleFrame.midY - CGFloat(configuration.playerHeight) / 2,
                width: CGFloat(configuration.playerWidth),
                height: CGFloat(configuration.playerHeight)
            )
        }

        let playerWindow = BootWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let matchesCodexWindow = targetFrame != nil
        playerWindow.title = configuration.displayName
        playerWindow.backgroundColor = matchesCodexWindow ? .clear : .black
        playerWindow.isOpaque = !matchesCodexWindow
        playerWindow.hasShadow = false
        playerWindow.level = .screenSaver
        playerWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        playerWindow.isReleasedWhenClosed = false
        playerWindow.delegate = self
        window = playerWindow

        let rootView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = matchesCodexWindow ? NSColor.clear.cgColor : NSColor.black.cgColor
        if matchesCodexWindow {
            rootView.layer?.cornerRadius = 12
            rootView.layer?.cornerCurve = .continuous
            rootView.layer?.masksToBounds = true
        }

        let videoView = AVPlayerView(frame: rootView.bounds)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.controlsStyle = .none
        videoView.videoGravity = .resizeAspectFill
        rootView.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: rootView.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        let skipButton = NSButton(title: "跳过  Esc", target: self, action: #selector(skip))
        skipButton.bezelStyle = .rounded
        skipButton.font = .systemFont(ofSize: 14, weight: .medium)
        skipButton.alphaValue = 0.78
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(skipButton)
        NSLayoutConstraint.activate([
            skipButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            skipButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
        ])

        let label = NSTextField(labelWithString: "Codex 正在启动…  Esc 跳过")
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -36),
        ])
        statusLabel = label

        playerWindow.contentView = rootView
        playerWindow.makeKeyAndOrderFront(nil)
        activateLauncher()
        installEscapeMonitor()
        if let targetApplication {
            do { try revealTargetBehindOverlay(targetApplication) }
            catch { stopForFailure(error); return }
        } else {
            beginOpeningTarget()
        }
        guard !handedOff else { return }
        beginPlayback(in: videoView)
        startedAt = Date()
        let playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
        NSLog("Dragon Codex Boot started; video=%@", videoURL.path)
    }

    private func beginPlayback(in view: AVPlayerView) {
        let item = AVPlayerItem(url: videoURL)
        let mediaPlayer = AVPlayer(playerItem: item)
        mediaPlayer.volume = Float(configuration.volume)
        view.player = mediaPlayer
        player = mediaPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handOff() }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor [weak self] in self?.showPlaybackFailure(error) }
        }
        mediaPlayer.play()
    }

    private func beginOpeningTarget() {
        if let running = targetApplication, !running.isTerminated {
            do { try revealTargetBehindOverlay(running) }
            catch { stopForFailure(error) }
            return
        }
        let launchURL: URL
        do { launchURL = try TrustedApplication.validatedLaunchURL(at: appURL) }
        catch { stopForFailure(error); return }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = false
        NSWorkspace.shared.openApplication(at: launchURL, configuration: openConfiguration) { [weak self] app, error in
            Task { @MainActor in
                guard let self, !self.handedOff else { return }
                if let error {
                    self.stopForFailure(error)
                    return
                }
                guard let app else {
                    self.stopForFailure(LauncherError.missingApp("启动操作没有返回目标进程。"))
                    return
                }
                do { try self.revealTargetBehindOverlay(app) }
                catch { self.stopForFailure(error) }
            }
        }
    }

    private func revealTargetBehindOverlay(_ app: NSRunningApplication) throws {
        try TrustedApplication.validateProcess(app.processIdentifier)
        targetApplication = app
        app.unhide()
        _ = app.activate(options: [.activateAllWindows])
        // Keep the animation in front and keep Esc available while Codex opens underneath it.
        window?.makeKeyAndOrderFront(nil)
        activateLauncher()
    }

    private func runningTargetApplication() throws -> NSRunningApplication? {
        let application = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == targetBundleIdentifier && !$0.isTerminated
        }
        if let application {
            try TrustedApplication.validateProcess(application.processIdentifier)
        }
        return application
    }

    private func targetIsReady() throws -> Bool {
        guard let app = targetApplication, !app.isTerminated, app.isFinishedLaunching else {
            targetApplication = try runningTargetApplication()
            return targetApplication?.isFinishedLaunching == true
        }
        return true
    }

    private func tick() {
        guard !handedOff, let player, let window else { return }
        if watchMode, targetApplication?.isTerminated != false {
            handOff()
            return
        }
        if Date().timeIntervalSince(startedAt) > configuration.maxWaitSeconds + 20 {
            handOff()
            return
        }

        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        let ready: Bool
        do { ready = try targetIsReady() }
        catch { stopForFailure(error); return }
        if !ready, !waitingAtHold, time >= configuration.holdAt {
            elapsedBeforeWait = time
            waitingAtHold = true
            player.pause()
            statusLabel?.isHidden = false
        } else if ready, waitingAtHold {
            waitingAtHold = false
            statusLabel?.isHidden = true
            player.seek(to: CMTime(seconds: elapsedBeforeWait, preferredTimescale: 600))
            player.play()
        }

        if ready, time >= configuration.transitionStart {
            window.alphaValue = configuration.playerOpacity(at: time)
            if time >= configuration.transitionEnd {
                handOff()
            }
        }
    }

    @objc private func skip() {
        handOff()
    }

    private func installEscapeMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.handOff() }
            return nil
        }
    }

    private func showPlaybackFailure(_ error: Error?) {
        guard !handedOff else { return }
        player?.pause()
        // A normal modal alert must not sit underneath the screen-saver-level video.
        window?.orderOut(nil)
        activateLauncher()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "启动动画或 Codex 启动失败"
        alert.informativeText = error?.localizedDescription ?? "无法播放启动视频。按确定后将尝试切换到 Codex。"
        alert.addButton(withTitle: "切换到 Codex")
        alert.runModal()
        handOff()
    }

    private func closeOverlay() {
        handedOff = true
        timer?.invalidate()
        timer = nil
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        keyMonitor = nil

        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func stopForFailure(_ error: Error) {
        guard !handedOff else { return }
        closeOverlay()
        NSLog("Codex launch stopped: %@", error.localizedDescription)
        if watchMode {
            onFinish?()
        } else {
            activateLauncher()
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func handOff() {
        guard !handedOff else { return }
        do {
            if let app = targetApplication, !app.isTerminated {
                try TrustedApplication.validateProcess(app.processIdentifier)
                closeOverlay()
                app.unhide()
                _ = app.activate(options: [.activateAllWindows])
                if watchMode { onFinish?() }
                else { NSApplication.shared.terminate(nil) }
                return
            }
            if watchMode {
                closeOverlay()
                onFinish?()
                return
            }
            let launchURL = try TrustedApplication.validatedLaunchURL(at: appURL)
            closeOverlay()
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.activates = false
            NSWorkspace.shared.openApplication(at: launchURL, configuration: openConfiguration) { app, error in
                Task { @MainActor in
                    do {
                        if let error { throw error }
                        guard let app else { throw LauncherError.missingApp("启动操作没有返回目标进程。") }
                        try TrustedApplication.validateProcess(app.processIdentifier)
                        app.unhide()
                        _ = app.activate(options: [.activateAllWindows])
                    } catch {
                        NSLog("Codex handoff stopped: %@", error.localizedDescription)
                        NSAlert(error: error).runModal()
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            stopForFailure(error)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !handedOff { handOff() }
    }

    fileprivate static func resolveApplication(for configuration: LauncherConfiguration) throws -> (url: URL, bundleIdentifier: String) {
        let fileManager = FileManager.default
        let bundleIdentifier = try TrustedApplication.validateBundleIdentifier(configuration.appBundleIdentifier)
        let rawPath = configuration.appPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawPath.isEmpty {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                throw LauncherError.missingApp("AppPath 不存在：\(url.path)")
            }
            return (try TrustedApplication.validatedLaunchURL(at: url), bundleIdentifier)
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           fileManager.fileExists(atPath: url.path) {
            return (try TrustedApplication.validatedLaunchURL(at: url), bundleIdentifier)
        }
        throw LauncherError.missingApp("未通过 Bundle Identifier 找到应用：\(bundleIdentifier)")
    }
}

private enum CodexWindowGeometry {
    static func frame(for processIdentifier: pid_t) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates: [(frame: CGRect, area: CGFloat)] = windowList.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }

            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.width >= 350,
                  frame.height >= 250 else {
                return nil
            }
            return (frame, frame.width * frame.height)
        }

        guard let quartzFrame = candidates.max(by: { $0.area < $1.area })?.frame else {
            return nil
        }

        // CGWindow bounds use a top-left origin; NSWindow frames use a bottom-left origin.
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: quartzFrame.minX,
            y: mainDisplayHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@MainActor
private final class CodexLaunchMonitor {
    private let runtime: RuntimeConfiguration
    private let targetBundleIdentifier: String
    private var launchObserver: NSObjectProtocol?
    private var windowPollTimer: Timer?
    private var pendingApplication: NSRunningApplication?
    private var pendingSince = Date()
    private var lastWindowFrame: CGRect?
    private var stableFrameCount = 0
    private var activeController: BootController?

    init(runtime: RuntimeConfiguration) throws {
        self.runtime = runtime
        targetBundleIdentifier = try BootController.resolveApplication(for: runtime.configuration).bundleIdentifier
    }

    func start() {
        let workspace = NSWorkspace.shared
        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in self?.applicationDidLaunch(application) }
        }
        NSLog("Dragon Codex Boot is watching for %@ launches", targetBundleIdentifier)
    }

    private func applicationDidLaunch(_ application: NSRunningApplication) {
        guard application.bundleIdentifier == targetBundleIdentifier,
              activeController == nil else {
            return
        }

        do { try TrustedApplication.validateProcess(application.processIdentifier) }
        catch {
            stopWaitingForWindow()
            NSLog("Ignoring untrusted Codex launch: %@", error.localizedDescription)
            return
        }

        pendingApplication = application
        pendingSince = Date()
        lastWindowFrame = nil
        stableFrameCount = 0
        windowPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollForWindow() }
        }
        windowPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        pollForWindow()
    }

    private func pollForWindow() {
        guard let application = pendingApplication, !application.isTerminated else {
            stopWaitingForWindow()
            return
        }

        if let frame = CodexWindowGeometry.frame(for: application.processIdentifier) {
            if frame == lastWindowFrame {
                stableFrameCount += 1
            } else {
                lastWindowFrame = frame
                stableFrameCount = 1
            }
            guard stableFrameCount >= 2 else { return }

            stopWaitingForWindow()
            do {
                let controller = try BootController(
                    runtime: runtime,
                    targetApplication: application,
                    watchMode: true,
                    onFinish: { [weak self] in self?.activeController = nil }
                )
                activeController = controller
                try controller.start(matching: frame)
            } catch {
                activeController = nil
                NSLog("Could not start Codex launch animation: %@", error.localizedDescription)
            }
            return
        }

        if Date().timeIntervalSince(pendingSince) > 30 {
            NSLog("Codex launched without a visible main window; skipping startup animation")
            stopWaitingForWindow()
        }
    }

    private func stopWaitingForWindow() {
        windowPollTimer?.invalidate()
        windowPollTimer = nil
        pendingApplication = nil
        lastWindowFrame = nil
        stableFrameCount = 0
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: BootController?
    private var launchMonitor: CodexLaunchMonitor?
    private let watchMode = CommandLine.arguments.contains("--watch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if watchMode {
            NSApplication.shared.setActivationPolicy(.accessory)
            do {
                let runtime = try RuntimeConfiguration.load()
                launchMonitor = try CodexLaunchMonitor(runtime: runtime)
                launchMonitor?.start()
            } catch {
                NSLog("Could not start Codex launch monitor: %@", error.localizedDescription)
                NSApplication.shared.terminate(nil)
            }
            return
        }

        do {
            let runtime = try RuntimeConfiguration.load()
            controller = try BootController(runtime: runtime)
            try controller?.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !watchMode }
}

private func exampleConfigurationURL() -> URL? {
    if let resource = Bundle.main.resourceURL?.appendingPathComponent("launcher.macos.example.json"),
       FileManager.default.fileExists(atPath: resource.path) {
        return resource
    }
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let candidates = [
        current.appendingPathComponent("config/launcher.macos.example.json"),
        current.appendingPathComponent("../config/launcher.macos.example.json"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

@main
@MainActor
private struct DragonCodexBootMacApp {
    static func main() {
        if CommandLine.arguments.contains("--install-integration") {
            fputs("此入口不再安装登录监视器。请运行 scripts/install-codex-integration.sh。\n", stderr)
            exit(1)
        }

        if CommandLine.arguments.contains("--uninstall-integration") {
            fputs("此入口不再卸载登录监视器。请运行 scripts/uninstall-codex-integration.sh。\n", stderr)
            exit(1)
        }

        if CommandLine.arguments.contains("--self-test") {
            do {
                guard let url = exampleConfigurationURL() else { throw LauncherError.missingConfig }
                let configuration = try LauncherConfiguration.decode(from: Data(contentsOf: url))
                let opacityChecks: [(Double, Double)] = [
                    (configuration.transitionStart, 1),
                    ((configuration.transitionStart + configuration.transitionEnd) / 2, 0.5),
                    (configuration.transitionEnd, 0),
                ]
                for (time, expected) in opacityChecks {
                    guard abs(configuration.playerOpacity(at: time) - expected) < 0.0001 else {
                        throw LauncherConfigurationError("播放器淡出曲线检查失败。")
                    }
                }
                print("macOS launcher configuration and fade checks passed: \(url.path)")
                exit(0)
            } catch {
                fputs("macOS launcher self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
