import Foundation
import AppKit
import AVKit
import ScreenCaptureKit
import Security

final class LayoutView: NSView { override var isFlipped: Bool { true } }
final class GuardDesktop: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var settings = Settings()
    var window: NSWindow!
    let tabs = NSTabView(), playerView = AVPlayerView()
    private var actions = [Int: () -> Void]()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var tracker = SessionTracker()
    private var active = Set<String>()
    private var sampling = false, requestedRecording = false, terminating = false, updating = false, checkingUpdate = false
    private var nextRecordingRetry = Date.distantPast, nextUpdateCheck = Date.distantPast, nextInstallTry = Date.distantPast
    private var available: MacUpdate?
    private let recorder = Recorder()
    private var movie: MemoryMovie?
    private var selectedRecording: URL?, selectedKey: URL?
    private var libraryFiles = [URL]()
    private var keyMonitor: Any?
    private let monitorStatus = NSTextField(labelWithString: ""), recordingStatus = NSTextField(labelWithString: ""), updateStatus = NSTextField(labelWithString: ""), footer = NSTextField(labelWithString: "就绪")
    private var recordingEnabled: NSButton!, autoUpdate: NSButton!, loginStart: NSButton!
    private var folder: NSTextField!, quota: NSTextField!, password: NSTextField!, confirmation: NSTextField!, bark: NSTextField!, hayo: NSTextField!, playbackPassword: NSTextField!
    private var library: NSComboBox!, keyLabel: NSTextField!, installUpdate: NSButton!
    private let sessionsURL = supportRoot.appendingPathComponent("sessions.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { settings = try Settings.load() } catch { logGuard("配置读取失败：" + error.localizedDescription) }
        if let data = try? Data(contentsOf: sessionsURL), let saved = try? JSONDecoder().decode(SessionTracker.self, from: data) {
            tracker = saved; tracker.confirmed = tracker.confirmed.filter { Date().timeIntervalSince1970 - $0.value < 180 }; active = Set(tracker.confirmed.keys)
        }
        buildWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); statusItem.button?.title = "远程守护"
        let menu = NSMenu(); let show = menu.addItem(withTitle: "打开远程守护", action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let quit = menu.addItem(withTitle: "退出软件", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; statusItem.menu = menu
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow), name: Notification.Name("com.soujer.remote-guard.show"), object: String(getuid()))
        recorder.onStatus = { [weak self] text, running in
            guard let self else { return }; self.recordingStatus.stringValue = text
            if !running { self.requestedRecording = false; self.nextRecordingRetry = Date().addingTimeInterval(60) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.playerView.isInFullScreenMode == true { self?.playerView.exitFullScreenMode(options: nil); return nil }; return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        nextUpdateCheck = Date().addingTimeInterval(10)
        if !CommandLine.arguments.contains("--background") { showWindow() }
        tick()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
    @objc func showWindow() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); NSApp.setActivationPolicy(.accessory); maybeInstall(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }; terminating = true; timer?.invalidate(); stopPlayback()
        recorder.stop { sender.reply(toApplicationShouldTerminate: true) }; return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func action(_ sender: NSControl) { actions[sender.tag]?() }
    @discardableResult private func button(_ title: String, _ parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 150, _ handler: @escaping () -> Void) -> NSButton {
        let value = NSButton(title: title, target: self, action: #selector(action(_:))); value.tag = actions.count; actions[value.tag] = handler
        value.frame = NSRect(x: x, y: y, width: width, height: 34); value.bezelStyle = .rounded; parent.addSubview(value); return value
    }
    @discardableResult private func label(_ text: String, _ parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 840, _ height: CGFloat = 28) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text); value.frame = NSRect(x: x, y: y, width: width, height: height); parent.addSubview(value); return value
    }
    private func field(_ text: String, _ parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, secure: Bool = false) -> NSTextField {
        let value: NSTextField = secure ? NSSecureTextField() : NSTextField(); value.stringValue = text; value.frame = NSRect(x: x, y: y, width: width, height: 28); parent.addSubview(value); return value
    }
    private func checkBox(_ text: String, _ checked: Bool, _ parent: NSView, _ y: CGFloat, _ handler: @escaping () -> Void) -> NSButton {
        let value = NSButton(checkboxWithTitle: text, target: self, action: #selector(action(_:))); value.tag = actions.count; actions[value.tag] = handler
        value.state = checked ? .on : .off; value.frame = NSRect(x: 25, y: y, width: 840, height: 30); parent.addSubview(value); return value
    }
    private func page(_ name: String) -> NSView {
        let item = NSTabViewItem(identifier: name); item.label = name; let view = LayoutView(frame: NSRect(x: 0, y: 0, width: 900, height: 640)); item.view = view; tabs.addTabViewItem(item); return view
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 800), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "远程守护 · macOS"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let root = LayoutView(frame: NSRect(x: 0, y: 0, width: 960, height: 800)); window.contentView = root
        let heading = label("远程守护", root, 25, 18); heading.font = .boldSystemFont(ofSize: 24)
        tabs.frame = NSRect(x: 15, y: 65, width: 930, height: 675); root.addSubview(tabs)
        footer.frame = NSRect(x: 25, y: 755, width: 900, height: 30); root.addSubview(footer)
        let monitor = page("监控"), push = page("推送"), record = page("加密录屏"), playback = page("录像播放"), update = page("更新")
        label("确认远程连接后告警；启用录屏后自动在本机加密保存画面。", monitor, 25, 25)
        button("启动监控", monitor, 25, 85) { [weak self] in self?.setMonitoring(true) }
        button("停止监控", monitor, 190, 85) { [weak self] in self?.setMonitoring(false) }
        loginStart = checkBox("登录时后台运行（请先把软件放入“应用程序”文件夹）", fm.fileExists(atPath: LaunchAgent.url.path), monitor, 150) { [weak self] in self?.saveLogin() }
        monitorStatus.frame = NSRect(x: 25, y: 215, width: 840, height: 100); monitorStatus.maximumNumberOfLines = 0; monitor.addSubview(monitorStatus)
        recordingStatus.frame = NSRect(x: 25, y: 330, width: 840, height: 70); recordingStatus.maximumNumberOfLines = 0; recordingStatus.stringValue = "录屏未启用"; monitor.addSubview(recordingStatus)
        label("关闭窗口后继续后台监控；从菜单栏打开软件或退出。", monitor, 25, 430)
        button("打开录像文件夹", monitor, 25, 480, 180) { [weak self] in guard let self else { return }; self.attempt { let url = URL(fileURLWithPath: self.settings.directory); try ensureDirectory(url); NSWorkspace.shared.open(url) } }
        label("Bark key（留空表示不使用此通道）", push, 25, 30); bark = field(settings.barkKey, push, 25, 65, 820, secure: true)
        label("hayo 微信 token（留空表示不使用此通道）", push, 25, 125); hayo = field(settings.hayoToken, push, 25, 160, 820, secure: true)
        button("保存推送设置", push, 25, 230) { [weak self] in self?.savePush() }
        button("测试推送", push, 195, 230) { [weak self] in self?.testPush() }
        label("仅在连接、断开时提醒一次；推送失败会记录在本机日志中，不影响录屏。", push, 25, 310, 840, 60)
        recordingEnabled = checkBox("确认远程连接后自动加密录屏（主显示器，无声音）", settings.recording, record, 20) { }
        button("授权屏幕录制", record, 25, 65, 180) { [weak self] in self?.authorizeScreen() }
        label("使用系统自带的录屏与编码组件，无需下载。授权后如仍不可录制，请重启软件。", record, 230, 70, 625, 55)
        label("录像保存目录", record, 25, 140); folder = field(settings.directory, record, 25, 175, 650)
        button("浏览", record, 700, 171, 150) { [weak self] in self?.chooseDirectory() }
        label("存储上限（MB）；达到上限删除最旧片段", record, 25, 225); quota = field(String(settings.quotaMB), record, 25, 260, 140)
        label("私钥密码（至少 12 位）", record, 25, 315, 390); label("再次输入密码（确认）", record, 460, 315, 390)
        password = field("", record, 25, 350, 390, secure: true); confirmation = field("", record, 460, 350, 390, secure: true)
        label("已有密钥时可留空保存；导入 Windows 私钥时，在左侧输入其密码后点击“导入私钥”。", record, 25, 400, 840, 55)
        button("保存录屏设置", record, 25, 465, 180) { [weak self] in self?.saveRecording() }
        button("导入已有私钥", record, 230, 465, 180) { [weak self] in self?.importKey() }
        label("默认每 5 分钟分段、720p / 5 帧每秒 / 400 kbps，约 15 MB；默认上限 2 GB。\n私钥和密码丢失无法恢复录像，请另行备份。", record, 25, 535, 840, 65)
        library = NSComboBox(frame: NSRect(x: 25, y: 20, width: 640, height: 30)); library.isEditable = false; playback.addSubview(library)
        button("刷新", playback, 690, 16, 155) { [weak self] in self?.refreshLibrary() }
        button("打开其他录像", playback, 25, 65, 180) { [weak self] in self?.chooseRecording() }
        button("选择私钥", playback, 225, 65, 160) { [weak self] in self?.choosePlaybackKey() }
        keyLabel = label("请选择播放私钥", playback, 405, 73, 440)
        label("私钥密码", playback, 25, 125, 100); playbackPassword = field("", playback, 125, 120, 330, secure: true)
        button("播放", playback, 475, 116, 110) { [weak self] in self?.play() }
        button("停止", playback, 595, 116, 110) { [weak self] in self?.stopPlayback() }
        button("全屏", playback, 725, 116, 120) { [weak self] in self?.toggleFullScreen() }
        playerView.frame = NSRect(x: 25, y: 175, width: 820, height: 395); playerView.controlsStyle = .inline; playerView.showsFullScreenToggleButton = true; playerView.showsSharingServiceButton = false; playback.addSubview(playerView)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFullScreen)); doubleClick.numberOfClicksRequired = 2; playerView.addGestureRecognizer(doubleClick)
        label("双击画面或点击全屏按钮，Esc 退出。验证和解密在本机内存完成，不生成明文视频。", playback, 25, 590, 840, 45)
        label("当前版本 v" + MacUpdates.current + " · Apple 芯片 / Intel 通用版 · 更新来源 Gitee", update, 25, 30)
        autoUpdate = checkBox("自动检查并安装正式版更新（每 6 小时，软件空闲且窗口关闭后安装）", settings.autoUpdate, update, 95) { [weak self] in self?.saveAutoUpdate() }
        button("检查更新", update, 25, 165) { [weak self] in self?.checkUpdates() }
        installUpdate = button("更新并重启", update, 200, 165) { [weak self] in self?.beginInstall() }; installUpdate.isEnabled = false
        updateStatus.frame = NSRect(x: 25, y: 240, width: 840, height: 150); updateStatus.maximumNumberOfLines = 0; updateStatus.stringValue = "更新会保留推送配置、私钥和录像。\n远程会话、录屏或视频播放期间延后自动安装。\n更新后若系统要求重新授权屏幕录制，请在录屏页面处理。"; update.addSubview(updateStatus)
        refreshLibrary(); refreshStatus()
    }
    private func attempt(_ handler: () throws -> Void) { do { try handler() } catch { footer.stringValue = error.localizedDescription; logGuard(error.localizedDescription) } }
    private func refreshStatus() {
        monitorStatus.stringValue = (settings.monitoring ? "后台监控已启动" : "监控未启动") + "\n" + (active.isEmpty ? "当前未确认远程会话" : active.sorted().joined(separator: "、") + " 已连接")
        if !settings.recording { recordingStatus.stringValue = "录屏未启用" }
    }
    private func setMonitoring(_ enabled: Bool) {
        attempt {
            var updated = settings; updated.monitoring = enabled; try updated.save(); settings = updated
            if enabled { try retireLegacyAgents() }
            else { active.removeAll(); tracker = SessionTracker(); requestedRecording = false; recorder.stop(); try? fm.removeItem(at: sessionsURL) }
            footer.stringValue = enabled ? "监控已启动" : "监控已停止，配置、密钥和录像保留"; refreshStatus(); tick()
        }
    }
    private func retireLegacyAgents() throws {
        for name in ["com.soujer.remote-guard", "com.soujer.remote-guard.instant"] {
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + name + ".plist")
            guard fm.fileExists(atPath: url.path) else { continue }
            let backup = supportRoot.appendingPathComponent("backups", isDirectory: true); try ensureDirectory(backup)
            _ = try? runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/" + name])
            try fm.moveItem(at: url, to: backup.appendingPathComponent("legacy-" + name + "-" + UUID().uuidString + ".plist"))
        }
    }
    private func saveLogin() {
        attempt {
            if loginStart.state == .on {
                let path = Bundle.main.bundleURL.path
                try require(path.hasPrefix("/Applications/") || path.hasPrefix(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"), "请先把 RemoteGuard.app 放入“应用程序”文件夹")
                try LaunchAgent.register(Bundle.main.bundleURL)
            } else { try LaunchAgent.remove() }
            footer.stringValue = "登录启动设置已保存"
        }
        loginStart.state = fm.fileExists(atPath: LaunchAgent.url.path) ? .on : .off
    }
    private func savePush() { attempt { settings.barkKey = bark.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); settings.hayoToken = hayo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); try settings.save(); footer.stringValue = "推送设置已保存" } }
    private func testPush() { savePush(); Notifications.send("远程守护测试", body: "推送通道测试", settings: settings) { [weak self] ok in self?.footer.stringValue = ok ? "测试推送已发送" : "推送失败，请检查 key / token 和网络" } }
    private func authorizeScreen() {
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        footer.stringValue = granted ? "已获得屏幕录制权限" : "请在系统设置 → 隐私与安全性 → 屏幕录制中允许远程守护，随后重启软件"
        if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        nextRecordingRetry = .distantPast
    }
    private func chooseDirectory() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { folder.stringValue = url.path } }
    private func saveRecording() {
        attempt {
            var updated = settings; updated.recording = recordingEnabled.state == .on; updated.directory = folder.stringValue; updated.quotaMB = Int(quota.stringValue) ?? 0
            var validation = updated; validation.recording = false; try validation.validate()
            if updated.recording {
                try require(updated.directory.hasPrefix("/"), "请选择绝对保存路径"); try ensureDirectory(URL(fileURLWithPath: updated.directory))
                let probe = URL(fileURLWithPath: updated.directory).appendingPathComponent(".write-check-" + UUID().uuidString)
                try Data().write(to: probe, options: .withoutOverwriting); try fm.removeItem(at: probe)
                if updated.publicKey.isEmpty {
                    if let error = Vault.passwordError(password.stringValue, confirmation.stringValue) { throw GuardError.message(error) }
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "remote-guard-playback.rgkey"; panel.allowedFileTypes = ["rgkey"]; panel.canCreateDirectories = true; panel.title = "保存播放私钥，请另行备份"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    updated.publicKey = try Vault.createKey(url, password: password.stringValue)
                }
            }
            try updated.save(); settings = updated; password.stringValue = ""; confirmation.stringValue = ""; footer.stringValue = "录屏设置已保存（已有密钥保留）"
            if requestedRecording { requestedRecording = false; recorder.stop() }; nextRecordingRetry = .distantPast; refreshStatus(); refreshLibrary()
        }
    }
    private func importKey() {
        attempt {
            let panel = NSOpenPanel(); panel.allowedFileTypes = ["rgkey"]; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let key = try Vault.readKey(url, password: password.stringValue)
            guard let publicKey = SecKeyCopyPublicKey(key) else { throw GuardError.message("无法读取私钥对应的公钥") }
            var updated = settings; updated.publicKey = try KeyXML.encode(publicKey, privateKey: false); try updated.save(); settings = updated
            password.stringValue = ""; confirmation.stringValue = ""; footer.stringValue = "已导入公钥；原私钥文件保留，播放时仍需选择它"
        }
    }
    private func refreshLibrary() {
        libraryFiles = ((try? RecordingStorage.files(URL(fileURLWithPath: settings.directory))) ?? []).filter { $0.pathExtension == "rgrec" }.reversed()
        library.removeAllItems(); library.addItems(withObjectValues: libraryFiles.map { $0.lastPathComponent }); if !libraryFiles.isEmpty { library.selectItem(at: 0) }
    }
    private func chooseRecording() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["rgrec"]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { selectedRecording = url; library.deselectItem(at: library.indexOfSelectedItem); footer.stringValue = "已选择录像：" + url.lastPathComponent } }
    private func choosePlaybackKey() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["rgkey"]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { selectedKey = url; keyLabel.stringValue = url.lastPathComponent } }
    private func play() {
        stopPlayback()
        guard let file = library.indexOfSelectedItem >= 0 ? libraryFiles[library.indexOfSelectedItem] : selectedRecording, let key = selectedKey else { footer.stringValue = "请选择录像和播放私钥"; return }
        let secret = playbackPassword.stringValue; playbackPassword.stringValue = ""; footer.stringValue = "正在验证和解锁录像……"
        DispatchQueue.global(qos: .userInitiated).async {
            do { let bytes = try Vault.decrypt(file, keyURL: key, password: secret); DispatchQueue.main.async { self.movie = MemoryMovie(bytes); self.playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: self.movie!.asset)); self.playerView.player?.play(); self.footer.stringValue = "正在播放；双击画面可全屏，Esc 退出" } }
            catch { DispatchQueue.main.async { self.footer.stringValue = "播放失败：" + error.localizedDescription } }
        }
    }
    private func stopPlayback() { if playerView.isInFullScreenMode { playerView.exitFullScreenMode(options: nil) }; playerView.player?.pause(); playerView.player?.replaceCurrentItem(with: nil); playerView.player = nil; movie = nil }
    @objc private func toggleFullScreen() { if playerView.isInFullScreenMode { playerView.exitFullScreenMode(options: nil) } else if let screen = window.screen ?? NSScreen.main { playerView.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false]) } }
    private func saveAutoUpdate() { attempt { settings.autoUpdate = autoUpdate.state == .on; try settings.save(); footer.stringValue = "自动更新偏好已保存" } }
    private func checkUpdates() {
        guard !checkingUpdate && !updating else { return }; checkingUpdate = true; nextUpdateCheck = Date().addingTimeInterval(6 * 3600); updateStatus.stringValue = "正在检查 Gitee 正式发行版……"
        DispatchQueue.global(qos: .utility).async {
            do { let update = try MacUpdates.check(); DispatchQueue.main.async { self.available = update; self.checkingUpdate = false; self.installUpdate.isEnabled = update != nil; self.updateStatus.stringValue = update.map { "发现新版 v" + $0.version + "。远程会话、录屏或播放期间延后安装。" } ?? "已是最新正式版"; self.maybeInstall() } }
            catch { DispatchQueue.main.async { self.checkingUpdate = false; self.updateStatus.stringValue = "检查更新失败：" + error.localizedDescription } }
        }
    }
    private func maybeInstall() { if settings.autoUpdate && !window.isVisible && active.isEmpty && !requestedRecording && playerView.player == nil && Date() >= nextInstallTry && available != nil { beginInstall() } }
    private func beginInstall() {
        guard let available, !updating else { return }
        guard active.isEmpty && !requestedRecording else { updateStatus.stringValue = "请等待远程会话和录屏结束后更新"; return }
        updating = true; nextInstallTry = Date().addingTimeInterval(3600); installUpdate.isEnabled = false; updateStatus.stringValue = "正在下载并校验通用版更新……"
        DispatchQueue.global(qos: .utility).async {
            do { let app = try MacUpdates.prepare(available); DispatchQueue.main.async {
                self.attempt { try require(self.active.isEmpty && !self.requestedRecording, "远程会话已开始，延后更新"); try MacUpdates.install(app); NSApp.terminate(nil) }
                self.updating = false; self.installUpdate.isEnabled = true
            } } catch { DispatchQueue.main.async { self.updating = false; self.installUpdate.isEnabled = true; self.updateStatus.stringValue = "更新失败，现有程序保留：" + error.localizedDescription } }
        }
    }
    private func tick() {
        if settings.autoUpdate && Date() >= nextUpdateCheck { checkUpdates() }; maybeInstall()
        // Continue detection throughout download/verification so a new session postpones installation.
        guard settings.monitoring && !sampling && !terminating else { refreshStatus(); return }
        sampling = true
        DispatchQueue.global(qos: .utility).async {
            let sample = try? Detection.sample()
            DispatchQueue.main.async {
                self.sampling = false; guard self.settings.monitoring && !self.terminating else { return }
                let previous = self.active; self.active = self.tracker.update(sample, now: Date().timeIntervalSince1970)
                for name in self.active.subtracting(previous) { Notifications.send(name + " 已连接", body: "已连接", settings: self.settings) { _ in } }
                for name in previous.subtracting(self.active) { Notifications.send(name + " 已断开", body: "已断开", settings: self.settings) { _ in } }
                if let data = try? JSONEncoder().encode(self.tracker) { try? data.write(to: self.sessionsURL, options: .atomic) }
                if self.settings.recording && !self.active.isEmpty && !self.requestedRecording && Date() >= self.nextRecordingRetry { self.requestedRecording = true; self.recorder.start(self.settings) }
                if (self.active.isEmpty || !self.settings.recording) && self.requestedRecording { self.requestedRecording = false; self.recorder.stop() }
                self.refreshStatus()
            }
        }
    }
}
