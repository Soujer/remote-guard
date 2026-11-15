import Foundation
import AppKit
import AVKit
import ScreenCaptureKit
import Security

final class LayoutView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.intersection(dirtyRect).fill(); super.draw(dirtyRect) }
}
final class SeekSlider: NSSlider {
    var isDragging = false
    override func mouseDown(with event: NSEvent) { isDragging = true; defer { isDragging = false }; super.mouseDown(with: event) }
}
final class GuardDesktop: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var settings = Settings()
    var window: NSWindow!
    let tabs = NSTabView(), playerView = AVPlayerView()
    private var actions = [Int: () -> Void]()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var tracker = SessionTracker()
    private var active = Set<String>()
    private var sampling = false, requestedRecording = false, terminating = false, updating = false, checkingUpdate = false
    private var samplingFailed = false
    private var lastSamplingError = Date.distantPast
    private var nextRecordingRetry = Date.distantPast, nextUpdateCheck = Date.distantPast, nextInstallTry = Date.distantPast
    private var available: MacUpdate?
    private let recorder = Recorder()
    private var movie: MemoryMovie?
    private var playbackGeneration = 0
    private var testRecordingUntil = Date.distantPast
    private var selectedRecording: URL?, selectedKey: URL?
    private var libraryFiles = [URL]()
    private var keyMonitor: Any?
    private let monitorStatus = NSTextField(labelWithString: ""), recordingStatus = NSTextField(labelWithString: ""), updateStatus = NSTextField(labelWithString: ""), footer = NSTextField(labelWithString: "就绪")
    private var recordingEnabled: NSButton!, autoUpdate: NSButton!, loginStart: NSButton!
    private var folder: NSTextField!, quota: NSTextField!, password: NSTextField!, confirmation: NSTextField!, bark: NSTextField!, hayo: NSTextField!, playbackPassword: NSTextField!
    private var library: NSTableView!, keyLabel: NSTextField!, installUpdate: NSButton!
    let playbackSurface = LayoutView()
    let timeline = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let speed = NSPopUpButton(), playbackClock = NSTextField(labelWithString: "00:00:00 / --:--:--")
    private var playbackTimer: Timer?, pauseButton: NSButton!
    private var playingFile: URL?, durationSaved = false
    private var seekGeneration = 0, wantsPlayback = false
    private var playbackSpeed: Float { [0.5, 1, 1.5, 2, 3, 4][max(0, speed.indexOfSelectedItem)] }
    private let sessionsURL = supportRoot.appendingPathComponent("sessions.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { settings = try Settings.load() } catch { footer.stringValue = "配置读取失败，原文件保留，请检查数据目录中的 settings.json"; logGuard("配置读取失败：" + error.localizedDescription) }
        if !fm.fileExists(atPath: Settings.url.path) { importLegacyPush() }
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
            if event.keyCode == 53, self?.playbackSurface.isInFullScreenMode == true { self?.playbackSurface.exitFullScreenMode(options: nil); return nil }; return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        nextUpdateCheck = Date().addingTimeInterval(10)
        if !CommandLine.arguments.contains("--background") { showWindow() }
        tick()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
    @objc func showWindow() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { stopPlayback(); sender.orderOut(nil); NSApp.setActivationPolicy(.accessory); maybeInstall(); return false }
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
        let mainMenu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "退出远程守护", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key) }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        let height = min(800, (NSScreen.main?.visibleFrame.height ?? 850) - 50)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 940, height: 600)
        window.title = "远程守护 · macOS"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let root = LayoutView(frame: NSRect(x: 0, y: 0, width: 960, height: 800))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: height)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = root; scroll.autoresizingMask = [.width, .height]; window.contentView = scroll
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
        button("测试录屏（5 秒）", record, 435, 465, 190) { [weak self] in self?.testRecording() }
        label("最高 1080p / 5 帧每秒 / 1 Mbps；每 5 分钟约 37.5 MB，2 GB 约 4.5～4.8 小时。\n私钥和密码丢失无法恢复录像，请另行备份。", record, 25, 535, 840, 65)
        library = NSTableView(); library.delegate = self; library.dataSource = self; library.rowHeight = 25
        for (identifier, title, width) in [("file", "录像文件", 640.0), ("duration", "时长", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width; library.addTableColumn(column)
        }
        let libraryScroll = NSScrollView(frame: NSRect(x: 25, y: 15, width: 820, height: 115)); libraryScroll.hasVerticalScroller = true; libraryScroll.documentView = library; playback.addSubview(libraryScroll)
        button("刷新", playback, 25, 140, 110) { [weak self] in self?.refreshLibrary() }
        button("打开其他录像", playback, 150, 140, 170) { [weak self] in self?.chooseRecording() }
        button("选择私钥", playback, 340, 140, 150) { [weak self] in self?.choosePlaybackKey() }
        keyLabel = label("请选择播放私钥", playback, 510, 148, 330)
        label("私钥密码", playback, 25, 195, 100); playbackPassword = field("", playback, 125, 190, 330, secure: true)
        button("播放", playback, 475, 186, 110) { [weak self] in self?.play() }
        button("停止", playback, 595, 186, 110) { [weak self] in self?.stopPlayback() }
        button("全屏", playback, 725, 186, 120) { [weak self] in self?.toggleFullScreen() }
        playbackSurface.frame = NSRect(x: 25, y: 235, width: 820, height: 355); playback.addSubview(playbackSurface)
        playerView.frame = NSRect(x: 0, y: 0, width: 820, height: 265); playerView.autoresizingMask = [.width, .height]
        playerView.wantsLayer = true; playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.controlsStyle = .none; playerView.showsFullScreenToggleButton = false; playerView.showsSharingServiceButton = false; playbackSurface.addSubview(playerView)
        let transport = LayoutView(frame: NSRect(x: 0, y: 265, width: 820, height: 90)); transport.autoresizingMask = [.width, .minYMargin]; playbackSurface.addSubview(transport)
        timeline.frame = NSRect(x: 10, y: 3, width: 800, height: 30); timeline.autoresizingMask = [.width]; timeline.target = self; timeline.action = #selector(scrub(_:)); timeline.isContinuous = false; timeline.isEnabled = false; transport.addSubview(timeline)
        button("后退 10 秒", transport, 5, 43, 105) { [weak self] in self?.skip(-10) }
        pauseButton = button("暂停", transport, 115, 43, 80) { [weak self] in self?.togglePause() }
        button("快进 10 秒", transport, 200, 43, 105) { [weak self] in self?.skip(10) }
        speed.frame = NSRect(x: 315, y: 47, width: 85, height: 28); speed.addItems(withTitles: ["0.5x", "1x", "1.5x", "2x", "3x", "4x"]); speed.selectItem(at: 1); speed.target = self; speed.action = #selector(changeSpeed); transport.addSubview(speed)
        playbackClock.frame = NSRect(x: 410, y: 52, width: 225, height: 25); transport.addSubview(playbackClock)
        button("切换全屏", transport, 665, 43, 145) { [weak self] in self?.toggleFullScreen() }
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFullScreen)); doubleClick.numberOfClicksRequired = 2; playerView.addGestureRecognizer(doubleClick)
        label("拖动进度、快进或选择倍速；双击切换全屏，Esc 退出。录像只在内存中解锁。", playback, 25, 605, 840, 35)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshPlayback() }
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
        if settings.monitoring && samplingFailed { monitorStatus.stringValue += "\n网络采样异常，保留上次状态" }
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
    private func importLegacyPush() {
        for name in ["com.soujer.remote-guard", "com.soujer.remote-guard.instant"] {
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + name + ".plist")
            guard let plist = NSDictionary(contentsOf: url) as? [String: Any], let arguments = plist["ProgramArguments"] as? [String], let path = arguments.first(where: { URL(fileURLWithPath: $0).lastPathComponent == "remote-guard-macos.sh" }) else { continue }
            let config = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("push-channels.conf")
            guard let bytes = try? Vault.readBounded(config, maximum: 65_536), let text = String(data: bytes, encoding: .utf8) else { continue }
            var values = [String: String]()
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, ["ENABLED_CHANNELS", "BARK_KEY", "HAYO_TOKEN"].contains(parts[0]) else { continue }
                var value = parts[1]
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
                // Parse literals only; never source or execute a user's shell configuration.
                if value.contains("$(") || value.contains("`") { continue }; values[parts[0]] = value
            }
            let enabled = values["ENABLED_CHANNELS", default: ""].split(separator: " ")
            if enabled.contains("bark") { settings.barkKey = values["BARK_KEY", default: ""] }
            if enabled.contains("hayo") { settings.hayoToken = values["HAYO_TOKEN", default: ""] }
            footer.stringValue = "已读取旧版推送配置；点击启动监控切换到新版"; return
        }
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
    private func testRecording() {
        attempt {
            try require(!requestedRecording, "录屏正在进行，无需另行测试")
            try require(!settings.publicKey.isEmpty, "请先创建或导入播放私钥并保存录屏设置")
            guard CGPreflightScreenCaptureAccess() else { authorizeScreen(); return }
            testRecordingUntil = Date().addingTimeInterval(5); requestedRecording = true; recorder.start(settings)
            footer.stringValue = "正在测试录屏，5 秒后结束；画面仅在本机加密保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.testRecordingUntil = .distantPast
                if self.active.isEmpty || !self.settings.recording { self.requestedRecording = false; self.recorder.stop { self.refreshLibrary() } }
                self.footer.stringValue = "测试已结束，可到录像播放页选择片段验证"
            }
        }
    }
    private func refreshLibrary() {
        libraryFiles = ((try? RecordingStorage.files(URL(fileURLWithPath: settings.directory))) ?? []).filter { $0.pathExtension == "rgrec" }.reversed()
        library.reloadData(); if !libraryFiles.isEmpty { library.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    private func chooseRecording() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["rgrec"]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { selectedRecording = url; library.deselectAll(nil); footer.stringValue = "已选择录像：" + url.lastPathComponent } }
    private func choosePlaybackKey() { let panel = NSOpenPanel(); panel.allowedFileTypes = ["rgkey"]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { selectedKey = url; keyLabel.stringValue = url.lastPathComponent } }
    private func play() {
        stopPlayback()
        guard let file = library.selectedRow >= 0 ? libraryFiles[library.selectedRow] : selectedRecording, let key = selectedKey else { footer.stringValue = "请选择录像和播放私钥"; return }
        let secret = playbackPassword.stringValue; playbackPassword.stringValue = ""; footer.stringValue = "正在验证和解锁录像……"
        let request = playbackGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            do { let bytes = try Vault.decrypt(file, keyURL: key, password: secret); DispatchQueue.main.async { guard request == self.playbackGeneration && !self.terminating else { return }; self.movie = MemoryMovie(bytes); self.wantsPlayback = true; self.playingFile = file; self.durationSaved = false; self.playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: self.movie!.asset)); self.playerView.player?.playImmediately(atRate: self.playbackSpeed); self.footer.stringValue = "正在播放；双击画面可全屏，Esc 退出" } }
            catch { DispatchQueue.main.async { if request == self.playbackGeneration { self.footer.stringValue = "播放失败：" + error.localizedDescription } } }
        }
    }
    private func stopPlayback() { playbackGeneration += 1; seekGeneration += 1; wantsPlayback = false; if playbackSurface.isInFullScreenMode { playbackSurface.exitFullScreenMode(options: nil) }; playerView.player?.pause(); playerView.player?.replaceCurrentItem(with: nil); playerView.player = nil; movie = nil; timeline.isEnabled = false; timeline.doubleValue = 0; playbackClock.stringValue = "00:00:00 / --:--:--" }
    @objc private func toggleFullScreen() { if playbackSurface.isInFullScreenMode { playbackSurface.exitFullScreenMode(options: nil) } else if let screen = window.screen ?? NSScreen.main { playbackSurface.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false]) } }
    func numberOfRows(in tableView: NSTableView) -> Int { libraryFiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = libraryFiles[row]
        return NSTextField(labelWithString: tableColumn?.identifier.rawValue == "duration" ? RecordingStorage.clock(RecordingStorage.duration(file)) : file.lastPathComponent)
    }
    private func refreshPlayback() {
        guard let player = playerView.player, let item = player.currentItem else { return }
        if item.status == .failed { footer.stringValue = "播放失败：" + (item.error?.localizedDescription ?? "视频无法解码"); stopPlayback(); return }
        let length = item.duration.seconds, current = player.currentTime().seconds
        guard length.isFinite, length > 0 else { return }
        timeline.isEnabled = true; timeline.maxValue = length
        if !timeline.isDragging { timeline.doubleValue = current.isFinite ? current : 0 }
        playbackClock.stringValue = RecordingStorage.clock(current) + " / " + RecordingStorage.clock(length)
        pauseButton.title = player.rate == 0 ? "继续" : "暂停"
        if !durationSaved, let file = playingFile { durationSaved = true; try? RecordingStorage.saveDuration(file, seconds: length); library.reloadData() }
    }
    @objc private func scrub(_ sender: NSSlider) { seekPlayback(sender.doubleValue) }
    private func skip(_ seconds: Double) { guard let player = playerView.player else { return }; seekPlayback(player.currentTime().seconds + seconds) }
    private func seekPlayback(_ seconds: Double) {
        guard let player = playerView.player, let item = player.currentItem, item.duration.seconds.isFinite, seconds.isFinite else { return }
        let value = max(0, min(seconds, item.duration.seconds)); seekGeneration += 1; let request = seekGeneration
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            DispatchQueue.main.async { if finished, let self, let player, self.playerView.player === player, self.seekGeneration == request, self.wantsPlayback { player.playImmediately(atRate: self.playbackSpeed) } }
        }
    }
    private func togglePause() {
        guard let player = playerView.player else { return }
        if player.rate > 0 || wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate { wantsPlayback = false; player.pause() } else { wantsPlayback = true; if let item = player.currentItem, item.duration.seconds.isFinite, player.currentTime().seconds >= item.duration.seconds - 0.1 { player.seek(to: .zero) }; player.playImmediately(atRate: playbackSpeed) }
    }
    @objc private func changeSpeed() { if let player = playerView.player, player.rate > 0 { player.rate = playbackSpeed } }
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
                self.samplingFailed = sample == nil
                if sample == nil && Date().timeIntervalSince(self.lastSamplingError) >= 60 { logGuard("网络采样失败，保留上次会话状态"); self.lastSamplingError = Date() }
                let previous = self.active; self.active = self.tracker.update(sample, now: Date().timeIntervalSince1970)
                for name in self.active.subtracting(previous) { Notifications.send(name + " 已连接", body: "已连接", settings: self.settings) { _ in } }
                for name in previous.subtracting(self.active) { Notifications.send(name + " 已断开", body: "已断开", settings: self.settings) { _ in } }
                if let data = try? JSONEncoder().encode(self.tracker) { try? data.write(to: self.sessionsURL, options: .atomic) }
                if self.settings.recording && !self.active.isEmpty && !self.requestedRecording && Date() >= self.nextRecordingRetry { self.requestedRecording = true; self.recorder.start(self.settings) }
                if (self.active.isEmpty || !self.settings.recording) && self.requestedRecording && Date() >= self.testRecordingUntil { self.requestedRecording = false; self.recorder.stop() }
                self.refreshStatus()
            }
        }
    }
}
