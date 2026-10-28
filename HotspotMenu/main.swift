import AppKit
import Network
import CoreWLAN

// A satisfied network path suppresses auto-connect even when SSID is hidden.
// This intentionally does not switch away from Wi-Fi with a captive portal.
func shouldConnect(enabled: Bool, online: Bool, busy: Bool, wifiOn: Bool,
                   offlineSeconds: Double, cooldownSeconds: Double, immediate: Bool = false) -> Bool {
    enabled && !online && !busy && wifiOn && (immediate || (offlineSeconds >= 15 && cooldownSeconds >= 120))
}
func completionReason(online: Bool, running: Bool, elapsed: TimeInterval) -> String? {
    if online { return "网络已恢复" }
    if !running { return "连接进程已结束" }
    if elapsed >= 65 { return "连接超时，已停止" }
    return nil
}
if CommandLine.arguments.contains("--self-test") {
    assert(shouldConnect(enabled: true, online: false, busy: false, wifiOn: true, offlineSeconds: 16, cooldownSeconds: 121))
    for state in 0..<5 {
        assert(!shouldConnect(enabled: state != 0, online: state == 1, busy: state == 2,
                              wifiOn: state != 3, offlineSeconds: state == 4 ? 2 : 16, cooldownSeconds: 121))
    }
    assert(!shouldConnect(enabled: true, online: false, busy: false, wifiOn: true, offlineSeconds: 50, cooldownSeconds: 30))
    assert(shouldConnect(enabled: true, online: false, busy: false, wifiOn: true, offlineSeconds: 0, cooldownSeconds: 0, immediate: true))
    assert(!shouldConnect(enabled: true, online: true, busy: false, wifiOn: true, offlineSeconds: 0, cooldownSeconds: 0, immediate: true))
    assert(!shouldConnect(enabled: false, online: false, busy: false, wifiOn: true, offlineSeconds: 0, cooldownSeconds: 0, immediate: true))
    assert(!shouldConnect(enabled: true, online: false, busy: true, wifiOn: true, offlineSeconds: 0, cooldownSeconds: 0, immediate: true))
    assert(completionReason(online: true, running: true, elapsed: 2) == "网络已恢复")
    assert(completionReason(online: false, running: false, elapsed: 2) == "连接进程已结束")
    assert(completionReason(online: false, running: true, elapsed: 65) == "连接超时，已停止")
    assert(completionReason(online: false, running: true, elapsed: 64) == nil)
    print("Auto-connect and lifecycle tests passed")
    exit(0)
}

final class App: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    let toggle = NSMenuItem(title: "自动连接", action: #selector(toggleAuto), keyEquivalent: "")
    let state = NSMenuItem(title: "正在检查网络…", action: nil, keyEquivalent: "")
    let connect = NSMenuItem(title: "立即连接 iPhone", action: #selector(connectNow), keyEquivalent: "")
    var monitor = NWPathMonitor()
    var monitorGeneration = 0
    var urgentUntil = -Double.infinity
    var lastUrgentAttempt = -Double.infinity
    var online = false
    var hasPath = false
    var offlineSince = ProcessInfo.processInfo.systemUptime
    var lastAttempt = -Double.infinity
    var process: Process?
    var attemptStarted = Date.distantPast
    var checkingWiFi = false
    var diagnosticHandle: FileHandle?
    var diagnosticURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HotspotMenu/connection.log")
    }
    func log(_ text: String) {
        try? diagnosticHandle?.write(contentsOf: Data("[\(Date())] \(text)\n".utf8))
    }
    func finishAttempt(_ message: String) {
        let old = process
        process = nil
        if old?.isRunning == true { old?.terminate() }
        lastAttempt = ProcessInfo.processInfo.systemUptime
        urgentUntil = -Double.infinity
        note = message; log(message); refresh()
    }
    var timer: Timer?
    var enabled = UserDefaults.standard.bool(forKey: "autoConnect")
    var target: String { UserDefaults.standard.string(forKey: "target") ?? "" }
    var note = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reopening the .app should not start a second background controller.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        for entry in [toggle, connect] { entry.target = self }
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(toggle)
        menu.addItem(connect)
        let phone = NSMenuItem(title: "设置 iPhone 名称…", action: #selector(setPhone), keyEquivalent: "")
        phone.target = self; menu.addItem(phone)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(resumeActivity), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(resumeActivity),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        try? FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: diagnosticURL.path) { FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil) }
        diagnosticHandle = try? FileHandle(forWritingTo: diagnosticURL)
        _ = try? diagnosticHandle?.seekToEnd()
        let logs = NSMenuItem(title: "查看连接日志", action: #selector(showLog), keyEquivalent: "")
        logs.target = self; menu.insertItem(logs, at: menu.items.count - 1)
        log("App started")
        armImmediateCheck()
        timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }
    // Use a fresh path after resume: pre-sleep path state can be stale.
    func startMonitor() {
        monitor.cancel()
        monitor = NWPathMonitor()
        monitorGeneration += 1
        let generation = monitorGeneration
        hasPath = false
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.monitorGeneration == generation else { return }
                let up = path.status == .satisfied
                if !self.hasPath || self.online != up {
                    self.offlineSince = ProcessInfo.processInfo.systemUptime
                    self.note = ""
                }
                self.hasPath = true; self.online = up
                self.tick(); self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "hotspot.network"))
    }
    @objc func resumeActivity(_ notification: Notification) { armImmediateCheck() }
    func armImmediateCheck() {
        // Wake, display wake and unlock often arrive together. Only one attempt
        // is allowed per 30-second burst; disabled mode never starts a helper.
        if enabled { urgentUntil = ProcessInfo.processInfo.systemUptime + 30 }
        startMonitor()
    }
    func refresh() {
        toggle.state = enabled ? .on : .off
        item.button?.title = process != nil ? "热点 ⋯" : (enabled ? "热点 ●" : "热点 ○")
        item.button?.toolTip = "iPhone 热点自动连接"
        connect.isEnabled = process == nil
        let network = !hasPath ? "正在检查网络" : online ? "网络已连接" : "没有可用网络路径"
        state.title = process != nil ? "正在连接 \(target)…" : "\(network) · 自动\(enabled ? "开启" : "关闭")"
        if !note.isEmpty { state.title += " · \(note)" }
    }
    @objc func showLog() { NSWorkspace.shared.open(diagnosticURL) }
    func tick() {
        // Reconcile state even if the exit callback was delayed or the user
        // connected manually. Wall-clock timeout also covers time asleep.
        if let p = process {
            if let reason = completionReason(online: hasPath && online, running: p.isRunning,
                                             elapsed: Date().timeIntervalSince(attemptStarted)) {
                finishAttempt(reason); return
            }
            return
        }
        guard hasPath, enabled, !online, !target.isEmpty, !checkingWiFi else { refresh(); return }
        checkingWiFi = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wifiOn = CWWiFiClient.shared().interface()?.powerOn() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingWiFi = false
                let now = ProcessInfo.processInfo.systemUptime
                if shouldConnect(enabled: self.enabled, online: self.online, busy: self.process != nil, wifiOn: wifiOn,
                                 offlineSeconds: now - self.offlineSince, cooldownSeconds: now - self.lastAttempt,
                                 immediate: now < self.urgentUntil && now - self.lastUrgentAttempt >= 30) && self.hasPath {
                    self.urgentUntil = -Double.infinity
                    self.lastUrgentAttempt = now
                    self.launch()
                }
            }
        }
    }
    @objc func toggleAuto() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "autoConnect")
        offlineSince = ProcessInfo.processInfo.systemUptime
        if !enabled { urgentUntil = -Double.infinity; finishAttempt("自动连接已关闭") }
        else { armImmediateCheck() }
        note = ""; refresh()
    }
    @objc func connectNow() { launch() }
    func launch() {
        guard process == nil else { return }
        guard !target.isEmpty else { note = "请先设置 iPhone 名称"; refresh(); return }
        let p = Process()
        p.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hotspot-probe")
        p.arguments = ["connect-sharing", target]
        p.standardOutput = diagnosticHandle ?? FileHandle.nullDevice; p.standardError = diagnosticHandle ?? FileHandle.nullDevice
        lastAttempt = ProcessInfo.processInfo.systemUptime
        process = p; note = ""; attemptStarted = Date(); log("Starting connection helper")
        p.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.log("Helper exited: \(task.terminationStatus)")
                self.process = nil
                self.lastAttempt = ProcessInfo.processInfo.systemUptime
                self.note = self.online ? "" : "已结束，等待网络恢复"
                self.refresh()
            }
        }
        do { try p.run() } catch { process = nil; note = "无法启动连接工具" }
        refresh()
    }
    @objc func setPhone() {
        guard process == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "iPhone 名称"
        alert.informativeText = "填写热点扫描中显示的完整名称。"
        let field = NSTextField(string: target)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { UserDefaults.standard.set(name, forKey: "target") }
        }
        refresh()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); monitor.cancel(); process?.terminate(); NSWorkspace.shared.notificationCenter.removeObserver(self); DistributedNotificationCenter.default().removeObserver(self) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
