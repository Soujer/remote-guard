import Foundation
import AVFoundation
import AppKit

enum SelfTests {
    static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws { try require(condition, name); checks += 1 }
        let root = fm.temporaryDirectory.appendingPathComponent("remote-guard-native-test-" + UUID().uuidString, isDirectory: true)
        try ensureDirectory(root); defer { try? fm.removeItem(at: root) }
        let password = "Interop123456", key = root.appendingPathComponent("test.rgkey")
        let publicKey = try Vault.createKey(key, password: password)
        var storage = Settings(); storage.directory = root.appendingPathComponent("quota").path; storage.quotaMB = 128
        let storageRoot = URL(fileURLWithPath: storage.directory); try ensureDirectory(storageRoot)
        let old = storageRoot.appendingPathComponent("rg-20261115T010000000Z-" + String(repeating: "a", count: 32) + ".rgrec")
        let recent = storageRoot.appendingPathComponent("rg-20261115T020000000Z-" + String(repeating: "b", count: 32) + ".rgrec.partial")
        for file in [old, recent] { fm.createFile(atPath: file.path, contents: nil); let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 67_108_864); try handle.close() }
        try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        let unrelated = storageRoot.appendingPathComponent("important.txt"); try Data("preserve".utf8).write(to: unrelated)
        try RecordingStorage.prepare(storage, reserve: 1_048_576)
        try check(!fm.fileExists(atPath: old.path) && fm.fileExists(atPath: recent.path), "Storage quota must remove the oldest recording first, including partial segments")
        try check(fm.fileExists(atPath: unrelated.path), "Quota cleanup must preserve unrelated files")
        try check(!publicKey.contains("<D>"), "Recording config must never contain a private key")
        try check(Vault.passwordError("Test12345678", "Test12345678") == nil, "Accept exactly twelve matching characters")
        try check(Vault.passwordError("Test12345678", "")!.contains("确认"), "Request missing confirmation")
        try check(Vault.passwordError("Test12345678", "test12345678")!.contains("不一致"), "Case-sensitive password confirmation")
        try check(Vault.passwordError("Testé12345678", "Teste\u{301}12345678") != nil, "Compare the original password bytes without Unicode normalization")
        let input = Data("test-only cross-platform encrypted recording fixture".utf8)
        let recording = root.appendingPathComponent("test.rgrec")
        let writer = try RecordingWriter(recording, publicKey: publicKey, limit: 1_048_576); try writer.write(input); try writer.finish()
        let roundTrip = try Vault.decrypt(recording, keyURL: key, password: password)
        try check(roundTrip == input, "RSA/AES/HMAC recording round trip")
        var rejected = false; do { _ = try Vault.decrypt(recording, keyURL: key, password: "wrong") } catch { rejected = true }; try check(rejected, "Reject wrong key password")
        var corrupted = try Data(contentsOf: recording); corrupted[corrupted.count - 1] ^= 1; let bad = root.appendingPathComponent("bad.rgrec"); try corrupted.write(to: bad)
        rejected = false; do { _ = try Vault.decrypt(bad, keyURL: key, password: password) } catch { rejected = true }; try check(rejected, "Reject corrupted recordings before playback")
        rejected = false; do { _ = try Vault.createKey(key, password: password) } catch { rejected = true }; try check(rejected, "Never overwrite a playback private key")
        let listener = Detection.parse("p12\ncToDesk\nn*:12345\n")
        let inbound = Detection.parse("p12\ncToDesk\nn192.0.2.1:12345->192.0.2.2:23456\n")
        try check(Detection.candidates(listeners: listener, established: inbound) == ["ToDesk"], "Detect an inbound control connection")
        try check(Detection.candidates(listeners: [], established: inbound).isEmpty, "Process or outgoing traffic alone is not a session")
        let heartbeat = Detection.parse("p12\ncToDesk\nn192.0.2.1:12345->192.0.2.2:443\n")
        try check(Detection.candidates(listeners: listener, established: heartbeat).isEmpty, "Ignore 443 heartbeat connections")
        var tracker = SessionTracker()
        try check(tracker.update(["ToDesk"], now: 100).isEmpty, "Require consecutive confirmation")
        try check(tracker.update(["ToDesk"], now: 102) == ["ToDesk"], "Confirm a second valid sample")
        try check(tracker.update([], now: 110) == ["ToDesk"], "Retain sessions through a brief quiet interval")
        try check(tracker.update(nil, now: 400) == ["ToDesk"], "Collection failure must not mean disconnected")
        try check(tracker.update([], now: 581).isEmpty, "Disconnect after a valid quiet interval")
        func release(_ number: String) -> [String: Any] {
            let prefix = "https://gitee.com/Soujer/remote-guard/releases/download/v" + number + "/"
            return ["tag_name": "v" + number, "assets": [["name": "remote-guard-macos-universal-v" + number + ".zip", "browser_download_url": prefix + "remote-guard-macos-universal-v" + number + ".zip"], ["name": "SHA256SUMS-macos-v" + number + ".txt", "browser_download_url": prefix + "SHA256SUMS-macos-v" + number + ".txt"]]]
        }
        try check(MacUpdates.select([release("1.9.0"), release("1.10.0")], current: "1.4.0")?.version == "1.10.0", "Select macOS updates using numeric versions")
        try check(MacUpdates.select([release("1.3.3")], current: "1.4.0") == nil, "Never downgrade macOS")
        var prerelease = release("9.0.0"); prerelease["prerelease"] = true
        try check(MacUpdates.select([prerelease], current: "1.4.0") == nil, "Skip prereleases")
        var incomplete = release("2.0.0"); incomplete["assets"] = []
        try check(MacUpdates.select([incomplete], current: "1.4.0") == nil, "Skip incomplete uploads")
        var foreign = release("2.0.0"), foreignAssets = foreign["assets"] as! [[String: String]]; foreignAssets[0]["browser_download_url"] = "https://example.com/foreign.zip"; foreign["assets"] = foreignAssets
        try check(MacUpdates.select([foreign], current: "1.4.0") == nil, "Reject package URLs outside the fixed Gitee repository")
        let helper = root.appendingPathComponent("apply-update.sh")
        let testScript = MacUpdates.installerScript.replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true").replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")
        try Data(testScript.utf8).write(to: helper)
        for fail in [false, true] {
            let caseRoot = root.appendingPathComponent(fail ? "rollback" : "install"); try ensureDirectory(caseRoot)
            let installed = caseRoot.appendingPathComponent("installed.app"), staged = caseRoot.appendingPathComponent("staged.app"), backup = caseRoot.appendingPathComponent("backup.app")
            try ensureDirectory(installed); try Data("old".utf8).write(to: installed.appendingPathComponent("version"))
            if !fail { try ensureDirectory(staged); try Data("new".utf8).write(to: staged.appendingPathComponent("version")) }
            let result = try runTool("/bin/bash", [helper.path, installed.path, staged.path, backup.path, "99999999", caseRoot.appendingPathComponent("none.plist").path, "gui/99999999"])
            try check(result.code == (fail ? 1 : 0), "Update helper must report its transaction result")
            let retained = try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8)
            try check(retained == (fail ? "old" : "new"), "Failed update must restore the previous application")
        }
        if let package = ProcessInfo.processInfo.environment["GUARD_PACKAGE"] {
            let zip = URL(fileURLWithPath: package), bytes = try Data(contentsOf: zip)
            try check(try SafeZIP.entries(bytes).count == SafeZIP.files.count, "Validate every signed app package entry")
            let extracted = root.appendingPathComponent("update-extraction"); try ensureDirectory(extracted)
            try SafeZIP.extract(bytes, zipURL: zip, directory: extracted)
            let signed = try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", extracted.appendingPathComponent("RemoteGuard.app").path])
            try check(signed.code == 0, "A safely extracted universal app must preserve its signature")
            for name in ["settings.json", "private.rgkey"] {
                let extra = root.appendingPathComponent(name), badZIP = root.appendingPathComponent(name + ".zip")
                try Data("must never be packaged".utf8).write(to: extra); try fm.copyItem(at: zip, to: badZIP)
                let added = try runTool("/usr/bin/zip", ["-q", "-j", badZIP.path, extra.path]); try check(added.code == 0, "Create a malformed package for validation")
                var rejected = false; do { _ = try SafeZIP.entries(Data(contentsOf: badZIP)) } catch { rejected = true }
                try check(rejected, "Reject update packages containing runtime settings or private keys")
            }
        }
        let fixtureURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_FIXTURE"] ?? "macos/Tests/windows-interop.json")
        if fm.fileExists(atPath: fixtureURL.path) {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: String]
            let windowsKey = root.appendingPathComponent("windows.rgkey"), windowsRecording = root.appendingPathComponent("windows.rgrec")
            try Data(base64Encoded: fixture["key"]!)!.write(to: windowsKey); try Data(base64Encoded: fixture["recording"]!)!.write(to: windowsRecording)
            let decoded = try Vault.decrypt(windowsRecording, keyURL: windowsKey, password: fixture["password"]!)
            try check(decoded == Data(base64Encoded: fixture["plaintext"]!), "Decrypt the Windows CNG interoperability fixture")
        }
        let movie = root.appendingPathComponent("synthetic.rgrec")
        let encoder = try SegmentEncoder(url: movie, publicKey: publicKey, width: 640, height: 360, limit: 2_097_152)
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel)
        try check(status == kCVReturnSuccess && pixel != nil, "Create a synthetic video frame")
        CVPixelBufferLockBaseAddress(pixel!, []); memset(CVPixelBufferGetBaseAddress(pixel!), 120, CVPixelBufferGetDataSize(pixel!)); CVPixelBufferUnlockBaseAddress(pixel!, [])
        for index in 0..<15 { try encoder.append(pixel!, at: Double(index) / 5); Thread.sleep(forTimeInterval: 0.03) }; try encoder.finish()
        let video = try Vault.decrypt(movie, keyURL: key, password: password)
        try check(video.range(of: Data("ftyp".utf8)) != nil && video.range(of: Data("moof".utf8)) != nil, "Encode fragmented MP4 directly into encrypted storage")
        let memory = MemoryMovie(video), image = AVAssetImageGenerator(asset: memory.asset)
        let frame = try image.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
        try check(frame.width == 640 && frame.height == 360, "Decode an authenticated in-memory movie without a plaintext file")
        _ = NSApplication.shared
        let desktop = GuardDesktop(); desktop.buildWindow()
        try check(desktop.tabs.numberOfTabViewItems == 5, "Build all five native desktop pages")
        try check(desktop.playerView.showsFullScreenToggleButton, "Embedded macOS playback must provide a full-screen control")
        let output = ProcessInfo.processInfo.environment["GUARD_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output {
            try ensureDirectory(output)
            for (index, name) in [(2, "recording"), (3, "playback")] {
                desktop.tabs.selectTabViewItem(at: index); desktop.window.contentView?.layoutSubtreeIfNeeded()
                if let view = desktop.tabs.tabViewItem(at: index).view, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    if let png = image.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name + ".png")) }
                }
            }
            let fixture: [String: String] = ["password": password, "key": try Data(contentsOf: key).base64EncodedString(), "recording": try Data(contentsOf: recording).base64EncodedString(), "plaintext": input.base64EncodedString(), "video": try Data(contentsOf: movie).base64EncodedString()]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: output.appendingPathComponent("macos-interop.json"))
        }
        print("Native macOS regression checks passed: \(checks)")
    }
}
