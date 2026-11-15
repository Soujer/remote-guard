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
        try check(!publicKey.contains("<D>"), "Recording config must never contain a private key")
        try check(Vault.passwordError("Test12345678", "Test12345678") == nil, "Accept exactly twelve matching characters")
        try check(Vault.passwordError("Test12345678", "")!.contains("确认"), "Request missing confirmation")
        try check(Vault.passwordError("Test12345678", "test12345678")!.contains("不一致"), "Case-sensitive password confirmation")
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
        let output = ProcessInfo.processInfo.environment["GUARD_TEST_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output {
            try ensureDirectory(output)
            let fixture: [String: String] = ["password": password, "key": try Data(contentsOf: key).base64EncodedString(), "recording": try Data(contentsOf: recording).base64EncodedString(), "plaintext": input.base64EncodedString(), "video": try Data(contentsOf: movie).base64EncodedString()]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: output.appendingPathComponent("macos-interop.json"))
        }
        print("Native macOS regression checks passed: \(checks)")
    }
}
